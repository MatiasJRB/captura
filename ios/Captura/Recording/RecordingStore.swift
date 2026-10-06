import Foundation
import CapturaCore

/// The local folder that holds recordings. Originals are never deleted here:
/// closed chunks stay at the top level, and anything that could not be closed
/// cleanly is moved to `Quarantine/` so it is preserved but never uploaded.
struct RecordingStore: Sendable {
    let directory: URL

    init(directory: URL = RecordingStore.defaultDirectory) {
        self.directory = directory
    }

    /// Application Support/Captura/Recordings.
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Captura", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    var quarantineDirectory: URL {
        directory.appendingPathComponent(RecordingFiles.quarantineFolderName, isDirectory: true)
    }

    /// Creates the folders, excludes them from iCloud/iTunes backup (audio is synced
    /// only to the user's own Drive, after opt-in) and keeps them readable while the
    /// phone is locked so recording can continue with the screen off.
    func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        protect(directory)
        protect(quarantineDirectory)
    }

    /// Applies `completeUntilFirstUserAuthentication`. `.complete` would make the open
    /// chunk unwritable a few seconds after the screen locks. Best effort: this is
    /// also the system default for app data, so a failure does not weaken protection.
    func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    func partialURL(forChunkNamed name: String) -> URL {
        directory.appendingPathComponent(RecordingFiles.partialName(forChunkNamed: name), isDirectory: false)
    }

    /// Atomically renames a closed `.partial` file to its final chunk name
    /// (same-volume `rename(2)`), so readers never see a half-written chunk.
    func finalize(partial: URL) throws -> URL {
        guard let name = RecordingFiles.finalName(forPartialNamed: partial.lastPathComponent) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    /// Moves a file into `Quarantine/`, keeping its name (a `.partial` name can never
    /// be mistaken for a closed chunk). Never overwrites an existing quarantined file.
    @discardableResult
    func quarantine(_ url: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        var destination = quarantineDirectory.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        var attempt = 1
        while manager.fileExists(atPath: destination.path) {
            attempt += 1
            destination = quarantineDirectory.appendingPathComponent("\(url.lastPathComponent).\(attempt)", isDirectory: false)
        }
        try manager.moveItem(at: url, to: destination)
        return destination
    }

    /// Startup recovery: a `.partial` left behind means the app was killed while
    /// writing, so the container was never finalized. Move it aside for a human to
    /// inspect; never upload it. Mirrors Android keeping failed encoder output pending.
    func quarantineLeftoverPartials() -> [URL] {
        files().filter { RecordingFiles.role(ofFileNamed: $0.lastPathComponent) == .partial }
            .compactMap { try? quarantine($0) }
    }

    /// Closed chunks ready for the upload queue, oldest name first.
    func closedChunks() -> [URL] {
        files().filter { RecordingFiles.role(ofFileNamed: $0.lastPathComponent) == .closedChunk }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func quarantinedFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: quarantineDirectory.path)) ?? []
        return names.sorted().map { quarantineDirectory.appendingPathComponent($0, isDirectory: false) }
    }

    private func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.map { directory.appendingPathComponent($0, isDirectory: false) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
    }
}
