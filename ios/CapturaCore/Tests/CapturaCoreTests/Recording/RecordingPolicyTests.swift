import XCTest
@testable import CapturaCore

final class ChunkRotationTests: XCTestCase {
    func testDefaultChunkDurationMatchesAndroidFifteenMinutes() {
        let androidChunkMilliseconds = 15.0 * 60.0 * 1000.0 // CaptureService.CHUNK_MS
        XCTAssertEqual(ChunkRotation.defaultChunkDuration * 1000, androidChunkMilliseconds)
    }

    func testFramesPerChunkIsDurationTimesSampleRate() {
        let rotation = ChunkRotation(chunkDuration: 1.5, sampleRate: 44_100)
        XCTAssertEqual(rotation.framesPerChunk, 66_150)
    }

    func testDefaultChunkHoldsFifteenMinutesOfFrames() {
        let rotation = ChunkRotation(sampleRate: 44_100)
        XCTAssertEqual(rotation.framesPerChunk, 900 * 44_100)
    }

    func testFirstBufferNeverRotates() {
        var rotation = ChunkRotation(chunkDuration: 1, sampleRate: 100)
        XCTAssertFalse(rotation.admit(frames: 40))
        XCTAssertEqual(rotation.framesInChunk, 40)
    }

    func testBufferThatFillsChunkExactlyStaysInChunk() {
        var rotation = ChunkRotation(chunkDuration: 1, sampleRate: 100)
        XCTAssertFalse(rotation.admit(frames: 60))
        XCTAssertFalse(rotation.admit(frames: 40))
        XCTAssertEqual(rotation.framesInChunk, 100)
    }

    func testBufferThatWouldOverflowStartsNewChunkWithItsFrames() {
        var rotation = ChunkRotation(chunkDuration: 1, sampleRate: 100)
        XCTAssertFalse(rotation.admit(frames: 60))
        XCTAssertTrue(rotation.admit(frames: 50))
        XCTAssertEqual(rotation.framesInChunk, 50)
    }

    func testRotationConservesEveryAdmittedFrame() {
        var rotation = ChunkRotation(chunkDuration: 1, sampleRate: 100)
        var closedChunks: [Int64] = []
        var total: Int64 = 0
        for _ in 0..<37 {
            let before = rotation.framesInChunk
            if rotation.admit(frames: 9) { closedChunks.append(before) }
            total += 9
        }
        XCTAssertEqual(closedChunks.reduce(0, +) + rotation.framesInChunk, total)
        XCTAssertTrue(closedChunks.allSatisfy { $0 <= 100 && $0 > 90 })
    }

    func testOversizedSingleBufferIsAcceptedInEmptyChunk() {
        var rotation = ChunkRotation(chunkDuration: 1, sampleRate: 100)
        XCTAssertFalse(rotation.admit(frames: 250))
        XCTAssertTrue(rotation.admit(frames: 1))
    }

    func testResetStartsCountingAFreshChunk() {
        var rotation = ChunkRotation(chunkDuration: 1, sampleRate: 100)
        _ = rotation.admit(frames: 90)
        rotation.reset()
        XCTAssertEqual(rotation.framesInChunk, 0)
        XCTAssertFalse(rotation.admit(frames: 90))
    }

    func testDurationInChunkUsesSampleRate() {
        var rotation = ChunkRotation(chunkDuration: 10, sampleRate: 44_100)
        _ = rotation.admit(frames: 22_050)
        XCTAssertEqual(rotation.durationInChunk, 0.5, accuracy: 0.000_1)
    }
}

final class RecorderPolicyTests: XCTestCase {
    private func reaction(_ event: AudioSessionEvent, _ phase: RecorderPhase, resumePending: Bool = false) -> RecorderReaction {
        RecorderPolicy.reaction(to: event, phase: phase, resumePending: resumePending)
    }

    func testInterruptionWhileRecordingSuspends() {
        XCTAssertEqual(reaction(.interruptionBegan, .recording), .suspend)
    }

    func testInterruptionWhileIdleIsIgnored() {
        XCTAssertEqual(reaction(.interruptionBegan, .idle), .ignore)
    }

    func testInterruptionEndWithShouldResumeResumesInNewChunk() {
        XCTAssertEqual(reaction(.interruptionEnded(shouldResume: true), .interrupted), .resumeInNewChunk)
    }

    func testInterruptionEndWithoutShouldResumeWaitsForTheUser() {
        XCTAssertEqual(reaction(.interruptionEnded(shouldResume: false), .interrupted), .ignore)
    }

    func testInterruptionEndAfterUserStoppedDoesNotRestartMicrophone() {
        XCTAssertEqual(reaction(.interruptionEnded(shouldResume: true), .idle), .ignore)
    }

    func testLostInputWithAnotherInputAvailableRestartsInNewChunk() {
        XCTAssertEqual(reaction(.routeChanged(.inputDeviceLost, inputAvailable: true), .recording), .restartInNewChunk)
    }

    func testLostInputWithoutAnyInputSuspends() {
        XCTAssertEqual(reaction(.routeChanged(.inputDeviceLost, inputAvailable: false), .recording), .suspend)
    }

    func testNoSuitableRouteWithoutInputSuspends() {
        XCTAssertEqual(reaction(.routeChanged(.noSuitableRoute, inputAvailable: false), .recording), .suspend)
    }

    func testBenignRouteChangeIsIgnored() {
        XCTAssertEqual(reaction(.routeChanged(.other, inputAvailable: true), .recording), .ignore)
    }

    func testMediaServicesResetWhileRecordingRestartsInNewChunk() {
        XCTAssertEqual(reaction(.mediaServicesReset, .recording), .restartInNewChunk)
    }

    func testMediaServicesResetWhileIdleNeverStartsMicrophone() {
        XCTAssertEqual(reaction(.mediaServicesReset, .idle), .ignore)
    }

    func testEngineConfigurationChangeWhileRecordingRestartsInNewChunk() {
        XCTAssertEqual(reaction(.engineConfigurationChanged, .recording), .restartInNewChunk)
    }

    func testForegroundResumesOnlyWhenAResumeIsPending() {
        XCTAssertEqual(reaction(.becameActive, .interrupted, resumePending: true), .resumeInNewChunk)
        XCTAssertEqual(reaction(.becameActive, .interrupted, resumePending: false), .ignore)
    }

    func testForegroundNeverStartsMicrophoneFromIdle() {
        XCTAssertEqual(reaction(.becameActive, .idle, resumePending: true), .ignore)
    }

    func testFailedRecorderIgnoresEverySessionEvent() {
        let events: [AudioSessionEvent] = [
            .interruptionBegan, .interruptionEnded(shouldResume: true),
            .routeChanged(.inputDeviceLost, inputAvailable: true), .mediaServicesReset,
            .engineConfigurationChanged, .becameActive,
        ]
        for event in events {
            XCTAssertEqual(reaction(event, .failed, resumePending: true), .ignore, "\(event)")
        }
    }
}

final class RecordingFilesTests: XCTestCase {
    private let chunk = "personal-capture-20261006-152000-6f9619ff-8b86-d011-b42d-00c04fc964ff.m4a"

    func testPartialNameAppendsPartialSuffix() {
        XCTAssertEqual(RecordingFiles.partialName(forChunkNamed: chunk), chunk + ".partial")
    }

    func testFinalNameStripsPartialSuffix() {
        XCTAssertEqual(RecordingFiles.finalName(forPartialNamed: chunk + ".partial"), chunk)
    }

    func testFinalNameRejectsForeignPartial() {
        XCTAssertNil(RecordingFiles.finalName(forPartialNamed: "notes.txt.partial"))
    }

    func testFinalNameRejectsFileWithoutPartialSuffix() {
        XCTAssertNil(RecordingFiles.finalName(forPartialNamed: chunk))
    }

    func testClosedChunkRole() {
        XCTAssertEqual(RecordingFiles.role(ofFileNamed: chunk), .closedChunk)
    }

    func testPartialRole() {
        XCTAssertEqual(RecordingFiles.role(ofFileNamed: chunk + ".partial"), .partial)
        XCTAssertEqual(RecordingFiles.role(ofFileNamed: "anything.partial"), .partial)
    }

    func testForeignFilesAreOther() {
        for name in ["Quarantine", ".DS_Store", "personal-capture-note.m4a", "audio.m4a"] {
            XCTAssertEqual(RecordingFiles.role(ofFileNamed: name), .other, name)
        }
    }
}
