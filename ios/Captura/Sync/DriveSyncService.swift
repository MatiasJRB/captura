import CapturaCore
import Foundation

/// What the app model needs from sync, so it can be tested with a fake.
protocol SyncService: Sendable {
    /// One pass over the queue. Cancel the calling Task to stop it (the current item
    /// returns to pending and keeps its resumable session).
    func run(_ trigger: SyncTrigger, onEvent: @escaping @Sendable (SyncEvent) -> Void) async -> SyncSummary
    /// Creates or validates the private inbox folder in Drive.
    func ensureFolder() async throws -> DriveFolderResolution
}

/// Builds a `SyncEngine` per run, with a transport that matches the trigger: an
/// automatic run may only use Wi-Fi, a manual one any network (Android binds the job
/// to the network its constraint allowed).
struct DriveSyncService: SyncService {
    let queue: UploadQueue
    let deviceID: String
    let folderStorage: FolderIDStorage
    let conditions: @Sendable () async -> NetworkConditions
    let token: DriveClient.TokenProvider
    let makeTransport: @Sendable (_ allowsCellular: Bool) -> any HTTPTransport
    let now: @Sendable () -> Date

    init(
        queue: UploadQueue,
        deviceID: String,
        folderStorage: FolderIDStorage,
        conditions: @escaping @Sendable () async -> NetworkConditions,
        token: @escaping DriveClient.TokenProvider,
        makeTransport: @escaping @Sendable (_ allowsCellular: Bool) -> any HTTPTransport = { DriveURLSessionTransport(allowsCellular: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.queue = queue
        self.deviceID = deviceID
        self.folderStorage = folderStorage
        self.conditions = conditions
        self.token = token
        self.makeTransport = makeTransport
        self.now = now
    }

    func run(_ trigger: SyncTrigger, onEvent: @escaping @Sendable (SyncEvent) -> Void) async -> SyncSummary {
        let allowsCellular: Bool
        if case .manual = trigger { allowsCellular = true } else { allowsCellular = false }
        return await engine(allowsCellular: allowsCellular, onEvent: onEvent).run(trigger)
    }

    /// Right after linking (an explicit action of the person), so any network is fine;
    /// it only exchanges small metadata requests.
    func ensureFolder() async throws -> DriveFolderResolution {
        try await engine(allowsCellular: true, onEvent: nil).ensureFolder()
    }

    private func engine(allowsCellular: Bool, onEvent: (@Sendable (SyncEvent) -> Void)?) -> SyncEngine {
        let drive = DriveClient(transport: makeTransport(allowsCellular), token: token)
        return SyncEngine(
            queue: queue, drive: drive, deviceID: deviceID, folderStorage: folderStorage,
            conditions: conditions, now: now, onEvent: onEvent
        )
    }
}

/// Adapts the linked Google account to `DriveClient.TokenProvider`.
enum DriveTokenSource {
    /// - `forceRefresh` (Drive answered 401): drop the cached token, then ask again.
    /// - A revoked or missing grant becomes `DriveError.needsReauthorization`, so the
    ///   run stops without counting a failure against any audio.
    static func make(_ provider: any GoogleAccessTokenProviding) -> DriveClient.TokenProvider {
        { forceRefresh in
            if forceRefresh { await provider.invalidateAccessToken() }
            do {
                return try await provider.accessToken()
            } catch let error as GoogleAuthError where requiresRelink(error) {
                throw DriveError.needsReauthorization
            }
        }
    }

    static func requiresRelink(_ error: GoogleAuthError) -> Bool {
        switch error {
        case .reauthenticationRequired, .invalidGrant, .signedOut:
            return true
        default:
            return false
        }
    }
}
