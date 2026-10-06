import AVFoundation
import XCTest
@testable import Captura

/// Rotation, interruption and state logic with a fake engine, fake session and
/// fake chunk files. No microphone, no network.
@MainActor
final class RecorderControllerTests: XCTestCase {
    private var root: URL!
    private var directory: URL!
    private var session: FakeRecordingSession!
    private var engines: [FakeAudioCaptureEngine] = []
    private var factory: FakeChunkFileFactory!
    private var center: NotificationCenter!
    private var clock: TestClock!
    private var foreground = true
    private var engineStartError: Error?
    private var closedReports: [URL] = []

    override func setUp() async throws {
        root = try RecorderFixtures.temporaryDirectory()
        directory = root.appendingPathComponent("Recordings", isDirectory: true)
        session = FakeRecordingSession()
        engines = []
        factory = FakeChunkFileFactory()
        center = NotificationCenter()
        clock = TestClock()
        foreground = true
        engineStartError = nil
        closedReports = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var engine: FakeAudioCaptureEngine { engines.last! }

    private func makeController(chunkDuration: TimeInterval = 60) -> RecorderController {
        let clock = self.clock!
        let controller = RecorderController(
            directory: directory,
            chunkDuration: chunkDuration,
            session: session,
            makeEngine: { [unowned self] in
                let engine = FakeAudioCaptureEngine()
                engine.startError = self.engineStartError
                self.engines.append(engine)
                return engine
            },
            fileFactory: factory,
            notificationCenter: center,
            isAppInForeground: { [unowned self] in self.foreground },
            now: { clock.now() }
        )
        controller.onChunkClosed = { [unowned self] in self.closedReports.append($0) }
        return controller
    }

    private func recording(chunkDuration: TimeInterval = 60) async throws -> RecorderController {
        let controller = makeController(chunkDuration: chunkDuration)
        try await controller.start()
        return controller
    }

    private func post(_ name: Notification.Name, _ userInfo: [AnyHashable: Any]? = nil) {
        center.post(name: name, object: nil, userInfo: userInfo)
    }

    private func postInterruptionBegan() {
        post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    }

    private func postInterruptionEnded(shouldResume: Bool) {
        post(AVAudioSession.interruptionNotification, [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0,
        ])
    }

    private func postRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        post(AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }

    private func partials() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".partial") }
    }

    // MARK: - Start and permission

    func testStartRequestsPermissionWhenUndetermined() async throws {
        session.permission = .undetermined
        let controller = makeController()
        try await controller.start()
        XCTAssertEqual(session.requestCount, 1)
        XCTAssertEqual(controller.permission, .granted)
    }

    func testStartDoesNotAskAgainWhenAlreadyGranted() async throws {
        _ = try await recording()
        XCTAssertEqual(session.requestCount, 0)
    }

    func testDeniedPermissionThrowsAndNeverTouchesMicrophone() async throws {
        session.permission = .undetermined
        session.permissionAfterRequest = .denied
        let controller = makeController()
        do {
            try await controller.start()
            XCTFail("start must throw")
        } catch {
            XCTAssertEqual(error as? RecorderError, .microphoneDenied)
        }
        XCTAssertEqual(controller.permission, .denied)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(session.activateCount, 0)
        XCTAssertTrue(engines.isEmpty)
    }

    func testDeniedPermissionMessagePointsToSettings() {
        XCTAssertTrue(RecorderError.microphoneDenied.errorDescription!.contains("Ajustes"))
        XCTAssertNotNil(RecorderController.settingsURL)
    }

    func testStartFromBackgroundIsRefused() async throws {
        foreground = false
        let controller = makeController()
        do {
            try await controller.start()
            XCTFail("start must throw")
        } catch {
            XCTAssertEqual(error as? RecorderError, .mustStartInForeground)
        }
        XCTAssertEqual(session.activateCount, 0)
    }

    func testStartActivatesSessionAndStartsEngineInRecordingFormat() async throws {
        let controller = try await recording()
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.format?.sampleRate, 44_100)
        XCTAssertEqual(engine.format?.channelCount, 1)
        XCTAssertEqual(controller.state, .recording(startedAt: RecorderFixtures.fixedDate, chunkStartedAt: RecorderFixtures.fixedDate))
    }

    func testStartWhileRecordingIsANoOp() async throws {
        let controller = try await recording()
        try await controller.start()
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(engine.startCount, 1)
    }

    func testSessionActivationFailureFailsVisibly() async throws {
        session.activationError = FakeRecordingSession.Failure()
        let controller = makeController()
        do {
            try await controller.start()
            XCTFail("start must throw")
        } catch {}
        guard case .failed(let message) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertFalse(message.isEmpty)
    }

    func testEngineStartFailureReleasesSession() async throws {
        engineStartError = FakeAudioCaptureEngine.Failure()
        let controller = makeController()
        do {
            try await controller.start()
            XCTFail("start must throw")
        } catch {}
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(session.deactivateCount, 1)
        XCTAssertEqual(controller.state.phase, .failed)
    }

    func testFailedRecorderCanBeStartedAgain() async throws {
        session.activationError = FakeRecordingSession.Failure()
        let controller = makeController()
        try? await controller.start()
        session.activationError = nil
        try await controller.start()
        XCTAssertTrue(controller.state.isRecording)
    }

    // MARK: - Chunks

    func testAudioIsWrittenToPartialFileWhileRecording() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        await controller.drainPendingWrites()
        XCTAssertEqual(try partials().count, 1)
        XCTAssertTrue(controller.closedChunks().isEmpty)
        XCTAssertTrue(closedReports.isEmpty)
    }

    func testStopClosesChunkReportsItAndReleasesMicrophone() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        let url = await controller.stop()
        await controller.drainPendingWrites()
        XCTAssertNotNil(url)
        XCTAssertEqual(closedReports, [url!])
        XCTAssertEqual(controller.closedChunks(), [url!])
        XCTAssertEqual(try partials(), [])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(session.deactivateCount, 1)
    }

    func testStopWithoutAudioLeavesNoFile() async throws {
        let controller = try await recording()
        let url = await controller.stop()
        XCTAssertNil(url)
        XCTAssertTrue(controller.closedChunks().isEmpty)
        XCTAssertEqual(try partials(), [])
        XCTAssertTrue(closedReports.isEmpty)
    }

    func testRotationReportsEachClosedChunk() async throws {
        let controller = try await recording(chunkDuration: 1)
        engine.emit(seconds: 3.5)
        await controller.drainPendingWrites()
        XCTAssertEqual(closedReports.count, 3)
        XCTAssertTrue(controller.state.isRecording)
        await controller.stop()
        await controller.drainPendingWrites()
        XCTAssertEqual(closedReports.count, 4)
        XCTAssertEqual(Set(closedReports), Set(controller.closedChunks()))
    }

    func testRotationUpdatesChunkStartInState() async throws {
        let controller = try await recording(chunkDuration: 1)
        engine.emit(seconds: 1.5)
        await controller.drainPendingWrites()
        guard case .recording(let startedAt, let chunkStartedAt) = controller.state else { return XCTFail() }
        XCTAssertEqual(startedAt, RecorderFixtures.fixedDate)
        XCTAssertEqual(chunkStartedAt.timeIntervalSince(startedAt), 1, accuracy: 0.000_1)
    }

    func testRotationConservesAllFrames() async throws {
        let controller = try await recording(chunkDuration: 0.7)
        engine.emit(seconds: 4.2, bufferSeconds: 0.093)
        await controller.stop()
        let frames = factory.files.reduce(Int64(0)) { $0 + $1.frames }
        XCTAssertEqual(frames, Int64(RecorderFixtures.frames(seconds: 4.2)))
    }

    func testCutChunkClosesCurrentChunkAndKeepsRecording() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        let first = await controller.cutChunk()
        engine.emit(seconds: 0.5)
        await controller.drainPendingWrites()
        XCTAssertNotNil(first)
        XCTAssertTrue(controller.state.isRecording)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(try partials().count, 1)
        XCTAssertEqual(controller.closedChunks(), [first!])
    }

    func testCutChunkWhenIdleDoesNothing() async throws {
        let controller = makeController()
        let url = await controller.cutChunk()
        XCTAssertNil(url)
    }

    func testLateBufferFromAStoppedCaptureIsDropped() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.2)
        await controller.stop()
        try await controller.start()
        engine.emitLateBufferFromPreviousCapture(frames: 4410)
        await controller.drainPendingWrites()
        XCTAssertEqual(try partials(), [])
        XCTAssertEqual(controller.closedChunks().count, 1)
    }

    // MARK: - Failures

    func testCloseFailureQuarantinesChunkAndDoesNotReportIt() async throws {
        factory.behavior.failClose = true
        let controller = try await recording()
        engine.emit(seconds: 0.3)
        let url = await controller.stop()
        await controller.drainPendingWrites()
        XCTAssertNil(url)
        XCTAssertTrue(closedReports.isEmpty)
        XCTAssertTrue(controller.closedChunks().isEmpty)
        XCTAssertEqual(controller.quarantinedFiles().count, 1)
        XCTAssertEqual(controller.lastQuarantined, controller.quarantinedFiles().first)
    }

    func testWriteFailureStopsRecordingWithVisibleMessage() async throws {
        let controller = try await recording()
        factory.behavior.failWrites = true
        engine.emit(seconds: 0.1)
        await controller.drainPendingWrites()
        XCTAssertEqual(controller.state, .failed(message: RecorderMessages.writeFailed))
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(session.deactivateCount, 1)
    }

    // MARK: - Interruptions

    func testInterruptionClosesChunkAndEntersInterrupted() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        postInterruptionBegan()
        await controller.drainPendingWrites()
        XCTAssertEqual(controller.state, .interrupted)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(closedReports.count, 1)
        XCTAssertEqual(try partials(), [])
    }

    func testInterruptionEndWithShouldResumeContinuesInNewChunk() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        postInterruptionBegan()
        clock.advance(by: 120)
        postInterruptionEnded(shouldResume: true)
        engine.emit(seconds: 0.5)
        await controller.stop()
        await controller.drainPendingWrites()
        XCTAssertEqual(session.activateCount, 2)
        XCTAssertEqual(engine.startCount, 2)
        XCTAssertEqual(closedReports.count, 2)
        XCTAssertEqual(Set(closedReports).count, 2)
    }

    func testResumedRecordingKeepsOriginalStartTime() async throws {
        let controller = try await recording()
        postInterruptionBegan()
        clock.advance(by: 120)
        postInterruptionEnded(shouldResume: true)
        XCTAssertEqual(controller.state, .recording(
            startedAt: RecorderFixtures.fixedDate,
            chunkStartedAt: RecorderFixtures.fixedDate.addingTimeInterval(120)
        ))
    }

    func testInterruptionEndWithoutShouldResumeStaysInterrupted() async throws {
        let controller = try await recording()
        postInterruptionBegan()
        postInterruptionEnded(shouldResume: false)
        XCTAssertEqual(controller.state, .interrupted)
        XCTAssertEqual(session.activateCount, 1)
    }

    func testUserCanRestartFromInterrupted() async throws {
        let controller = try await recording()
        postInterruptionBegan()
        try await controller.start()
        XCTAssertTrue(controller.state.isRecording)
    }

    func testInterruptionAfterStopIsIgnored() async throws {
        let controller = try await recording()
        await controller.stop()
        postInterruptionBegan()
        postInterruptionEnded(shouldResume: true)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(session.activateCount, 1)
    }

    func testResumeRefusedInBackgroundWaitsForForeground() async throws {
        let controller = try await recording()
        postInterruptionBegan()
        foreground = false
        session.activationError = FakeRecordingSession.Failure()
        postInterruptionEnded(shouldResume: true)
        XCTAssertEqual(controller.state, .interrupted)

        foreground = true
        session.activationError = nil
        post(UIApplication.didBecomeActiveNotification)
        XCTAssertTrue(controller.state.isRecording)
    }

    func testForegroundWithoutPendingResumeDoesNotStartMicrophone() async throws {
        let controller = try await recording()
        postInterruptionBegan()
        post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(controller.state, .interrupted)
        XCTAssertEqual(session.activateCount, 1)
    }

    func testResumeRefusedInForegroundFailsVisibly() async throws {
        let controller = try await recording()
        postInterruptionBegan()
        session.activationError = FakeRecordingSession.Failure()
        postInterruptionEnded(shouldResume: true)
        XCTAssertEqual(controller.state, .failed(message: RecorderMessages.resumeFailed))
    }

    func testForegroundRefreshesPermission() async throws {
        let controller = try await recording()
        session.permission = .denied
        post(UIApplication.didBecomeActiveNotification)
        XCTAssertEqual(controller.permission, .denied)
    }

    // MARK: - Routes, media services, engine configuration

    func testLostInputRouteClosesChunkAndContinuesOnNewRoute() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        postRouteChange(.oldDeviceUnavailable)
        engine.emit(seconds: 0.5)
        await controller.drainPendingWrites()
        XCTAssertTrue(controller.state.isRecording)
        XCTAssertEqual(engine.startCount, 2)
        XCTAssertEqual(closedReports.count, 1)
        XCTAssertEqual(try partials().count, 1)
    }

    func testLostInputWithoutAnyInputEntersInterrupted() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        session.isInputAvailable = false
        postRouteChange(.oldDeviceUnavailable)
        await controller.drainPendingWrites()
        XCTAssertEqual(controller.state, .interrupted)
        XCTAssertEqual(closedReports.count, 1)
    }

    func testBenignRouteChangeKeepsTheSameChunk() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        postRouteChange(.categoryChange)
        engine.emit(seconds: 0.5)
        await controller.drainPendingWrites()
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertTrue(closedReports.isEmpty)
    }

    func testMediaServicesResetRebuildsEngineAndSessionInNewChunk() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        let original = engine
        post(AVAudioSession.mediaServicesWereResetNotification)
        engine.emit(seconds: 0.5)
        await controller.drainPendingWrites()
        XCTAssertEqual(engines.count, 2)
        XCTAssertFalse(original.isRunning)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(session.activateCount, 2)
        XCTAssertTrue(controller.state.isRecording)
        XCTAssertEqual(closedReports.count, 1)
    }

    func testMediaServicesResetWhileIdleDoesNotRecord() async throws {
        let controller = makeController()
        post(AVAudioSession.mediaServicesWereResetNotification)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(engines.isEmpty)
        XCTAssertEqual(session.activateCount, 0)
    }

    func testEngineConfigurationChangeRestartsInNewChunk() async throws {
        let controller = try await recording()
        engine.emit(seconds: 0.5)
        engine.onConfigurationChange?()
        engine.emit(seconds: 0.5)
        await controller.drainPendingWrites()
        XCTAssertEqual(engine.startCount, 2)
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(closedReports.count, 1)
        XCTAssertTrue(controller.state.isRecording)
    }

    // MARK: - Launch recovery and queries

    func testLaunchQuarantinesLeftoverPartialFiles() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leftover = directory.appendingPathComponent("personal-capture-20261006-010000-00000000-0000-0000-0000-000000000001.m4a.partial")
        try Data("fictional interrupted chunk".utf8).write(to: leftover)
        let controller = makeController()
        XCTAssertEqual(controller.recoveredOnLaunch.map(\.lastPathComponent), [leftover.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(controller.closedChunks().isEmpty)
        XCTAssertEqual(controller.quarantinedFiles().map(\.lastPathComponent), [leftover.lastPathComponent])
    }

    func testElapsedCountsFromWhenUserPressedRecord() async throws {
        let controller = try await recording()
        clock.advance(by: 42)
        XCTAssertEqual(controller.elapsed(), 42, accuracy: 0.001)
    }

    func testElapsedIsZeroWhenIdle() async throws {
        let controller = try await recording()
        clock.advance(by: 10)
        await controller.stop()
        XCTAssertEqual(controller.elapsed(), 0)
    }

    func testChunkElapsedRestartsAfterCut() async throws {
        let controller = try await recording()
        clock.advance(by: 30)
        await controller.cutChunk()
        clock.advance(by: 5)
        XCTAssertEqual(controller.chunkElapsed(), 5, accuracy: 0.001)
        XCTAssertEqual(controller.elapsed(), 35, accuracy: 0.001)
    }

    func testDefaultChunkDurationIsFifteenMinutes() {
        let controller = RecorderController(directory: directory, session: session, notificationCenter: center)
        XCTAssertEqual(controller.chunkDuration, 15 * 60)
    }
}
