import Foundation

public enum UploadState: String, Codable, CaseIterable, Sendable {
    /// Waiting for an allowed network (and its backoff, if any).
    case pending
    /// Being uploaded by a run. A crash leaves it here; the queue reloads it as pending.
    case uploading
    /// Drive's receipt matched and the worker would accept it. Terminal.
    case verified
    /// Kept on the phone for a human to look at; never retried automatically.
    case quarantined
}

/// One closed capture file and its upload progress. The original file is never
/// modified or deleted by the queue.
public struct UploadItem: Codable, Equatable, Identifiable, Sendable {
    /// The file name; it embeds a UUID, so it is unique per capture.
    public let id: String
    public let fileName: String
    /// Path below the captures root (validated: no `..`, no absolute paths).
    public let relativePath: String
    public let bytes: Int64
    public let sha256: String
    public let md5: String
    public let kind: CaptureKind
    public let createdAt: Date
    public internal(set) var state: UploadState
    /// Failed attempts of any kind; drives the exponential backoff.
    public internal(set) var attempts: Int
    /// Failures caused by the item or its remote receipt (not by the network).
    /// Three of them quarantine the item, like the worker does.
    public internal(set) var rejections: Int
    /// Secret-free error code of the last failure.
    public internal(set) var lastError: String?
    /// Pre-generated Drive ID. Kept once assigned, so a retry never creates a duplicate.
    public internal(set) var driveFileID: String?
    /// Resumable session URI as returned by the `SecretSealer` (never plaintext on disk
    /// unless the identity sealer is used).
    public internal(set) var sealedSessionURI: String?
    public internal(set) var nextAttemptAt: Date?
    public internal(set) var verifiedAt: Date?

    public var checksums: FileChecksums { FileChecksums(bytes: bytes, sha256: sha256, md5: md5) }

    init(fileName: String, relativePath: String, checksums: FileChecksums, createdAt: Date) {
        self.id = fileName
        self.fileName = fileName
        self.relativePath = relativePath
        self.bytes = checksums.bytes
        self.sha256 = checksums.sha256
        self.md5 = checksums.md5
        self.kind = CaptureKind.from(fileName: fileName)
        self.createdAt = createdAt
        self.state = .pending
        self.attempts = 0
        self.rejections = 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, relativePath, bytes, sha256, md5, kind, createdAt, state, attempts, rejections
        case lastError, driveFileID, nextAttemptAt, verifiedAt
        case sealedSessionURI = "sessionURI"
    }
}

/// Seals resumable session URIs before they are written to disk. They are bearer
/// capabilities for one upload (`SyncCrypto.java` encrypts them on Android). The app
/// supplies a Keychain/Data Protection implementation.
public protocol SecretSealer: Sendable {
    func seal(_ secret: String) throws -> String
    func open(_ sealed: String) throws -> String
}

/// Stores the value as is. Only for tests and platforms that protect the file otherwise.
public struct IdentitySecretSealer: SecretSealer {
    public init() {}
    public func seal(_ secret: String) throws -> String { secret }
    public func open(_ sealed: String) throws -> String { sealed }
}

/// Which local files may ever be uploaded.
public enum UploadEligibility {
    /// 15-minute chunks (`CaptureNaming.isChunkName`) plus the exact note names Android
    /// also uploads (`personal-capture-note[-draft]-<uuid>.m4a`). `.partial` never matches.
    public static func isUploadableName(_ name: String) -> Bool {
        if name.hasSuffix(CaptureNaming.partialSuffix) { return false }
        return CaptureNaming.isChunkName(name) || CaptureKind.from(fileName: name) != .ambientAudio
    }

    /// Size bounds shared with Android (`> 1024`) and the worker (`<= MAX_AUDIO`).
    public static func check(fileName: String, bytes: Int64) throws {
        if fileName.hasSuffix(CaptureNaming.partialSuffix) { throw UploadQueueError.partialFile }
        guard isUploadableName(fileName) else { throw UploadQueueError.notACaptureFile }
        guard bytes > WorkerContract.minimumExclusiveAudioBytes else { throw UploadQueueError.tooSmall }
        guard bytes <= WorkerContract.maxAudioBytes else { throw UploadQueueError.tooLarge }
    }
}

/// Exponential backoff between failed attempts, like Android's JobScheduler
/// (`BACKOFF_POLICY_EXPONENTIAL`, 30 s initial, capped at 5 h).
public struct UploadBackoff: Equatable, Sendable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval

    public init(initialDelay: TimeInterval = 30, maximumDelay: TimeInterval = 5 * 60 * 60) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }

    public static let standard = UploadBackoff()

    public func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 32))
        return min(initialDelay * pow(2, exponent), maximumDelay)
    }
}

public enum UploadQueueError: Error, Equatable, Sendable {
    case partialFile
    case notACaptureFile
    case tooSmall
    case tooLarge
    case notARegularFile
    case outsideCapturesRoot
    case unknownItem
    /// The same file name was enqueued again with different bytes.
    case contentChanged
    case corruptStore
    /// The store could not be written (disk full, permissions). Nothing changed.
    case writeFailed
    case unsupportedStoreVersion(Int)

    public var code: String {
        switch self {
        case .partialFile: return "partial-file"
        case .notACaptureFile: return "not-a-capture-file"
        case .tooSmall: return "audio-too-small"
        case .tooLarge: return "audio-too-large"
        case .notARegularFile: return "not-a-regular-file"
        case .outsideCapturesRoot: return "outside-captures-root"
        case .unknownItem: return "unknown-item"
        case .contentChanged: return "changed-audio"
        case .corruptStore: return "corrupt-queue-store"
        case .writeFailed: return "queue-write-failed"
        case .unsupportedStoreVersion(let version): return "unsupported-queue-version-\(version)"
        }
    }

    /// The file simply is not something the queue uploads.
    var isIneligibleFile: Bool {
        switch self {
        case .partialFile, .notACaptureFile, .tooSmall, .tooLarge, .notARegularFile, .outsideCapturesRoot: return true
        default: return false
        }
    }
}
