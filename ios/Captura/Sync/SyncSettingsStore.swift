import CapturaCore
import Foundation
import Synchronization

/// Sync state that must survive restarts. Port of Android's `SyncConfig` preferences.
struct SyncSettings: Codable, Equatable, Sendable {
    /// Opaque per-install ID written to the Drive inbox (`properties.device`), like
    /// `SyncConfig.deviceId`. Never derived from hardware identifiers.
    var deviceID: String
    /// The private inbox folder in Drive. The macOS worker's `folder_id` must match it.
    var folderID: String?
    /// The Google account that `folderID` and the queue's Drive IDs and upload sessions
    /// belong to. When another account is linked, all of that is forgotten.
    var driveAccountEmail: String?
    /// Opt-in, confirmed by the person: upload closed chunks on Wi-Fi without asking.
    var automaticSync = false
    /// Last "Sincronizar ahora": cellular is allowed for 30 minutes after it.
    var manualRequestedAt: Date?
    /// Last status line shown under the Drive section (Spanish, secret-free).
    var lastMessage: String?
    var lastMessageAt: Date?

    init(deviceID: String) {
        self.deviceID = deviceID
    }
}

/// A small JSON file (`sync-settings.json`) written atomically on every change.
///
/// `FolderIDStorage.save` must be durable before it returns: the folder is created in
/// Drive only after its new ID was saved, so a crash cannot leave an inbox the phone
/// forgot about. A file renamed into place gives that guarantee; `UserDefaults` does not.
final class SyncSettingsStore: Sendable {
    static let fileName = "sync-settings.json"

    let fileURL: URL
    private let state: Mutex<SyncSettings>
    /// False when the settings could not be written at all (disk full, no permission).
    /// Sync is then disabled, because a device ID that is not saved would change on the
    /// next launch and orphan the Drive folder.
    let isPersistent: Bool

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder.settings.decode(SyncSettings.self, from: data),
           DriveClient.isValidDeviceID(loaded.deviceID) {
            state = Mutex(loaded)
            isPersistent = true
            return
        }
        if manager.fileExists(atPath: fileURL.path) {
            // Unreadable: keep it aside for a human instead of overwriting it.
            let aside = directory.appendingPathComponent("sync-settings.unreadable-\(UUID().uuidString.lowercased()).json")
            try? manager.moveItem(at: fileURL, to: aside)
        }
        let fresh = SyncSettings(deviceID: UUID().uuidString.lowercased())
        state = Mutex(fresh)
        isPersistent = (try? Self.write(fresh, to: fileURL)) != nil
    }

    var current: SyncSettings { state.withLock { $0 } }

    /// Applies `change` and writes the file before the new value becomes visible.
    /// On a write failure nothing changes, in memory or on disk.
    @discardableResult
    func update(_ change: (inout SyncSettings) -> Void) throws -> SyncSettings {
        try state.withLock { settings in
            var next = settings
            change(&next)
            guard next != settings else { return settings }
            try Self.write(next, to: fileURL)
            settings = next
            return next
        }
    }

    /// The durable folder ID storage `SyncEngine` and `DriveClient.ensureFolder` need.
    var folderIDStorage: FolderIDStorage {
        FolderIDStorage(
            load: { [self] in current.folderID },
            save: { [self] id in try update { $0.folderID = id } }
        )
    }

    private static func write(_ settings: SyncSettings, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(settings).write(to: url, options: writingOptions)
    }

    private static var writingOptions: Data.WritingOptions {
        // Readable after the first unlock so background sync works with the screen locked.
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    }
}

private extension JSONDecoder {
    static var settings: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
