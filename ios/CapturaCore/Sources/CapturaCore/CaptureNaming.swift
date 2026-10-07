import Foundation

/// Capture-session provenance. Mirrors `CaptureKind.java` and `worker/capture_kind.py`.
/// It describes how a file was captured; it never grants permission to act.
public enum CaptureKind: String, Codable, Sendable {
    case ambientAudio = "ambient_audio"
    case dictatedNote = "dictated_note"
    case noteInterrupted = "note_interrupted"

    public static func from(fileName: String) -> CaptureKind {
        if fileName.range(of: #"^personal-capture-note-draft-[a-f0-9-]{36}\.m4a$"#, options: .regularExpression) != nil {
            return .noteInterrupted
        }
        if fileName.range(of: #"^personal-capture-note-[a-f0-9-]{36}\.m4a$"#, options: .regularExpression) != nil {
            return .dictatedNote
        }
        return .ambientAudio
    }
}

/// File names shared with the Android recorder: `personal-capture-<yyyyMMdd-HHmmss>-<uuid>.m4a`.
public enum CaptureNaming {
    public static let folderName = "Captura · audios"
    public static let fileExtension = "m4a"
    /// Suffix for a chunk that is still being written. Never uploaded.
    public static let partialSuffix = ".partial"

    public static func chunkName(startedAt date: Date, id: UUID = UUID(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "personal-capture-\(formatter.string(from: date))-\(id.uuidString.lowercased()).\(fileExtension)"
    }

    public static func isChunkName(_ name: String) -> Bool {
        name.range(of: #"^personal-capture-[0-9]{8}-[0-9]{6}-[a-f0-9-]{36}\.m4a$"#, options: .regularExpression) != nil
    }
}
