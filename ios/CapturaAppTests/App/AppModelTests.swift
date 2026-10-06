import CapturaCore
import Foundation
import XCTest
@testable import Captura

/// The app model with a fake microphone, a real queue and settings on temporary
/// directories, and fake or in-memory Google/Drive. No network, no real account.
@MainActor
final class AppModelTests: XCTestCase {
    private var harness: AppModelHarness?

    override func tearDown() async throws {
        if let harness {
            await harness.model.stopRecording()
            await harness.model.waitUntilIdle()
            harness.cleanUp()
        }
        harness = nil
        try await super.tearDown()
    }

    private func make(
        linked: Bool = true,
        network: NetworkConditions = .onWiFi,
        automatic: Bool = false,
        sync: SyncService? = nil,
        makeSync: ((UploadQueue, SyncSettingsStore, GoogleSignInController) -> SyncService)? = nil,
        authResponses: [HTTPResponse] = [],
        prepare: ((SyncSettingsStore) throws -> Void)? = nil
    ) throws -> AppModelHarness {
        let made = try AppModelHarness(
            linked: linked, network: network, automatic: automatic, sync: sync, makeSync: makeSync,
            authResponses: authResponses, prepare: prepare
        )
        harness = made
        return made
    }

    // MARK: - Chunk intake

    func testClosedChunkIsQueuedAsPendingWithItsChecksums() async throws {
        let h = try make()
        try await h.recordAndStop(seconds: 3)

        let items = await h.queue.items()
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.state, .pending)
        XCTAssertTrue(CaptureNaming.isChunkName(item.fileName))
        let file = h.recordings.appendingPathComponent(item.fileName)
        XCTAssertEqual(item.checksums, try Checksums.compute(fileAt: file))
        XCTAssertEqual(h.model.counts.pending, 1)
        XCTAssertEqual(h.model.recordings.map(\.status), [.pending])
    }

    func testRecordingNeverUploadsWithoutTheOptIn() async throws {
        let fake = FakeSyncService()
        let h = try make(network: .onWiFi, automatic: false, sync: fake)
        try await h.recordAndStop()
        XCTAssertEqual(fake.runs, [])
        XCTAssertEqual(h.model.counts.pending, 1)
    }

    // MARK: - Automatic sync (opt-in, Wi-Fi only)

    func testAutomaticSyncRunsOnWiFiAfterAChunkCloses() async throws {
        let fake = FakeSyncService()
        let h = try make(network: .onWiFi, automatic: true, sync: fake)
        fake.completesUploadsIn = h.queue
        try await h.recordAndStop()
        XCTAssertEqual(fake.runs, [.automatic])
        XCTAssertEqual(h.model.counts.verified, 1)
        XCTAssertEqual(h.model.counts.pending, 0)
    }

    func testAutomaticSyncWaitsOnCellularAndRunsWhenWiFiReturns() async throws {
        let fake = FakeSyncService()
        let h = try make(network: .onCellular, automatic: true, sync: fake)
        fake.completesUploadsIn = h.queue
        try await h.recordAndStop()
        XCTAssertEqual(fake.runs, [], "no cellular fallback for automatic transfers")
        XCTAssertNil(h.model.plannedTrigger())

        h.network.change(to: .onWiFi)
        await h.model.waitUntilIdle()
        XCTAssertEqual(fake.runs, [.automatic])
    }

    func testAutomaticSyncCannotBeEnabledBeforeLinkingDrive() throws {
        let h = try make(linked: false)
        h.model.setAutomaticSync(true)
        XCTAssertFalse(h.model.settings.automaticSync)
        XCTAssertEqual(h.model.syncMessage, "Primero vinculá Google Drive.")
    }

    func testAutomaticSyncChoiceSurvivesRestart() throws {
        let h = try make()
        h.model.setAutomaticSync(true)
        XCTAssertTrue(SyncSettingsStore(directory: h.root.appendingPathComponent("Sync")).current.automaticSync)
    }

    // MARK: - Manual sync ("Sincronizar ahora")

    func testManualSyncOnCellularRunsWithTheManualTrigger() async throws {
        let fake = FakeSyncService()
        let h = try make(network: .onCellular, automatic: false, sync: fake)
        fake.completesUploadsIn = h.queue
        try h.writeClosedChunk()
        await h.model.syncNow()
        await h.model.waitUntilIdle()

        XCTAssertEqual(fake.runs, [.manual(requestedAt: h.clock.now())])
        XCTAssertEqual(h.model.counts.verified, 1)
        XCTAssertNil(h.model.settings.manualRequestedAt, "everything is up: the cellular allowance ends")
    }

    func testManualWindowAllowsAnyNetworkForThirtyMinutesOnly() throws {
        let requested = RecorderFixtures.fixedDate.addingTimeInterval(-10 * 60)
        let h = try make(network: .onCellular, automatic: false, prepare: { settings in
            try settings.update { $0.manualRequestedAt = requested }
        })
        XCTAssertEqual(h.model.plannedTrigger(), .manual(requestedAt: requested))
        h.clock.advance(by: 21 * 60)
        XCTAssertNil(h.model.plannedTrigger(), "31 minutes after the request, cellular is not allowed")
    }

    func testManualSyncWhileRecordingCutsTheChunkAndKeepsRecording() async throws {
        let fake = FakeSyncService()
        let h = try make(network: .onWiFi, sync: fake)
        await h.model.startRecording()
        h.engine?.emit(seconds: 3)
        await h.recorder.drainPendingWrites()

        await h.model.syncNow()
        await h.model.waitUntilIdle()

        XCTAssertTrue(h.recorder.state.isRecording, "Sincronizar ahora never stops the recording")
        let items = await h.queue.items()
        XCTAssertEqual(items.count, 1, "the chunk recorded so far was closed and queued")
        XCTAssertEqual(fake.runs.first, .manual(requestedAt: h.clock.now()))
    }

    func testManualSyncBeforeLinkingAsksToLinkFirst() async throws {
        let fake = FakeSyncService()
        let h = try make(linked: false, sync: fake)
        await h.model.syncNow()
        XCTAssertEqual(fake.runs, [])
        XCTAssertEqual(h.model.syncMessage, "Primero vinculá Google Drive.")
    }

    // MARK: - Google link

    func testLinkingDriveEnsuresTheFolderRightAway() async throws {
        let fake = FakeSyncService()
        let h = try make(linked: false, sync: fake, authResponses: [AppAuthFixtures.tokenResponse()])
        let storage = h.settings.folderIDStorage
        fake.onEnsureFolder = { id in try await storage.save(id) }

        await h.model.linkDrive()

        XCTAssertEqual(h.auth.status, .signedIn(email: AppAuthFixtures.email))
        XCTAssertEqual(fake.ensureFolderCount, 1)
        XCTAssertEqual(h.model.settings.folderID, "fixtureFolder0001")
        XCTAssertTrue(h.model.syncMessage.contains("está lista"), h.model.syncMessage)
        XCTAssertEqual(fake.runs, [], "linking alone never uploads")
    }

    func testLinkingCreatesThePrivateInboxTheWorkerProbes() async throws {
        let drive = MiniDriveFolderServer()
        let h = try make(linked: false, makeSync: { queue, settings, auth in
            DriveSyncService(
                queue: queue,
                deviceID: settings.current.deviceID,
                folderStorage: settings.folderIDStorage,
                conditions: { .onCellular },
                token: DriveTokenSource.make(auth.tokenProvider!),
                makeTransport: { _ in drive },
                now: { RecorderFixtures.fixedDate }
            )
        }, authResponses: [AppAuthFixtures.tokenResponse()])

        await h.model.linkDrive()

        let folderID = try XCTUnwrap(h.model.settings.folderID)
        let folder = try XCTUnwrap(drive.folder(folderID))
        XCTAssertEqual(folder["mimeType"] as? String, DriveMetadata.folderMimeType)
        XCTAssertEqual(folder["name"] as? String, CaptureNaming.folderName)
        let properties = try XCTUnwrap(folder["properties"] as? [String: String])
        XCTAssertEqual(properties[DriveMetadata.inboxPropertyKey], "1")
        XCTAssertEqual(properties[DriveMetadata.devicePropertyKey], h.settings.current.deviceID)
        // Saved durably before the folder was created.
        XCTAssertEqual(SyncSettingsStore(directory: h.root.appendingPathComponent("Sync")).current.folderID, folderID)
        XCTAssertEqual(drive.requestLog, ["GET /drive/v3/files/generateIds", "POST /drive/v3/files", "GET /drive/v3/files/\(folderID)"])
    }

    func testRevokedGrantDuringSyncShowsSignedOutAndKeepsTheAudio() async throws {
        let invalidGrant = HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        let h = try make(network: .onWiFi, automatic: true, makeSync: { queue, settings, auth in
            DriveSyncService(
                queue: queue,
                deviceID: settings.current.deviceID,
                folderStorage: settings.folderIDStorage,
                conditions: { .onWiFi },
                token: DriveTokenSource.make(auth.tokenProvider!),
                makeTransport: { _ in UnreachableTransport() },
                now: { RecorderFixtures.fixedDate }
            )
        }, authResponses: [invalidGrant])
        try h.writeClosedChunk()
        await h.model.refreshLibrary()
        XCTAssertEqual(h.auth.status, .signedIn(email: AppAuthFixtures.email))

        await h.model.syncNow()
        await h.model.waitUntilIdle()

        XCTAssertEqual(h.auth.status, .signedOut)
        XCTAssertTrue(h.model.driveNeedsRelink)
        XCTAssertTrue(h.model.syncMessage.contains("Volvé a vincular Google Drive"), h.model.syncMessage)
        XCTAssertFalse(h.model.settings.automaticSync, "opt-in is asked again after relinking")
        let items = await h.queue.items()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.state, .pending)
        XCTAssertEqual(item.attempts, 0, "a revoked grant is not the audio's fault")
    }

    func testUnlinkingTurnsAutomaticSyncOff() async throws {
        let h = try make(automatic: true)
        await h.model.unlinkDrive()
        XCTAssertEqual(h.auth.status, .signedOut)
        XCTAssertFalse(h.model.settings.automaticSync)
        XCTAssertNil(try h.tokenStore.load())
    }

    // MARK: - Account changes

    private static let sessionA = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=fixtureSessionA")!

    /// A queued chunk with a Drive ID and an upload session started for account A.
    private func partiallyUploadedChunk(_ h: AppModelHarness) async throws -> String {
        let id = try h.writeClosedChunk().lastPathComponent
        await h.model.refreshLibrary()
        try await h.queue.assignDriveFileID("fixtureDriveFileA0001", to: id)
        try await h.queue.setSessionURI(Self.sessionA, for: id)
        return id
    }

    private func ownedByAccountA(_ settings: SyncSettingsStore) throws {
        try settings.update {
            $0.folderID = "fixtureFolderA001"
            $0.driveAccountEmail = AppAuthFixtures.email
        }
    }

    /// Drive refused the grant mid-sync: "Volver a vincular" is shown, account A still stored.
    private func requireRelink(_ h: AppModelHarness, _ fake: FakeSyncService) async {
        var reauth = SyncSummary()
        reauth.stopReason = .needsReauthorization
        fake.summary = reauth
        h.model.requestSync()
        await h.model.waitUntilIdle()
        XCTAssertTrue(h.model.driveNeedsRelink)
        XCTAssertEqual(h.model.linkedEmail, AppAuthFixtures.email)
        fake.summary = SyncSummary()
    }

    func testLinkingAnotherAccountWithdrawsConsentAndForgetsTheOldAccountsDriveState() async throws {
        let fake = FakeSyncService()
        let h = try make(network: .onWiFi, automatic: true, sync: fake, authResponses: [
            AppAuthFixtures.tokenResponse(email: "beto@otra.test", refreshToken: "fixture-beto"), HTTPResponse(status: 200),
        ], prepare: ownedByAccountA)
        let storage = h.settings.folderIDStorage
        fake.onEnsureFolder = { id in try await storage.save(id) }
        let id = try await partiallyUploadedChunk(h)
        await requireRelink(h, fake)
        let runsBefore = fake.runs.count

        await h.model.linkDrive()
        await h.model.waitUntilIdle()

        XCTAssertEqual(h.model.linkedEmail, "beto@otra.test")
        XCTAssertFalse(h.model.settings.automaticSync, "the opt-in was confirmed for the other account")
        XCTAssertEqual(h.model.settings.driveAccountEmail, "beto@otra.test")
        XCTAssertEqual(h.model.settings.folderID, "fixtureFolder0001", "a folder of the new account, not account A's")
        XCTAssertEqual(Array(fake.runs.dropFirst(runsBefore)), [], "nothing uploads without a new opt-in")
        let item = await h.queue.item(id: id)
        XCTAssertNil(item?.driveFileID)
        let session = await h.queue.sessionURI(for: id)
        XCTAssertNil(session)
        let revoke = h.authTransport.requests.last
        XCTAssertEqual(revoke?.url.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(revoke?.appFormFields["token"], "fixture-refresh", "account A's grant is revoked")
        XCTAssertTrue(h.model.syncMessage.contains("otra cuenta"), h.model.syncMessage)
    }

    func testRelinkingTheSameAccountKeepsConsentFolderAndUploads() async throws {
        let fake = FakeSyncService()
        fake.folder = .success(DriveFolderResolution(id: "fixtureFolderA001", outcome: .reused))
        let h = try make(network: .onWiFi, automatic: true, sync: fake, authResponses: [
            AppAuthFixtures.tokenResponse(refreshToken: "fixture-ana-new"),
        ], prepare: ownedByAccountA)
        let id = try await partiallyUploadedChunk(h)
        await requireRelink(h, fake)

        await h.model.linkDrive()
        await h.model.waitUntilIdle()

        XCTAssertTrue(h.model.settings.automaticSync)
        XCTAssertEqual(h.model.settings.folderID, "fixtureFolderA001")
        let item = await h.queue.item(id: id)
        XCTAssertEqual(item?.driveFileID, "fixtureDriveFileA0001")
        XCTAssertEqual(h.authTransport.requests.count, 1, "only the code exchange; no revocation")
    }

    func testUnlinkingForgetsUploadSessionsButKeepsTheFolderOfThatAccount() async throws {
        let h = try make(automatic: true, prepare: ownedByAccountA)
        let id = try await partiallyUploadedChunk(h)

        await h.model.unlinkDrive()

        let session = await h.queue.sessionURI(for: id)
        XCTAssertNil(session, "an upload session is a capability of the unlinked grant")
        let item = await h.queue.item(id: id)
        XCTAssertEqual(item?.driveFileID, "fixtureDriveFileA0001", "kept for the same account; another one resets it")
        XCTAssertEqual(h.model.settings.folderID, "fixtureFolderA001")
        XCTAssertEqual(h.model.settings.driveAccountEmail, AppAuthFixtures.email)
    }

    func testDriveStateOfAnotherAccountIsForgottenBeforeAnySync() async throws {
        // A link that switched accounts and stopped before the old state was reset.
        let fake = FakeSyncService()
        let h = try make(network: .onWiFi, automatic: true, sync: fake, prepare: { settings in
            try settings.update {
                $0.folderID = "fixtureFolderB001"
                $0.driveAccountEmail = "beto@otra.test"
            }
        })
        let id = try await partiallyUploadedChunk(h)
        XCTAssertNil(h.model.plannedTrigger(), "nothing runs with another account's Drive state")

        await h.model.sceneBecameActive()
        await h.model.waitUntilIdle()

        XCTAssertEqual(fake.runs, [])
        XCTAssertFalse(h.model.settings.automaticSync)
        XCTAssertEqual(h.model.settings.driveAccountEmail, AppAuthFixtures.email)
        XCTAssertNotEqual(h.model.settings.folderID, "fixtureFolderB001")
        let item = await h.queue.item(id: id)
        XCTAssertNil(item?.driveFileID)
    }

    // MARK: - Review queue

    func testRetryingQuarantinedAudioPutsItBackInTheQueue() async throws {
        let h = try make()
        let url = try h.writeClosedChunk()
        await h.model.refreshLibrary()
        try await h.queue.quarantine(url.lastPathComponent, code: "changed-audio")
        await h.model.refreshLibrary()
        XCTAssertEqual(h.model.counts.quarantined, 1)
        XCTAssertEqual(h.model.recordings.first?.status, .review(code: "changed-audio"))

        await h.model.retryQuarantined()
        await h.model.waitUntilIdle()
        XCTAssertEqual(h.model.counts.quarantined, 0)
        XCTAssertEqual(h.model.counts.pending, 1)
    }

    // MARK: - Background time

    func testLeavingTheAppMidUploadAsksForTimeAndExpiryStopsCleanly() async throws {
        let blocking = BlockingSyncService()
        let h = try make(network: .onWiFi, automatic: true, sync: blocking)
        try h.writeClosedChunk()
        await h.model.refreshLibrary()
        h.model.requestSync()
        await blocking.waitUntilRunning()

        h.model.sceneEnteredBackground()
        XCTAssertEqual(h.background.begun.count, 1)
        XCTAssertEqual(h.background.scheduledProcessing, 1, "pending audio asks iOS for a later wake-up")

        h.background.expire()
        await h.model.waitUntilIdle()
        XCTAssertTrue(blocking.wasCancelled)
        XCTAssertEqual(h.background.ended.count, 1)
        XCTAssertFalse(h.model.isSyncing)
    }

    func testLeavingTheAppWhileRecordingNeedsNoExtraTime() async throws {
        let blocking = BlockingSyncService()
        let h = try make(network: .onWiFi, automatic: true, sync: blocking)
        try h.writeClosedChunk()
        await h.model.startRecording()
        await h.model.refreshLibrary()
        h.model.requestSync()
        await blocking.waitUntilRunning()

        h.model.sceneEnteredBackground()
        XCTAssertEqual(h.background.begun, [], "background audio keeps the app running")

        await h.model.stopRecording()
        XCTAssertEqual(h.background.begun.count, 1, "once recording stops, the running upload asks for time")
        h.background.expire()
        await h.model.waitUntilIdle()
        XCTAssertTrue(blocking.wasCancelled)
    }

    // MARK: - Intents

    func testStopFromAnIntentReportsWhetherItWasRecording() async throws {
        let h = try make()
        let stoppedIdle = await h.model.stopRecording()
        XCTAssertFalse(stoppedIdle)
        await h.model.startRecordingFromIntent()
        XCTAssertTrue(h.recorder.state.isRecording)
        h.engine?.emit(seconds: 2)
        await h.recorder.drainPendingWrites()
        let stopped = await h.model.stopRecording()
        XCTAssertTrue(stopped)
    }
}
