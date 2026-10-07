import Foundation

/// Persisted upload queue. Port of `SyncQueue.java` with a JSON store instead of SQLite.
///
/// Every mutation is written atomically (temp file + rename) before it becomes visible
/// in memory, so a failed write leaves both the file and the queue unchanged.
public actor UploadQueue {
    public static let storeFileName = "upload-queue.json"
    public static let storeVersion = 1
    /// Like the worker: three failures attributable to the item quarantine it.
    public static let maxRejections = 3
    /// Like `SyncQueue.pending()`: at most 100 items per run, ordered by name (oldest first).
    public static let batchLimit = 100

    public nonisolated let storeURL: URL
    public nonisolated let capturesRoot: URL
    private let sealer: any SecretSealer
    private let backoff: UploadBackoff
    private var entries: [String: UploadItem]
    private var running = false

    /// Loads the store (an absent file is an empty queue). Items left `uploading` by a
    /// crash become `pending` again. A corrupt store throws instead of being discarded,
    /// because discarding it would forget which files are already verified.
    public init(
        storeDirectory: URL, capturesRoot: URL,
        sealer: any SecretSealer = IdentitySecretSealer(), backoff: UploadBackoff = .standard
    ) throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let storeURL = storeDirectory.appending(component: Self.storeFileName)
        self.storeURL = storeURL
        self.capturesRoot = capturesRoot
        self.sealer = sealer
        self.backoff = backoff
        var loaded: [String: UploadItem] = [:]
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let data = try Data(contentsOf: storeURL)
            let file: StoreFile
            do {
                file = try JSONDecoder().decode(StoreFile.self, from: data)
            } catch {
                throw UploadQueueError.corruptStore
            }
            guard file.version == Self.storeVersion else { throw UploadQueueError.unsupportedStoreVersion(file.version) }
            for var item in file.items {
                if item.state == .uploading { item.state = .pending }
                loaded[item.id] = item
            }
        }
        self.entries = loaded
    }

    private struct StoreFile: Codable {
        var version: Int
        var items: [UploadItem]
    }

    // MARK: - Reading

    public func items() -> [UploadItem] {
        entries.values.sorted { $0.fileName < $1.fileName }
    }

    public func item(id: String) -> UploadItem? { entries[id] }

    public func count(_ state: UploadState) -> Int {
        entries.values.filter { $0.state == state }.count
    }

    /// Pending items whose backoff has elapsed (or all pending ones when
    /// `ignoringBackoff`, for a manual request), oldest name first.
    public func eligible(now: Date, ignoringBackoff: Bool = false) -> [UploadItem] {
        let ready = entries.values.filter { item in
            guard item.state == .pending else { return false }
            if ignoringBackoff { return true }
            return (item.nextAttemptAt ?? .distantPast) <= now
        }
        return Array(ready.sorted { $0.fileName < $1.fileName }.prefix(Self.batchLimit))
    }

    /// Pending items whose backoff has not elapsed yet.
    public func waitingForBackoff(now: Date) -> Int {
        entries.values.filter { $0.state == .pending && ($0.nextAttemptAt ?? .distantPast) > now }.count
    }

    /// Resolves the item's original inside the captures root.
    public func fileURL(for item: UploadItem) throws -> URL {
        try Self.resolve(relativePath: item.relativePath, fileName: item.fileName, in: capturesRoot)
    }

    // MARK: - Enqueue

    /// Adds a closed capture file. Refuses `.partial` files, unknown names, files of
    /// 1024 bytes or less and files above the worker's `MAX_AUDIO`.
    ///
    /// Idempotent: the same file with the same bytes returns the existing item (in any
    /// state, including verified). Different bytes under a known name throw
    /// `.contentChanged` and leave the existing item untouched.
    @discardableResult
    public func enqueue(fileAt url: URL, now: Date = Date()) throws -> UploadItem {
        let candidate = try makeItem(fileAt: url, now: now)
        if let existing = entries[candidate.id] {
            guard existing.checksums == candidate.checksums else { throw UploadQueueError.contentChanged }
            return existing
        }
        var next = entries
        next[candidate.id] = candidate
        try persist(next)
        return candidate
    }

    /// Scans the captures root for closed capture files not yet queued (like
    /// `SyncQueue.discover`). Ineligible files are skipped silently.
    @discardableResult
    public func discover(now: Date = Date()) throws -> [UploadItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: capturesRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var next = entries
        var added: [UploadItem] = []
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            guard UploadEligibility.isUploadableName(name), next[name] == nil else { continue }
            do {
                let item = try makeItem(fileAt: url, now: now)
                next[item.id] = item
                added.append(item)
            } catch let error as UploadQueueError where error.isIneligibleFile {
                continue
            }
        }
        if !added.isEmpty { try persist(next) }
        return added.sorted { $0.fileName < $1.fileName }
    }

    private func makeItem(fileAt url: URL, now: Date) throws -> UploadItem {
        let name = url.lastPathComponent
        if name.hasSuffix(CaptureNaming.partialSuffix) { throw UploadQueueError.partialFile }
        guard UploadEligibility.isUploadableName(name) else { throw UploadQueueError.notACaptureFile }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile == true, let size = values?.fileSize else {
            throw UploadQueueError.notARegularFile
        }
        try UploadEligibility.check(fileName: name, bytes: Int64(size))
        let relativePath = try Self.relativePath(of: url, in: capturesRoot)
        let checksums = try Checksums.compute(fileAt: url)
        // The file may have grown or shrunk while hashing; re-check the bounds.
        try UploadEligibility.check(fileName: name, bytes: checksums.bytes)
        return UploadItem(fileName: name, relativePath: relativePath, checksums: checksums, createdAt: now)
    }

    // MARK: - Run bookkeeping

    /// Only one sync run may own the queue at a time.
    public func claimRun() -> Bool {
        guard !running else { return false }
        running = true
        return true
    }

    public func releaseRun() { running = false }

    @discardableResult
    public func assignDriveFileID(_ driveFileID: String, to id: String) throws -> UploadItem {
        guard WorkerContract.isDriveIdentifier(driveFileID) else { throw DriveError.invalidIdentifier }
        return try mutate(id) { item in
            if item.driveFileID == nil { item.driveFileID = driveFileID }
        }
    }

    public func markUploading(_ id: String) throws {
        try mutate(id) { item in
            guard item.state == .pending else { return }
            item.state = .uploading
        }
    }

    /// Stores (sealed) or clears the resumable session URI.
    public func setSessionURI(_ session: URL?, for id: String) throws {
        let sealed = try session.map { try sealer.seal($0.absoluteString) }
        try mutate(id) { $0.sealedSessionURI = sealed }
    }

    /// The stored session, or nil when none is stored or it cannot be opened any more
    /// (then the upload simply starts a new session).
    public func sessionURI(for id: String) -> URL? {
        guard let sealed = entries[id]?.sealedSessionURI,
              let plain = try? sealer.open(sealed)
        else { return nil }
        return URL(string: plain)
    }

    public func markVerified(_ id: String, driveFileID: String, at date: Date) throws {
        try mutate(id) { item in
            item.state = .verified
            item.driveFileID = driveFileID
            item.sealedSessionURI = nil
            item.nextAttemptAt = nil
            item.lastError = nil
            item.verifiedAt = date
        }
    }

    /// Back to pending without counting a failure (cancelled run, policy stop, re-auth).
    public func release(_ id: String) throws {
        try mutate(id) { item in
            if item.state == .uploading { item.state = .pending }
        }
    }

    /// Records a failed attempt and schedules the next one with exponential backoff.
    /// When `rejected` (the failure is attributable to the item, not the network) and
    /// this is the third such failure, the item is quarantined.
    @discardableResult
    public func recordFailure(_ id: String, code: String, rejected: Bool, now: Date) throws -> UploadItem {
        try mutate(id) { item in
            guard item.state != .verified else { return }
            item.attempts += 1
            if rejected { item.rejections += 1 }
            item.lastError = code
            if item.rejections >= Self.maxRejections {
                item.state = .quarantined
                item.nextAttemptAt = nil
            } else {
                item.state = .pending
                item.nextAttemptAt = now.addingTimeInterval(backoff.delay(afterFailures: item.attempts))
            }
        }
    }

    /// Keeps the original for human review (changed, missing or invalid file).
    @discardableResult
    public func quarantine(_ id: String, code: String) throws -> UploadItem {
        try mutate(id) { item in
            guard item.state != .verified else { return }
            item.state = .quarantined
            item.lastError = code
            item.nextAttemptAt = nil
        }
    }

    /// A person reviewed a quarantined item and asked to try again.
    ///
    /// When the item was rejected because of its remote copy (wrong receipt or parent,
    /// trashed, shared, not owned), retrying under the same Drive ID could only fail
    /// the same way, so the retry starts a new remote copy (new ID, new session).
    @discardableResult
    public func retryQuarantined(_ id: String) throws -> UploadItem {
        try mutate(id) { item in
            guard item.state == .quarantined else { return }
            item.state = .pending
            item.rejections = 0
            item.nextAttemptAt = nil
            if let code = item.lastError, Self.remoteCopyUnusableCodes.contains(code) {
                item.driveFileID = nil
                item.sealedSessionURI = nil
            }
        }
    }

    private static let remoteCopyUnusableCodes: Set<String> = [
        DriveError.remoteReceiptMismatch.code,
        DriveError.remoteFileNotPrivate.code,
    ]

    /// Forgets the resumable sessions (and, unless `keepingFileIDs`, the pre-generated
    /// Drive IDs) of every item that is not verified, so their next upload starts from
    /// scratch. Used when the remote side they were started for is gone: the inbox
    /// folder was replaced (a session carries its parent folder), the Google account
    /// changed, or Drive was unlinked (sessions are capabilities of that grant).
    /// Verified items keep their receipt. Originals are never touched.
    public func forgetRemoteUploads(keepingFileIDs: Bool = false) throws {
        var next = entries
        var changed = false
        for (id, var item) in entries where item.state != .verified {
            let clearID = !keepingFileIDs && item.driveFileID != nil
            guard clearID || item.sealedSessionURI != nil else { continue }
            if clearID { item.driveFileID = nil }
            item.sealedSessionURI = nil
            next[id] = item
            changed = true
        }
        if changed { try persist(next) }
    }

    // MARK: - Persistence

    @discardableResult
    private func mutate(_ id: String, _ change: (inout UploadItem) throws -> Void) throws -> UploadItem {
        guard var item = entries[id] else { throw UploadQueueError.unknownItem }
        try change(&item)
        var next = entries
        next[id] = item
        try persist(next)
        return item
    }

    private func persist(_ next: [String: UploadItem]) throws {
        let file = StoreFile(version: Self.storeVersion, items: next.values.sorted { $0.fileName < $1.fileName })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(file).write(to: storeURL, options: Self.writingOptions)
        } catch {
            throw UploadQueueError.writeFailed
        }
        entries = next
    }

    private static var writingOptions: Data.WritingOptions {
        #if os(iOS)
        // Background sync must read the queue after the first unlock.
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    // MARK: - Paths

    static func relativePath(of url: URL, in root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { throw UploadQueueError.outsideCapturesRoot }
        let relative = String(filePath.dropFirst(prefix.count))
        _ = try resolve(relativePath: relative, fileName: url.lastPathComponent, in: root)
        return relative
    }

    static func resolve(relativePath: String, fileName: String, in root: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.last == fileName,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw UploadQueueError.outsideCapturesRoot }
        var url = root
        for component in components { url = url.appending(component: component) }
        return url
    }
}
