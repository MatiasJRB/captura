import Foundation

/// Local, optional Mac evidence. Text is display-only ASR, never an instruction.
public struct WorkerFeedback: Equatable, Sendable {
    public struct Quote: Equatable, Sendable {
        public let text: String
        public let id: String
        public let processedAt: Date
        public let startMilliseconds: Int64
    }
    public static let unavailable = WorkerFeedback()
    public private(set) var generatedAt: Date?
    public private(set) var topics: [String] = []
    public private(set) var quotes: [Quote] = []
    private var states: [String: String] = [:]

    public func state(id: String, sha: String) -> String? { states[id + ":" + sha] }

    public static func read(_ url: URL) -> Self {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink != true, let bytes = values.fileSize, bytes <= 2_000_000,
              let data = try? Data(contentsOf: url) else { return .unavailable }
        return parse(data)
    }

    public static let maximumAge: TimeInterval = 3600

    public func isFresh(at now: Date) -> Bool {
        guard let generatedAt else { return false }
        let age = now.timeIntervalSince(generatedAt)
        return age >= -60 && age <= Self.maximumAge
    }

    public static func parse(_ data: Data, now: Date = Date(), folderID: String? = nil, deviceID: String? = nil) -> Self {
        guard data.count <= 2_000_000,
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["schema_version"] as? Int == 1, report["available"] as? Bool == true,
              let generated = report["generated_at"] as? Double, generated > 0, generated.isFinite,
              let records = report["records"] as? [[String: Any]], records.count <= 5000 else { return .unavailable }
        var result = Self()
        result.generatedAt = Date(timeIntervalSince1970: generated / 1000)
        guard result.isFresh(at: now),
              folderID == nil || report["folder_id"] as? String == folderID,
              deviceID == nil || report["device_id"] as? String == deviceID else { return .unavailable }
        var conflicts = Set<String>()
        for row in records {
            guard let id = row["id"] as? String, WorkerContract.isDriveIdentifier(id),
                  let sha = row["sha256"] as? String, validHash(sha),
                  let state = row["state"] as? String, ["transcribed", "downloaded", "error"].contains(state) else { continue }
            let key = id + ":" + sha
            if let old = result.states[key], old != state { conflicts.insert(key) }
            result.states[key] = state
        }
        for key in conflicts { result.states.removeValue(forKey: key) }
        guard let highlights = report["highlights"] as? [String: Any],
              highlights["schema_version"] as? Int == 1, highlights["state"] as? String == "ready",
              let at = highlights["generated_at"] as? Double, at > 0, at.isFinite,
              let topics = highlights["topics"] as? [String], topics.count <= 3,
              let quotes = highlights["quotes"] as? [[String: Any]], quotes.count <= 6 else { return result }
        for row in quotes {
            guard let text = row["text"] as? String, safe(text, max: 220),
                  let id = row["id"] as? String, let sha = row["sha256"] as? String,
                  result.state(id: id, sha: sha) == "transcribed",
                  let processed = row["at"] as? Double, processed > 0, processed <= at + 60_000,
                  processed >= at - 7 * 86_400_000,
                  let start = row["start_ms"] as? Int64, start >= 0 else { continue }
            result.quotes.append(Quote(text: text, id: id, processedAt: Date(timeIntervalSince1970: processed / 1000), startMilliseconds: start))
        }
        if !result.quotes.isEmpty { result.topics = topics.filter { safe($0, max: 48) } }
        return result
    }

    private static func validHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func safe(_ text: String, max: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= max
            && text.unicodeScalars.allSatisfy { ![.control, .format].contains($0.properties.generalCategory) }
    }
}
