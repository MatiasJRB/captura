import CapturaCore
import Foundation

/// How many queue items are in each state, for the Drive section.
struct QueueCounts: Equatable, Sendable {
    var pending = 0
    var uploading = 0
    var verified = 0
    var quarantined = 0

    init() {}

    init(_ items: [UploadItem]) {
        for item in items {
            switch item.state {
            case .pending: pending += 1
            case .uploading: uploading += 1
            case .verified: verified += 1
            case .quarantined: quarantined += 1
            }
        }
    }

    /// "Pendientes" in the UI: waiting or being uploaded right now.
    var waiting: Int { pending + uploading }
}

/// One local recording as the list shows it. Originals are never deleted by the app.
struct RecordingRow: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case pending
        case uploading
        case uploaded
        /// Kept for a human to look at (`lastError` is a secret-free code).
        case review(code: String?)
        /// Closed but never queued (e.g. too short for the worker): stays on the phone.
        case localOnly
        /// Left behind by an interrupted write; preserved in Quarantine/, never uploaded.
        case incomplete
    }

    let id: String
    let fileName: String
    let bytes: Int64
    let startedAt: Date?
    let status: Status

    var statusLabel: String {
        switch status {
        case .pending: return "Pendiente"
        case .uploading: return "Subiendo"
        case .uploaded: return "Subido a Drive"
        case .review: return "En revisión"
        case .localOnly: return "Solo en el iPhone"
        case .incomplete: return "Incompleto · conservado"
        }
    }

    /// Newest first: closed chunks (with their queue state), then quarantined files.
    static func build(closedChunks: [URL], items: [UploadItem], quarantinedFiles: [URL]) -> [RecordingRow] {
        let byName = Dictionary(items.map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [RecordingRow] = closedChunks.map { url in
            let name = url.lastPathComponent
            let item = byName[name]
            return RecordingRow(
                id: name,
                fileName: name,
                bytes: item?.bytes ?? fileSize(url),
                startedAt: startDate(fromChunkName: name),
                status: item.map(status(of:)) ?? .localOnly
            )
        }
        rows.sort { ($0.startedAt ?? .distantPast, $0.fileName) > ($1.startedAt ?? .distantPast, $1.fileName) }
        let incomplete = quarantinedFiles.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { url in
            RecordingRow(
                id: "quarantine/" + url.lastPathComponent,
                fileName: url.lastPathComponent,
                bytes: fileSize(url),
                startedAt: startDate(fromChunkName: url.lastPathComponent),
                status: .incomplete
            )
        }
        return rows + incomplete
    }

    static func status(of item: UploadItem) -> Status {
        switch item.state {
        case .pending: return .pending
        case .uploading: return .uploading
        case .verified: return .uploaded
        case .quarantined: return .review(code: item.lastError)
        }
    }

    /// `personal-capture-<yyyyMMdd-HHmmss>-<uuid>.m4a[.partial]` in local time.
    static func startDate(fromChunkName name: String, timeZone: TimeZone = .current) -> Date? {
        let prefix = "personal-capture-"
        guard name.hasPrefix(prefix) else { return nil }
        let stamp = name.dropFirst(prefix.count).prefix(15)
        guard stamp.count == 15 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(stamp))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
