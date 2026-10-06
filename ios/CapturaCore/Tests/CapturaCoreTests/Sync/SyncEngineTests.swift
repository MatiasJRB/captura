import XCTest
@testable import CapturaCore

final class SyncEngineTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var captures: URL!
    private var server: FakeDriveServer!
    private var env: Environment!
    private var folders: FolderBox!
    private var queue: UploadQueue!
    private let quarter = Int64(DriveClient.chunkGranularity)

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
        captures = try temp.subdirectory("captures")
        server = FakeDriveServer()
        env = Environment()
        folders = FolderBox()
        queue = try UploadQueue(storeDirectory: try temp.subdirectory("store"), capturesRoot: captures)
    }

    override func tearDown() {
        queue = nil
        temp = nil
    }

    private func makeEngine(chunkSize: Int64 = DriveClient.defaultChunkSize, onEvent: (@Sendable (SyncEvent) -> Void)? = nil) -> SyncEngine {
        let env = self.env!
        return SyncEngine(
            queue: queue, drive: makeClient(server, chunkSize: chunkSize), deviceID: Fixture.deviceID,
            folderStorage: folders.storage, conditions: { env.conditions }, now: { env.now }, onEvent: onEvent
        )
    }

    @discardableResult
    private func record(_ index: Int, bytes: Int = 6_000, name: String? = nil) throws -> URL {
        try Fixture.write(Fixture.bytes(bytes, seed: UInt8(index % 250)), named: name ?? Fixture.chunkName(index), in: captures)
    }

    private func item(_ index: Int) async -> UploadItem? {
        await queue.item(id: Fixture.chunkName(index))
    }

    private func requests(_ entry: String) -> Int {
        server.requestLog.filter { $0 == entry }.count
    }

    // MARK: Happy path

    func testQueuedChunksAreUploadedAndVerified() async throws {
        let url = try record(1)
        try record(2)

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.uploaded, 2)
        XCTAssertEqual(summary.remaining, 0)
        XCTAssertNil(summary.stopReason)
        XCTAssertEqual(summary.statusMessage, "Sincronizado · originales conservados en el teléfono.")
        let first = await item(1)
        XCTAssertEqual(first?.state, .verified)
        XCTAssertEqual(server.content(of: try XCTUnwrap(first?.driveFileID)), try Data(contentsOf: url))
    }

    func testUploadedFilesPassTheWorkerAcceptanceRules() async throws {
        try record(1)
        try record(2, bytes: 700_000)
        _ = await makeEngine().run(.automatic)
        let folderID = try XCTUnwrap(folders.current)

        let folderMeta = try decode(XCTUnwrap(server.metadataJSON(of: folderID)))
        XCTAssertNoThrow(try WorkerContract.verifyFolder(folderMeta, expected: folderID))
        let ids = server.ids(withParent: folderID)
        XCTAssertEqual(ids.count, 2)
        for id in ids {
            let meta = try decode(XCTUnwrap(server.metadataJSON(of: id)))
            XCTAssertNoThrow(try WorkerContract.verifyAudio(meta, folderID: folderID))
            let downloaded = Checksums.compute(data: try XCTUnwrap(server.content(of: id)))
            XCTAssertNoThrow(try WorkerContract.validateBytes(downloaded, against: meta))
        }
    }

    func testOriginalsAreLeftUntouched() async throws {
        let url = try record(1)
        let before = try Data(contentsOf: url)
        _ = await makeEngine().run(.automatic)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testDictatedNoteIsUploadedWithItsCaptureKind() async throws {
        try record(1, name: Fixture.noteName)
        _ = await makeEngine().run(.automatic)
        let note = await queue.item(id: Fixture.noteName)
        let driveID = try XCTUnwrap(note?.driveFileID)
        let properties = server.metadataJSON(of: driveID)?["properties"] as? [String: String]
        XCTAssertEqual(properties?["captureKind"], "dictated_note")
    }

    func testFolderIsEnsuredOncePerRun() async throws {
        try record(1)
        try record(2)
        try record(3)
        _ = await makeEngine().run(.automatic)
        let folderID = try XCTUnwrap(folders.current)
        XCTAssertEqual(requests("GET /drive/v3/files/\(folderID)"), 1)
        XCTAssertEqual(requests("POST /drive/v3/files"), 1)
        XCTAssertEqual(server.folderIDs(), [folderID])
    }

    func testStoredFolderIsReusedOnTheNextRun() async throws {
        try record(1)
        let first = await makeEngine().run(.automatic)
        try record(2)
        let second = await makeEngine().run(.automatic)
        XCTAssertEqual(first.folder?.outcome, .created)
        XCTAssertEqual(second.folder, DriveFolderResolution(id: try XCTUnwrap(folders.current), outcome: .reused))
        XCTAssertEqual(server.folderIDs().count, 1)
    }

    func testEventsReportFolderProgressAndResult() async throws {
        try record(1)
        let events = EventLog()
        _ = await makeEngine { events.append($0) }.run(.automatic)
        let id = Fixture.chunkName(1)
        XCTAssertEqual(events.values.first, .folderReady(DriveFolderResolution(id: try XCTUnwrap(folders.current), outcome: .created)))
        XCTAssertTrue(events.values.contains(.itemStarted(id: id, fileName: id)))
        XCTAssertTrue(events.values.contains(.progress(id: id, confirmedBytes: 0, totalBytes: 6_000)))
        XCTAssertEqual(events.values.last, .itemFinished(id: id, state: .verified))
    }

    // MARK: Idempotency

    func testSecondRunUploadsNothingAgain() async throws {
        try record(1)
        try record(2)
        _ = await makeEngine().run(.automatic)
        let requestsAfterFirstRun = server.requestLog.count

        let second = await makeEngine().run(.manual(requestedAt: env.now))

        XCTAssertEqual(second.uploaded, 0)
        XCTAssertEqual(server.requestLog.count, requestsAfterFirstRun, "verified items never touch the network again")
        XCTAssertEqual(server.sessionCount, 2)
    }

    func testRemoteCopyLeftByAKilledRunIsAdoptedWithoutUploadingAgain() async throws {
        let url = try record(1)
        let item = try await queue.enqueue(fileAt: url, now: env.now)
        let client = makeClient(server)
        let folder = try await makeEngine().ensureFolder()
        let driveID = try await client.generateID()
        try await queue.assignDriveFileID(driveID, to: item.id)
        // The previous run uploaded the bytes, then died before saving "verified".
        try await client.upload(
            DriveUpload(fileID: driveID, name: item.fileName, fileURL: url, checksums: item.checksums),
            folderID: folder.id, session: nil, sessionChanged: { _ in }, checkpoint: { _ in }
        )

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(server.sessionCount, 1, "no second upload session")
        let stored = await queue.item(id: item.id)
        XCTAssertEqual(stored?.state, .verified)
        XCTAssertEqual(stored?.driveFileID, driveID)
    }

    // MARK: Interruption and resume

    func testDroppedConnectionResumesFromTheServerRangeOnTheNextRun() async throws {
        let url = try record(1, bytes: Int(2 * quarter + 5_000))
        server.inject(.dropNextChunk(persisting: Int(quarter)))
        let engine = makeEngine(chunkSize: quarter)

        let first = await engine.run(.automatic)
        let afterDrop = await item(1)
        env.now = env.now.addingTimeInterval(31)
        let second = await engine.run(.automatic)

        XCTAssertEqual(first.stopReason, .retryLater(code: "drive-connection-failed"))
        XCTAssertEqual(afterDrop?.state, .pending)
        XCTAssertNotNil(afterDrop?.sealedSessionURI)
        XCTAssertEqual(second.uploaded, 1)
        XCTAssertEqual(server.sessionCount, 1, "the stored session was resumed, not restarted")
        let uploadedID = await item(1)?.driveFileID
        XCTAssertEqual(server.content(of: try XCTUnwrap(uploadedID)), try Data(contentsOf: url))
    }

    func testRetryWaitsForBackoffOnAutomaticRuns() async throws {
        try record(1)
        server.inject(.dropNextChunk(persisting: 0))
        let engine = makeEngine()
        _ = await engine.run(.automatic)

        let tooEarly = await engine.run(.automatic)

        XCTAssertEqual(tooEarly.uploaded, 0)
        XCTAssertEqual(tooEarly.skippedBackoff, 1)
        XCTAssertEqual(tooEarly.remaining, 1)
    }

    func testManualRequestRetriesWithoutWaitingForBackoff() async throws {
        try record(1)
        server.inject(.dropNextChunk(persisting: 0))
        let engine = makeEngine()
        _ = await engine.run(.automatic)

        let manual = await engine.run(.manual(requestedAt: env.now))

        XCTAssertEqual(manual.uploaded, 1)
    }

    func testSessionExpiredMidUploadIsRestartedInTheSameRun() async throws {
        let url = try record(1, bytes: Int(quarter + 1_000))
        server.inject(.expireSessionOnNextChunk)

        let summary = await makeEngine(chunkSize: quarter).run(.automatic)

        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(server.sessionCount, 2)
        let uploadedID = await item(1)?.driveFileID
        XCTAssertEqual(server.content(of: try XCTUnwrap(uploadedID)), try Data(contentsOf: url))
    }

    func testCancellationKeepsTheItemPendingWithItsSession() async throws {
        try record(1, bytes: Int(2 * quarter + 1_000))
        let engine = makeEngine(chunkSize: quarter) { event in
            if case .progress(_, let confirmed, _) = event, confirmed > 0 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        let summary = await Task { await engine.run(.automatic) }.value
        let stored = await item(1)

        XCTAssertEqual(summary.stopReason, .cancelled)
        XCTAssertEqual(stored?.state, .pending)
        XCTAssertEqual(stored?.attempts, 0)
        XCTAssertNotNil(stored?.sealedSessionURI)
    }

    func testCancelledUploadResumesOnTheNextRun() async throws {
        let url = try record(1, bytes: Int(2 * quarter + 1_000))
        let cancelling = makeEngine(chunkSize: quarter) { event in
            if case .progress(_, let confirmed, _) = event, confirmed > 0 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        _ = await Task { await cancelling.run(.automatic) }.value

        let summary = await makeEngine(chunkSize: quarter).run(.automatic)

        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(server.sessionCount, 1)
        let uploadedID = await item(1)?.driveFileID
        XCTAssertEqual(server.content(of: try XCTUnwrap(uploadedID)), try Data(contentsOf: url))
    }

    // MARK: Network policy

    func testAutomaticRunOnCellularSendsNothing() async throws {
        try record(1)
        try record(2)
        env.conditions = NetworkConditions(online: true, wifi: false)

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.stopReason, .policy(.waitingForWiFi))
        XCTAssertEqual(summary.skippedByPolicy, 2)
        XCTAssertTrue(server.requestLog.isEmpty)
    }

    func testOfflineRunSendsNothing() async throws {
        try record(1)
        env.conditions = NetworkConditions(online: false, wifi: false)

        let summary = await makeEngine().run(.manual(requestedAt: env.now))

        XCTAssertEqual(summary.stopReason, .policy(.offline))
        XCTAssertEqual(summary.statusMessage, "Sin conexión. Los audios siguen en el teléfono.")
        XCTAssertTrue(server.requestLog.isEmpty)
    }

    func testManualRunMayUseCellularInsideItsWindow() async throws {
        try record(1)
        env.conditions = NetworkConditions(online: true, wifi: false)

        let summary = await makeEngine().run(.manual(requestedAt: env.now.addingTimeInterval(-29 * 60)))

        XCTAssertEqual(summary.uploaded, 1)
    }

    func testManualRunAfterItsWindowSendsNothing() async throws {
        try record(1)
        env.conditions = NetworkConditions(online: true, wifi: false)

        let summary = await makeEngine().run(.manual(requestedAt: env.now.addingTimeInterval(-31 * 60)))

        XCTAssertEqual(summary.stopReason, .policy(.manualWindowExpired))
        XCTAssertTrue(server.requestLog.isEmpty)
    }

    func testLosingWiFiStopsBeforeTheNextItem() async throws {
        try record(1)
        try record(2)
        let env = self.env!
        let engine = makeEngine { event in
            if case .itemFinished(_, .verified) = event { env.conditions = NetworkConditions(online: true, wifi: false) }
        }

        let summary = await engine.run(.automatic)

        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.skippedByPolicy, 1)
        XCTAssertEqual(summary.stopReason, .policy(.waitingForWiFi))
        let second = await item(2)
        XCTAssertEqual(second?.state, .pending)
        XCTAssertEqual(second?.attempts, 0)
    }

    func testEmptyQueueMakesNoRequests() async {
        let summary = await makeEngine().run(.automatic)
        XCTAssertTrue(server.requestLog.isEmpty)
        XCTAssertNil(summary.stopReason)
    }

    func testConcurrentRunIsRefused() async throws {
        try record(1)
        _ = await queue.claimRun()

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.stopReason, .alreadyRunning)
        XCTAssertTrue(server.requestLog.isEmpty)
    }

    // MARK: Failures

    func testRevokedAuthorizationStopsWithoutCountingFailures() async throws {
        try record(1)
        server.failEverything(status: 401)

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.stopReason, .needsReauthorization)
        XCTAssertEqual(summary.statusMessage, "Google requiere autorización. Volvé a vincular Google Drive.")
        let item1Attempts = await item(1)?.attempts
        XCTAssertEqual(item1Attempts, 0)
    }

    func testRevokedAuthorizationDuringAnUploadReleasesTheItem() async throws {
        try record(1)
        server.rejectUploads(named: Fixture.chunkName(1), status: 401)

        let summary = await makeEngine().run(.automatic)
        let stored = await item(1)

        XCTAssertEqual(summary.stopReason, .needsReauthorization)
        XCTAssertEqual(stored?.state, .pending)
        XCTAssertEqual(stored?.attempts, 0)
    }

    func testRateLimitStopsTheRunAndBacksOff() async throws {
        try record(1)
        try record(2)
        server.rejectUploads(named: Fixture.chunkName(1), status: 429)

        let summary = await makeEngine().run(.automatic)
        let first = await item(1)
        let second = await item(2)

        XCTAssertEqual(summary.stopReason, .retryLater(code: "drive-retry-later-429"))
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(first?.rejections, 0)
        XCTAssertEqual(first?.nextAttemptAt, env.now.addingTimeInterval(30))
        XCTAssertEqual(second?.attempts, 0, "a rate limit stops the run instead of hammering")
    }

    func testPermanentFailureDoesNotStarveOtherItems() async throws {
        try record(1)
        try record(2)
        server.rejectUploads(named: Fixture.chunkName(1), status: 400)

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.uploaded, 1)
        let item1LastError = await item(1)?.lastError
        XCTAssertEqual(item1LastError, "drive-http-400")
        let item2State = await item(2)?.state
        XCTAssertEqual(item2State, .verified)
    }

    func testThirdPermanentFailureQuarantinesTheItem() async throws {
        try record(1)
        server.rejectUploads(named: Fixture.chunkName(1), status: 400)
        let engine = makeEngine()

        var last = SyncSummary()
        for _ in 0..<3 { last = await engine.run(.manual(requestedAt: env.now)) }

        XCTAssertEqual(last.quarantined, 1)
        XCTAssertEqual(last.needsReview, 1)
        XCTAssertEqual(last.statusMessage, "Hay audios para revisar; originales conservados.")
        let item1State = await item(1)?.state
        XCTAssertEqual(item1State, .quarantined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captures.appending(component: Fixture.chunkName(1)).path))
    }

    func testChangedOriginalIsQuarantinedAndNeverUploaded() async throws {
        let url = try record(1)
        try await queue.enqueue(fileAt: url, now: env.now)
        try Fixture.bytes(6_000, seed: 200).write(to: url)

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.quarantined, 1)
        let item1LastError = await item(1)?.lastError
        XCTAssertEqual(item1LastError, "changed-audio")
        XCTAssertEqual(server.sessionCount, 0)
    }

    func testMissingOriginalIsQuarantined() async throws {
        let url = try record(1)
        try await queue.enqueue(fileAt: url, now: env.now)
        try FileManager.default.removeItem(at: url)

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.quarantined, 1)
        let item1LastError = await item(1)?.lastError
        XCTAssertEqual(item1LastError, "missing-audio")
    }

    func testRemoteReceiptMismatchIsRejectedNotVerified() async throws {
        let url = try record(1)
        let item1 = try await queue.enqueue(fileAt: url, now: env.now)
        let client = makeClient(server)
        let folder = try await makeEngine().ensureFolder()
        let driveID = try await client.generateID()
        try await queue.assignDriveFileID(driveID, to: item1.id)
        try await client.upload(
            DriveUpload(fileID: driveID, name: item1.fileName, fileURL: url, checksums: item1.checksums),
            folderID: folder.id, session: nil, sessionChanged: { _ in }, checkpoint: { _ in }
        )
        server.update(driveID) { $0["md5Checksum"] = String(repeating: "0", count: 32) }

        let summary = await makeEngine().run(.automatic)
        let stored = await item(1)

        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(stored?.state, .pending)
        XCTAssertEqual(stored?.lastError, "remote-receipt-mismatch")
        XCTAssertEqual(stored?.rejections, 1)
    }

    func testQueueThatCannotBeSavedStopsTheRunWithoutUploading() async throws {
        let url = try record(1)
        try await queue.enqueue(fileAt: url, now: env.now)
        let storeDirectory = queue.storeURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storeDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDirectory.path) }

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.stopReason, .localStorageFailed(code: "queue-write-failed"))
        XCTAssertEqual(server.sessionCount, 0, "nothing is uploaded unless its Drive ID could be saved first")
    }

    // MARK: Folder

    func testTrashedFolderIsReplacedAndReported() async throws {
        try record(1)
        _ = await makeEngine().run(.automatic)
        let oldFolder = try XCTUnwrap(folders.current)
        server.update(oldFolder) { $0["trashed"] = true }
        try record(2)

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.folder?.outcome, .replaced(previousID: oldFolder))
        XCTAssertNotEqual(folders.current, oldFolder)
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.statusMessage, "Se creó una carpeta nueva en Drive. Actualizá el folder_id en la Mac.")
    }

    func testSharedFolderStopsTheRunWithoutUploading() async throws {
        try record(1)
        _ = await makeEngine().run(.automatic)
        server.update(try XCTUnwrap(folders.current)) { $0["shared"] = true }
        try record(2)
        let sessionsBefore = server.sessionCount

        let summary = await makeEngine().run(.automatic)

        XCTAssertEqual(summary.stopReason, .folderUnavailable(code: "invalid-private-folder"))
        XCTAssertEqual(server.sessionCount, sessionsBefore)
        let item2Attempts = await item(2)?.attempts
        XCTAssertEqual(item2Attempts, 0)
    }

    func testEnsureFolderBeforeAnyRecordingCreatesTheInbox() async throws {
        let resolution = try await makeEngine().ensureFolder()
        XCTAssertEqual(resolution.outcome, .created)
        XCTAssertEqual(folders.current, resolution.id)
        XCTAssertEqual(server.folderIDs(), [resolution.id])
    }

    // MARK: Helpers

    private func decode(_ object: [String: Any]) throws -> DriveFileMetadata {
        try DriveFileMetadata.decode(JSONSerialization.data(withJSONObject: object))
    }
}

final class SyncSummaryTests: XCTestCase {
    func testPendingItemsMessage() {
        var summary = SyncSummary()
        summary.remaining = 2
        XCTAssertEqual(summary.statusMessage, "Quedan audios pendientes.")
    }

    func testWaitingForWiFiMessage() {
        var summary = SyncSummary()
        summary.stopReason = .policy(.waitingForWiFi)
        XCTAssertEqual(summary.statusMessage, "Esperando Wi-Fi para sincronizar. Los audios siguen en el teléfono.")
    }

    func testTransientFailureMessageMirrorsAndroid() {
        var summary = SyncSummary()
        summary.stopReason = .retryLater(code: "drive-connection-failed")
        XCTAssertEqual(summary.statusMessage, "No se pudo sincronizar. Los audios siguen en el teléfono. Reintentá o revisá la conexión a Google.")
    }

    func testExpiredManualRequestMessage() {
        var summary = SyncSummary()
        summary.stopReason = .policy(.manualWindowExpired)
        XCTAssertEqual(summary.statusMessage, "El pedido manual venció. Tocá Sincronizar ahora otra vez.")
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [SyncEvent] = []
    var values: [SyncEvent] { lock.withLock { log } }
    func append(_ event: SyncEvent) { lock.withLock { log.append(event) } }
}
