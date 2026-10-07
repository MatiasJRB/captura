import Foundation

/// Typed Drive failures. Cases never carry tokens, URLs or response bodies, so they are
/// safe to persist as `lastError` and to show in diagnostics.
public enum DriveError: Error, Equatable, Sendable {
    /// A URL failed the endpoint allowlist; nothing was sent.
    case invalidEndpoint
    case invalidIdentifier
    case invalidDeviceID
    case invalidFileName
    /// Google rejected the credentials twice (or the scope is missing): link Drive again.
    case needsReauthorization
    /// The token provider failed for a reason other than revoked authorization.
    case tokenUnavailable
    /// The transport failed before an HTTP status arrived (offline, TLS, timeout).
    case connectionFailed
    /// The resumable session is gone (404/410); a new session must be started.
    case sessionExpired
    /// 429, 5xx or a 403 rate-limit or daily-limit reply: try again later.
    case retryable(status: Int)
    /// 403 `storageQuotaExceeded`: the account's Drive is full. Not the audio's fault;
    /// every upload fails until space is freed, so the run stops and retries later.
    case storageFull
    /// Any other HTTP failure.
    case failed(status: Int)
    case invalidResponse
    case oversizedResponse
    case invalidUploadRange
    case missingUploadSession
    case uploadNoProgress
    /// The folder exists but is shared or not owned by this account.
    case invalidPrivateFolder
    case remoteFileNotPrivate
    case remoteNoteKindMismatch
    case remoteReceiptMismatch
    /// The upload finished but Drive did not show a matching receipt yet.
    case missingRemoteReceipt
    /// Drive's receipt matches but the macOS worker would still refuse the file.
    case workerWouldReject(WorkerContract.Rejection)

    /// Stable, secret-free identifier for logs and the queue's `lastError`.
    public var code: String {
        switch self {
        case .invalidEndpoint: return "invalid-google-endpoint"
        case .invalidIdentifier: return "invalid-file-id"
        case .invalidDeviceID: return "invalid-device-id"
        case .invalidFileName: return "invalid-file-name"
        case .needsReauthorization: return "needs-reauthorization"
        case .tokenUnavailable: return "token-unavailable"
        case .connectionFailed: return "drive-connection-failed"
        case .sessionExpired: return "upload-session-expired"
        case .retryable(let status): return "drive-retry-later-\(status)"
        case .storageFull: return "drive-storage-full"
        case .failed(let status): return "drive-http-\(status)"
        case .invalidResponse: return "invalid-drive-response"
        case .oversizedResponse: return "oversized-google-response"
        case .invalidUploadRange: return "invalid-upload-range"
        case .missingUploadSession: return "missing-upload-session"
        case .uploadNoProgress: return "upload-no-progress"
        case .invalidPrivateFolder: return "invalid-private-folder"
        case .remoteFileNotPrivate: return "remote-file-not-private"
        case .remoteNoteKindMismatch: return "remote-note-kind-mismatch"
        case .remoteReceiptMismatch: return "remote-receipt-mismatch"
        case .missingRemoteReceipt: return "missing-remote-receipt"
        case .workerWouldReject(let rejection): return "worker-would-reject-\(rejection.rawValue)"
        }
    }

    /// Transient: the same request may succeed later without any change to the item.
    public var isRetryable: Bool {
        switch self {
        case .connectionFailed, .sessionExpired, .retryable, .storageFull, .uploadNoProgress, .missingRemoteReceipt,
             .tokenUnavailable:
            return true
        default:
            return false
        }
    }

    /// Maps a non-success HTTP reply. Mirrors the worker's rate-limit detection, and
    /// also treats account- or project-wide 403 limits as transient: they would fail
    /// every audio alike, so they must not count against (and quarantine) each one.
    static func from(_ response: HTTPResponse) -> DriveError {
        switch response.status {
        case 401:
            return .needsReauthorization
        case 429, 500...599:
            return .retryable(status: response.status)
        case 403:
            let text = String(decoding: response.body.prefix(65_536), as: UTF8.self)
            if text.contains(storageFullMarker) { return .storageFull }
            if rateLimitMarkers.contains(where: { text.contains($0) }) { return .retryable(status: 403) }
            if missingScopeMarkers.contains(where: { text.contains($0) }) { return .needsReauthorization }
            return .failed(status: 403)
        default:
            return .failed(status: response.status)
        }
    }

    private static let storageFullMarker = "storageQuotaExceeded"
    private static let rateLimitMarkers = [
        "rateLimitExceeded", "RateLimitExceeded", "RATE_LIMIT_EXCEEDED", "QUOTA_EXCEEDED",
        "dailyLimitExceeded", "quotaExceeded",
    ]
    private static let missingScopeMarkers = ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT", "insufficientScopes"]
}

extension DriveError: CustomStringConvertible {
    public var description: String { code }
}
