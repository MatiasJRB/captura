import CapturaCore
import XCTest
@testable import Captura

/// The local "Captura se pausó" notice, through the app model with a fake notifier,
/// fake microphone and fake chunk files. Nothing is shown and no microphone is used.
@MainActor
final class PauseNoticeTests: XCTestCase {
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

    private func make() throws -> AppModelHarness {
        let made = try AppModelHarness(linked: false)
        harness = made
        return made
    }

    /// Taps Grabar and waits for the notice permission check that follows a start.
    private func startRecording(_ h: AppModelHarness) async {
        await h.model.startRecording()
        await h.model.noticePermissionTask?.value
        XCTAssertTrue(h.recorder.state.isRecording, "state: \(h.recorder.state)")
    }

    /// Captura leaves the screen (another app, the lock screen or a call).
    private func leaveTheScreen(_ h: AppModelHarness) {
        h.appState.isForeground = false
        h.model.sceneEnteredBackground()
    }

    private func recordingInTheBackground() async throws -> AppModelHarness {
        let h = try make()
        await startRecording(h)
        leaveTheScreen(h)
        return h
    }

    // MARK: - Permission

    func testLaunchNeverAsksForNoticePermission() async throws {
        let h = try make()
        await h.model.sceneBecameActive()
        XCTAssertEqual(h.notices.prompts, 0)
        XCTAssertEqual(h.notices.permissionReads, 0)
    }

    func testFirstRecordingAsksForNoticesAfterTheMicrophonePermission() async throws {
        let h = try make()
        h.session.permission = .undetermined
        var microphoneAtPrompt: MicrophonePermission?
        var recordingAtPrompt: Bool?
        h.notices.onPrompt = {
            microphoneAtPrompt = h.recorder.permission
            recordingAtPrompt = h.recorder.state.isRecording
        }
        await startRecording(h)

        XCTAssertEqual(h.session.requestCount, 1)
        XCTAssertEqual(h.notices.prompts, 1)
        XCTAssertEqual(microphoneAtPrompt, .granted)
        XCTAssertEqual(recordingAtPrompt, true, "the prompt never delays the recording")
    }

    func testNoticePermissionIsAskedOnlyOnce() async throws {
        let h = try make()
        await startRecording(h)
        await h.model.stopRecording()
        await startRecording(h)
        XCTAssertEqual(h.notices.prompts, 1)
        XCTAssertEqual(h.notices.permissionReads, 2, "later starts only read the choice")
    }

    func testDeniedMicrophoneNeverAsksForNotices() async throws {
        let h = try make()
        h.session.permission = .undetermined
        h.session.permissionAfterRequest = .denied
        await h.model.startRecording()
        await h.model.noticePermissionTask?.value
        XCTAssertFalse(h.recorder.state.isRecording)
        XCTAssertEqual(h.notices.prompts, 0)
        XCTAssertEqual(h.notices.permissionReads, 0)
    }

    func testDeniedNoticesChangeNothingElse() async throws {
        let h = try make()
        h.notices.answer = .denied
        await startRecording(h)
        leaveTheScreen(h)

        h.recorder.handle(.interruptionBegan)
        XCTAssertEqual(h.recorder.state, .interrupted)
        XCTAssertTrue(h.notices.posted.isEmpty)
        XCTAssertNil(h.model.recorderMessage)

        h.recorder.handle(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(h.recorder.state.isRecording)
    }

    // MARK: - When a notice is posted

    func testInterruptionWhileOnScreenPostsNothing() async throws {
        let h = try make()
        await startRecording(h)
        h.recorder.handle(.interruptionBegan)
        XCTAssertEqual(h.recorder.state, .interrupted)
        XCTAssertTrue(h.notices.posted.isEmpty, "the status card already says it")
    }

    func testInterruptionInTheBackgroundIsNoticedRightAway() async throws {
        let h = try await recordingInTheBackground()
        h.recorder.handle(.interruptionBegan)
        let notice = try XCTUnwrap(h.notices.delivered)
        XCTAssertEqual(notice, PauseNotice(.interrupted))
        XCTAssertEqual(notice.title, "Captura se pausó")
        XCTAssertTrue(notice.body.hasSuffix("Abrí la app para seguir grabando."))
    }

    func testRecordingThatContinuesByItselfWithdrawsTheNotice() async throws {
        let h = try await recordingInTheBackground()
        h.recorder.handle(.interruptionBegan)
        XCTAssertNotNil(h.notices.delivered)
        h.recorder.handle(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(h.recorder.state.isRecording)
        XCTAssertNil(h.notices.delivered)
    }

    func testInterruptionThatCannotContinueAsksToOpenTheApp() async throws {
        let h = try await recordingInTheBackground()
        h.recorder.handle(.interruptionBegan)
        h.recorder.handle(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(h.recorder.state, .interrupted)
        XCTAssertEqual(h.notices.posted, [PauseNotice(.interrupted), PauseNotice(.waitingForTheApp)])
        let notice = try XCTUnwrap(h.notices.delivered)
        XCTAssertEqual("\(notice.title). \(notice.body)", "Captura se pausó. Abrí la app para seguir grabando.")
    }

    func testResumeRefusedInTheBackgroundAsksToOpenTheAppAndOpeningResumes() async throws {
        let h = try await recordingInTheBackground()
        h.recorder.handle(.interruptionBegan)
        h.session.activationError = FakeRecordingSession.Failure()
        h.recorder.handle(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(h.recorder.state, .interrupted)
        XCTAssertEqual(h.notices.delivered, PauseNotice(.waitingForTheApp))

        // Tapping the notice opens the app, which resumes the recording.
        h.session.activationError = nil
        h.appState.isForeground = true
        h.recorder.handle(.becameActive)
        await h.model.sceneBecameActive()
        XCTAssertTrue(h.recorder.state.isRecording)
        XCTAssertNil(h.notices.delivered)
    }

    func testOnePauseAlertsOncePerReason() async throws {
        let h = try await recordingInTheBackground()
        h.recorder.handle(.interruptionBegan)
        h.model.sceneEnteredBackground()
        XCTAssertEqual(h.notices.posted, [PauseNotice(.interrupted)])
    }

    func testPauseSeenOnScreenIsNoticedWhenCapturaLeavesTheScreen() async throws {
        let h = try make()
        await startRecording(h)
        h.recorder.handle(.interruptionBegan)
        XCTAssertTrue(h.notices.posted.isEmpty)
        leaveTheScreen(h)
        XCTAssertEqual(h.notices.delivered, PauseNotice(.interrupted))
    }

    func testLeavingTheScreenWhileRecordingPostsNothing() async throws {
        let h = try await recordingInTheBackground()
        XCTAssertTrue(h.recorder.state.isRecording)
        XCTAssertTrue(h.notices.posted.isEmpty)
    }

    func testDisconnectedMicrophoneInTheBackgroundIsNoticed() async throws {
        let h = try await recordingInTheBackground()
        h.session.isInputAvailable = false
        h.recorder.handle(.routeChanged(.inputDeviceLost, inputAvailable: false))
        XCTAssertEqual(h.recorder.state, .interrupted)
        XCTAssertEqual(h.notices.delivered, PauseNotice(.inputLost))
        XCTAssertTrue(h.notices.delivered?.body.hasPrefix("Se desconectó el micrófono.") ?? false)
    }

    func testMediaResetThatCannotRestartInTheBackgroundIsNoticed() async throws {
        let h = try await recordingInTheBackground()
        h.session.activationError = FakeRecordingSession.Failure()
        h.recorder.handle(.mediaServicesReset)
        XCTAssertEqual(h.recorder.state, .failed(message: RecorderMessages.restartFailed))
        XCTAssertEqual(h.notices.delivered, PauseNotice(.microphoneLost))
        XCTAssertEqual(h.notices.delivered?.title, "Captura dejó de grabar")
    }

    func testWriteFailureInTheBackgroundIsNoticed() async throws {
        let h = try await recordingInTheBackground()
        h.files.behavior.failWrites = true
        h.engine?.emit(seconds: 0.1)
        await h.recorder.drainPendingWrites()
        XCTAssertEqual(h.recorder.state, .failed(message: RecorderMessages.writeFailed))
        XCTAssertEqual(h.notices.delivered, PauseNotice(.writeFailed))
    }

    // MARK: - When it goes away

    func testStoppingRemovesTheNotice() async throws {
        let h = try await recordingInTheBackground()
        h.recorder.handle(.interruptionBegan)
        XCTAssertNotNil(h.notices.delivered)
        // "Detener Captura" works without opening the app.
        await h.model.stopRecording()
        XCTAssertNil(h.notices.delivered)
    }

    func testOpeningTheAppRemovesTheNoticeButStartsNothing() async throws {
        let h = try await recordingInTheBackground()
        h.recorder.handle(.interruptionBegan)
        h.appState.isForeground = true
        h.recorder.handle(.becameActive)
        await h.model.sceneBecameActive()
        XCTAssertNil(h.notices.delivered)
        XCTAssertEqual(h.recorder.state, .interrupted, "the person decides whether to continue")
    }

    func testRecordingAgainRemovesTheNotice() async throws {
        let h = try await recordingInTheBackground()
        h.recorder.handle(.interruptionBegan)
        h.appState.isForeground = true
        await startRecording(h)
        XCTAssertNil(h.notices.delivered)
    }

    // MARK: - System adapter

    /// The app has no entitlements file and no push capability: local notifications need
    /// neither. Reading the choice never shows the prompt, and withdrawing with nothing
    /// delivered is harmless. Nothing is posted here, so no notice can appear.
    func testSystemNotifierReadsTheChoiceWithoutAskingOrAnyEntitlement() async {
        let notifier = SystemPauseNotifier()
        let permission = await notifier.permission()
        XCTAssertTrue([.undetermined, .allowed, .denied].contains(permission))
        notifier.withdraw()
    }

    // MARK: - Texts

    func testNoticesAreSpanishAndAlwaysSayHowToContinue() {
        let reasons: [RecorderPauseReason] = [.interrupted, .waitingForTheApp, .inputLost, .microphoneLost, .lowStorage, .writeFailed]
        for reason in reasons {
            let notice = PauseNotice(reason)
            XCTAssertTrue([PauseNotice.pausedTitle, PauseNotice.stoppedTitle].contains(notice.title), "\(reason)")
            XCTAssertTrue(notice.body.localizedCaseInsensitiveContains("abrí la app para seguir grabando"), "\(reason)")
            XCTAssertFalse(notice.body.contains(".m4a"), "\(reason)")
        }
        XCTAssertTrue(PauseNotice(.lowStorage).body.contains("poco espacio"))
        XCTAssertTrue(PauseNotice(.writeFailed).body.contains("No se pudo guardar"))
    }
}
