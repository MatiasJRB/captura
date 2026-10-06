import Foundation

/// Acceptance rules of the unchanged macOS worker (`worker/worker.py`), mirrored here so
/// the phone only reports an upload as done when the worker will import it.
///
/// Rejection codes are the worker's own `SafeError` strings.
public enum WorkerContract {
    /// `MAX_AUDIO`: 64 MiB.
    public static let maxAudioBytes: Int64 = 64 * 1024 * 1024
    /// The worker requires `1024 < size`; Android's queue skips files of 1024 bytes or less.
    public static let minimumExclusiveAudioBytes: Int64 = 1024
    public static let acceptedAudioMimeTypes: Set<String> = ["audio/mp4", "audio/x-m4a"]

    public enum Rejection: String, Error, Equatable, Sendable {
        case invalidDriveID = "invalid_drive_id"
        case wrongFolder = "wrong_folder"
        case folderNotPrivateCapture = "folder_not_private_capture"
        case invalidAudioMetadata = "invalid_audio_metadata"
        case audioSizeOutOfBounds = "audio_size_out_of_bounds"
        case downloadChecksumMismatch = "download_checksum_mismatch"
    }

    public static func acceptsAudioSize(_ bytes: Int64) -> Bool {
        bytes > minimumExclusiveAudioBytes && bytes <= maxAudioBytes
    }

    /// `worker.identifier`: `[A-Za-z0-9_-]{1,200}`.
    public static func isDriveIdentifier(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (1...200).contains(scalars.count) else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
            default: return false
            }
        }
    }

    /// `worker.verify_folder`.
    public static func verifyFolder(_ meta: DriveFileMetadata, expected: String? = nil) throws {
        guard let id = meta.id, isDriveIdentifier(id) else { throw Rejection.invalidDriveID }
        if let expected, !expected.isEmpty, id != expected { throw Rejection.wrongFolder }
        guard meta.mimeType == DriveMetadata.folderMimeType,
              meta.shared == false, meta.ownedByMe == true, meta.trashed == false,
              meta.properties[DriveMetadata.inboxPropertyKey] == "1",
              !(meta.properties[DriveMetadata.devicePropertyKey] ?? "").isEmpty
        else { throw Rejection.folderNotPrivateCapture }
    }

    /// `worker.verify_audio`. Returns the accepted size. A malformed size decodes as
    /// missing, so it is reported as out of bounds rather than `invalid_audio_size`.
    @discardableResult
    public static func verifyAudio(_ meta: DriveFileMetadata, folderID: String) throws -> Int64 {
        guard let id = meta.id, isDriveIdentifier(id) else { throw Rejection.invalidDriveID }
        guard meta.shared == false, meta.ownedByMe == true, meta.trashed == false,
              meta.parents.contains(folderID),
              let mimeType = meta.mimeType, acceptedAudioMimeTypes.contains(mimeType),
              meta.properties[DriveMetadata.audioPropertyKey] == "1",
              isLowercaseHex(meta.properties[DriveMetadata.sha256PropertyKey], length: 64),
              isLowercaseHex(meta.md5Checksum, length: 32)
        else { throw Rejection.invalidAudioMetadata }
        let size = meta.size ?? 0
        guard acceptsAudioSize(size) else { throw Rejection.audioSizeOutOfBounds }
        return size
    }

    /// `worker.validate_bytes`: the downloaded bytes must match size, MD5 and SHA-256.
    @discardableResult
    public static func validateBytes(_ checksums: FileChecksums, against meta: DriveFileMetadata) throws -> String {
        guard checksums.bytes == meta.size,
              checksums.md5 == meta.md5Checksum,
              checksums.sha256 == meta.properties[DriveMetadata.sha256PropertyKey]
        else { throw Rejection.downloadChecksumMismatch }
        return checksums.sha256
    }

    static func isLowercaseHex(_ value: String?, length: Int) -> Bool {
        guard let value, value.utf8.count == length else { return false }
        return value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
