import CapturaCore
import Foundation

extension AppModel {
    /// The one instance the app, its intents and its background task share. A second
    /// `RecorderController` would quarantine the open chunk of the first one.
    static let shared: AppModel = live(options: .current)

    /// Application Support/Captura: `Recordings/` (originals) and `Sync/` (queue and
    /// settings). Excluded from iCloud/iTunes backups: audio leaves the phone only to
    /// the person's own Drive, after opt-in (Android sets `allowBackup="false"`).
    static var baseDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Captura", isDirectory: true)
    }

    static var syncDirectory: URL {
        baseDirectory.appendingPathComponent("Sync", isDirectory: true)
    }

    static func live(options: LaunchOptions) -> AppModel {
        let recorder = RecorderController(
            directory: RecordingStore.defaultDirectory,
            chunkDuration: options.chunkSeconds ?? ChunkRotation.defaultChunkDuration
        )
        excludeFromBackup(baseDirectory)
        let settingsStore = SyncSettingsStore(directory: syncDirectory)
        excludeFromBackup(syncDirectory)
        let tokenStore = KeychainTokenStore()
        let sealer = KeychainSecretSealer()
        if settingsStore.isNewInstall {
            discardKeychainLeftovers(tokenStore: tokenStore, sealer: sealer)
        }
        let auth = GoogleSignInController(store: tokenStore)
        let network = NetworkMonitor()

        var queue: UploadQueue?
        var queueMessage: String?
        do {
            queue = try UploadQueue(
                storeDirectory: syncDirectory,
                capturesRoot: recorder.directory,
                sealer: sealer
            )
        } catch {
            let code = (error as? UploadQueueError)?.code ?? "queue-unavailable"
            queueMessage = "No se pudo leer la cola de subida (\(code)). Los originales siguen en el iPhone; la subida a Drive queda apagada."
        }

        var sync: SyncService?
        if let queue, let provider = auth.tokenProvider {
            sync = DriveSyncService(
                queue: queue,
                deviceID: settingsStore.current.deviceID,
                folderStorage: settingsStore.folderIDStorage,
                conditions: { [network] in await network.current() },
                token: DriveTokenSource.make(provider)
            )
        }

        return AppModel(
            recorder: recorder,
            auth: auth,
            settingsStore: settingsStore,
            queue: queue,
            queueUnavailableMessage: queueMessage,
            sync: sync,
            network: network,
            background: SystemBackgroundExecution(),
            notices: SystemPauseNotifier()
        )
    }

    /// iOS keeps Keychain items when the app is deleted, but removes Application
    /// Support (settings, queue, recordings). On a new install, a stored Google link or
    /// session key belongs to a deleted install: drop them, so nothing is linked (and no
    /// Drive folder is created) until the person links again. The grant itself stays at
    /// Google, as after deleting any app; it can be removed from the Google account.
    nonisolated static func discardKeychainLeftovers(tokenStore: TokenStore, sealer: KeychainSecretSealer) {
        try? tokenStore.delete()
        try? sealer.deleteKey()
    }

    private static func excludeFromBackup(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
