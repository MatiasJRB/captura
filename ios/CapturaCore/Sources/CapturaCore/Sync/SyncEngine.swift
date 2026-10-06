import Foundation

/// Where the app keeps the inbox folder ID (e.g. UserDefaults). `save` must be durable
/// before it returns: the folder is created only after the new ID is saved.
public struct FolderIDStorage: Sendable {
    public var load: @Sendable () async -> String?
    public var save: @Sendable (String) async throws -> Void

    public init(load: @escaping @Sendable () async -> String?, save: @escaping @Sendable (String) async throws -> Void) {
        self.load = load
        self.save = save
    }
}

/// Network state as the caller observes it now (validated internet, Wi-Fi transport).
public struct NetworkConditions: Equatable, Sendable {
    public var online: Bool
    public var wifi: Bool

    public init(online: Bool, wifi: Bool) {
        self.online = online
        self.wifi = wifi
    }
}

public enum SyncTrigger: Equatable, Sendable {
    /// Opted-in background sync: Wi-Fi only.
    case automatic
    /// "Sincronizar ahora": any validated network for 30 minutes after the request.
    case manual(requestedAt: Date)

    var isManual: Bool {
        if case .manual = self { return true }
        return false
    }

    var requestedAt: Date? {
        if case .manual(let date) = self { return date }
        return nil
    }
}

public enum SyncEvent: Equatable, Sendable {
    case folderReady(DriveFolderResolution)
    case itemStarted(id: String, fileName: String)
    case progress(id: String, confirmedBytes: Int64, totalBytes: Int64)
    case itemFinished(id: String, state: UploadState)
}

public struct SyncSummary: Equatable, Sendable {
    public enum PolicyBlock: Equatable, Sendable {
        case offline
        case waitingForWiFi
        case manualWindowExpired
    }

    public enum StopReason: Equatable, Sendable {
        case policy(PolicyBlock)
        case cancelled
        case needsReauthorization
        /// Transient failure (network, rate limit, 5xx): the run stopped and will retry.
        case retryLater(code: String)
        case folderUnavailable(code: String)
        case localStorageFailed(code: String)
        /// Another run owns the queue.
        case alreadyRunning
    }

    /// Items verified in Drive during this run (uploaded now or found already uploaded).
    public var uploaded = 0
    /// Attempts that failed and will be retried.
    public var failed = 0
    /// Items quarantined during this run.
    public var quarantined = 0
    /// Eligible items not attempted because the network policy did not allow it.
    public var skippedByPolicy = 0
    /// Pending items still waiting for their backoff (automatic runs only).
    public var skippedBackoff = 0
    /// Pending items after the run.
    public var remaining = 0
    /// Quarantined items in the queue after the run (all of them, not just this run's).
    public var needsReview = 0
    public var folder: DriveFolderResolution?
    public var stopReason: StopReason?

    public init() {}

    /// Short Spanish status line for the UI, mirroring the Android messages.
    public var statusMessage: String {
        switch stopReason {
        case .policy(.offline)?:
            return "Sin conexión. Los audios siguen en el teléfono."
        case .policy(.waitingForWiFi)?:
            return "Esperando Wi-Fi para sincronizar. Los audios siguen en el teléfono."
        case .policy(.manualWindowExpired)?:
            return "El pedido manual venció. Tocá Sincronizar ahora otra vez."
        case .cancelled?:
            return "Sincronización pausada. Se retoma más tarde."
        case .needsReauthorization?:
            return "Google requiere autorización. Volvé a vincular Google Drive."
        case .folderUnavailable?:
            return "La carpeta de Drive no es privada o no se puede usar. Los audios siguen en el teléfono."
        case .alreadyRunning?:
            return "Ya hay una sincronización en curso."
        case .retryLater?, .localStorageFailed?:
            return "No se pudo sincronizar. Los audios siguen en el teléfono. Reintentá o revisá la conexión a Google."
        case nil:
            break
        }
        if case .replaced? = folder?.outcome {
            return "Se creó una carpeta nueva en Drive. Actualizá el folder_id en la Mac."
        }
        if needsReview > 0 { return "Hay audios para revisar; originales conservados." }
        if remaining == 0 { return "Sincronizado · originales conservados en el teléfono." }
        return "Quedan audios pendientes."
    }
}

/// Uploads eligible queue items one at a time. Port of `SyncJobService.Run.upload`.
///
/// The caller decides when to run (opt-in automatic sync or an explicit manual request)
/// and reports network conditions; the engine re-checks them before every request.
/// Cancel the surrounding Task to stop (e.g. a background task expiring): the current
/// item returns to pending and its resumable session is kept for the next run.
public struct SyncEngine: Sendable {
    private let queue: UploadQueue
    private let drive: DriveClient
    private let deviceID: String
    private let folderStorage: FolderIDStorage
    private let conditions: @Sendable () async -> NetworkConditions
    private let now: @Sendable () -> Date
    private let onEvent: (@Sendable (SyncEvent) -> Void)?

    public init(
        queue: UploadQueue, drive: DriveClient, deviceID: String, folderStorage: FolderIDStorage,
        conditions: @escaping @Sendable () async -> NetworkConditions,
        now: @escaping @Sendable () -> Date = { Date() },
        onEvent: (@Sendable (SyncEvent) -> Void)? = nil
    ) {
        self.queue = queue
        self.drive = drive
        self.deviceID = deviceID
        self.folderStorage = folderStorage
        self.conditions = conditions
        self.now = now
        self.onEvent = onEvent
    }

    /// Ensures the private inbox folder (also useful right after linking Drive, so the
    /// worker's `probe` can find it before the first upload).
    ///
    /// When the stored folder is replaced, uploads started under it are forgotten first:
    /// a resumable session carries its parent folder, so resuming it would finish the
    /// audio in the old folder, where the worker never looks. This happens before the
    /// new ID is saved, so a failure leaves the old ID and the next run tries again.
    public func ensureFolder() async throws -> DriveFolderResolution {
        let storage = folderStorage
        let queue = self.queue
        let existingID = await storage.load()
        let resolution = try await drive.ensureFolder(
            existingID: existingID, deviceID: deviceID,
            persistNewID: { newID in
                // A new ID while one was stored means the stored folder is replaced.
                if existingID != nil { try await queue.forgetRemoteUploads() }
                try await storage.save(newID)
            }
        )
        onEvent?(.folderReady(resolution))
        return resolution
    }

    public func run(_ trigger: SyncTrigger) async -> SyncSummary {
        var summary = SyncSummary()
        guard await queue.claimRun() else {
            summary.stopReason = .alreadyRunning
            return summary
        }
        await execute(trigger, into: &summary)
        await queue.releaseRun()
        summary.remaining = await queue.count(.pending)
        summary.needsReview = await queue.count(.quarantined)
        return summary
    }

    private func execute(_ trigger: SyncTrigger, into summary: inout SyncSummary) async {
        let started = now()
        do {
            try await queue.discover(now: started)
        } catch {
            summary.stopReason = .localStorageFailed(code: Self.code(of: error))
            return
        }
        let items = await queue.eligible(now: started, ignoringBackoff: trigger.isManual)
        if !trigger.isManual { summary.skippedBackoff = await queue.waitingForBackoff(now: started) }
        guard !items.isEmpty else { return }
        if let block = await policyBlock(trigger) {
            summary.skippedByPolicy = items.count
            summary.stopReason = .policy(block)
            return
        }
        if Task.isCancelled {
            summary.stopReason = .cancelled
            return
        }

        let folder: DriveFolderResolution
        do {
            folder = try await ensureFolder()
            summary.folder = folder
        } catch {
            summary.stopReason = Self.stopReason(forFolderError: error)
            return
        }

        for (index, item) in items.enumerated() {
            switch await process(item, folderID: folder.id, trigger: trigger) {
            case .uploaded:
                summary.uploaded += 1
            case .failed:
                summary.failed += 1
            case .quarantined:
                summary.quarantined += 1
            case .stop(let reason, let countsAsFailure):
                if countsAsFailure { summary.failed += 1 }
                if case .policy = reason { summary.skippedByPolicy = items.count - index }
                summary.stopReason = reason
                return
            }
        }
    }

    // MARK: - One item

    private enum ItemOutcome {
        case uploaded
        case failed
        case quarantined
        case stop(SyncSummary.StopReason, countsAsFailure: Bool)
    }

    private struct PolicyStop: Error {
        let block: SyncSummary.PolicyBlock
    }

    private func process(_ item: UploadItem, folderID: String, trigger: SyncTrigger) async -> ItemOutcome {
        do {
            try await checkpoint(trigger)
        } catch {
            return stopOutcome(for: error)
        }
        onEvent?(.itemStarted(id: item.id, fileName: item.fileName))

        // Prepare: closed, unchanged original only (SyncQueue.prepare).
        let fileURL: URL
        let checksums: FileChecksums
        do {
            fileURL = try await queue.fileURL(for: item)
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                return await quarantine(item, code: "missing-audio")
            }
            checksums = try Checksums.compute(fileAt: fileURL)
        } catch is CancellationError {
            return .stop(.cancelled, countsAsFailure: false)
        } catch let error as UploadQueueError {
            return await quarantine(item, code: error.code)
        } catch {
            return await quarantine(item, code: "unreadable-audio")
        }
        guard checksums == item.checksums else { return await quarantine(item, code: "changed-audio") }

        do {
            // Re-read: preparing the folder may have forgotten this item's remote upload.
            var current = await queue.item(id: item.id) ?? item
            if current.driveFileID == nil {
                let generated = try await drive.generateID()
                current = try await queue.assignDriveFileID(generated, to: item.id)
            }
            guard let driveFileID = current.driveFileID else { throw DriveError.invalidIdentifier }
            try await queue.markUploading(item.id)
            let upload = DriveUpload(fileID: driveFileID, name: item.fileName, fileURL: fileURL, checksums: checksums)

            // Already in Drive (e.g. a previous run finished but was killed before saving).
            if try await drive.verifyUpload(upload, folderID: folderID) {
                return try await verified(item, driveFileID: driveFileID)
            }
            let queue = self.queue
            let itemID = item.id
            let total = item.bytes
            try await drive.upload(
                upload, folderID: folderID, session: await queue.sessionURI(for: itemID),
                sessionChanged: { try await queue.setSessionURI($0, for: itemID) },
                checkpoint: { confirmed in
                    try await self.checkpoint(trigger)
                    self.onEvent?(.progress(id: itemID, confirmedBytes: confirmed, totalBytes: total))
                }
            )
            guard try await drive.verifyUpload(upload, folderID: folderID) else {
                throw DriveError.missingRemoteReceipt
            }
            return try await verified(item, driveFileID: driveFileID)
        } catch {
            return await handleFailure(error, item: item)
        }
    }

    private func verified(_ item: UploadItem, driveFileID: String) async throws -> ItemOutcome {
        try await queue.markVerified(item.id, driveFileID: driveFileID, at: now())
        onEvent?(.itemFinished(id: item.id, state: .verified))
        return .uploaded
    }

    private func quarantine(_ item: UploadItem, code: String) async -> ItemOutcome {
        do {
            try await queue.quarantine(item.id, code: code)
        } catch {
            return .stop(.localStorageFailed(code: Self.code(of: error)), countsAsFailure: false)
        }
        onEvent?(.itemFinished(id: item.id, state: .quarantined))
        return .quarantined
    }

    private func handleFailure(_ error: Error, item: UploadItem) async -> ItemOutcome {
        if Self.stopsRun(error) {
            try? await queue.release(item.id)
            return stopOutcome(for: error)
        }
        if let error = error as? UploadQueueError {
            try? await queue.release(item.id)
            return .stop(.localStorageFailed(code: error.code), countsAsFailure: false)
        }
        let driveError = error as? DriveError ?? .connectionFailed
        let updated: UploadItem
        do {
            updated = try await queue.recordFailure(item.id, code: driveError.code, rejected: !driveError.isRetryable, now: now())
        } catch {
            return .stop(.localStorageFailed(code: Self.code(of: error)), countsAsFailure: true)
        }
        onEvent?(.itemFinished(id: item.id, state: updated.state))
        if updated.state == .quarantined { return .quarantined }
        // A network-wide problem would fail the next items too: stop and retry later,
        // like the Android job. An item-specific failure lets the others go on.
        if driveError.isRetryable { return .stop(.retryLater(code: driveError.code), countsAsFailure: true) }
        return .failed
    }

    /// Not the item's fault: keep it pending without counting a failure.
    private static func stopsRun(_ error: Error) -> Bool {
        if error is CancellationError || error is PolicyStop { return true }
        guard let error = error as? DriveError else { return false }
        return error == .needsReauthorization || error == .tokenUnavailable
    }

    private func stopOutcome(for error: Error) -> ItemOutcome {
        if let stop = error as? PolicyStop { return .stop(.policy(stop.block), countsAsFailure: false) }
        if let error = error as? DriveError {
            if error == .needsReauthorization { return .stop(.needsReauthorization, countsAsFailure: false) }
            return .stop(.retryLater(code: error.code), countsAsFailure: false)
        }
        return .stop(.cancelled, countsAsFailure: false)
    }

    // MARK: - Policy

    private func checkpoint(_ trigger: SyncTrigger) async throws {
        try Task.checkCancellation()
        if let block = await policyBlock(trigger) { throw PolicyStop(block: block) }
    }

    private func policyBlock(_ trigger: SyncTrigger) async -> SyncSummary.PolicyBlock? {
        let network = await conditions()
        let current = now()
        let allowed = SyncPolicy.allowed(
            manual: trigger.isManual, wifi: network.wifi, online: network.online,
            requestedAt: trigger.requestedAt ?? current, now: current
        )
        if allowed { return nil }
        if !network.online { return .offline }
        return trigger.isManual ? .manualWindowExpired : .waitingForWiFi
    }

    private static func stopReason(forFolderError error: Error) -> SyncSummary.StopReason {
        if error is CancellationError { return .cancelled }
        if let error = error as? DriveError {
            if error == .needsReauthorization { return .needsReauthorization }
            if error.isRetryable { return .retryLater(code: error.code) }
            return .folderUnavailable(code: error.code)
        }
        return .localStorageFailed(code: code(of: error))
    }

    private static func code(of error: Error) -> String {
        if let error = error as? UploadQueueError { return error.code }
        if let error = error as? DriveError { return error.code }
        return "local-storage-failed"
    }
}
