import AVFoundation
import XCTest
@testable import Captura

/// End-to-end with the real audio session, `AVAudioEngine` and AAC encoder.
/// On the simulator the microphone may deliver silence; these tests check what
/// the worker depends on: a closed, readable mono AAC .m4a of the right length.
///
/// Microphone tests are opt-in. On a simulator, macOS must also allow the
/// Simulator to use the Mac's microphone (System Settings > Privacy & Security >
/// Microphone); while that macOS prompt is unanswered Core Audio aborts the whole
/// test process. To run them:
///   xcrun simctl boot "iPhone Air"
///   xcrun simctl privacy "iPhone Air" grant microphone org.example.captura
///   TEST_RUNNER_CAPTURA_REAL_AUDIO_TESTS=1 xcodebuild test ... -only-testing:CapturaAppTests/RealRecordingTests
///
/// Each produced chunk is copied to an evidence folder for an external `ffprobe`
/// check: `$CAPTURA_RECORDER_EVIDENCE_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_CAPTURA_RECORDER_EVIDENCE_DIR`), else the app's Caches/RecorderEvidence.
@MainActor
final class RealRecordingTests: XCTestCase {
    private var directory: URL!
    private var controller: RecorderController?

    override func setUp() async throws {
        directory = try RecorderFixtures.temporaryDirectory().appendingPathComponent("Recordings", isDirectory: true)
    }

    override func tearDown() async throws {
        if let controller {
            await controller.stop()
        }
        controller = nil
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func requireMicrophonePermission() throws {
        guard ProcessInfo.processInfo.environment["CAPTURA_REAL_AUDIO_TESTS"] == "1" else {
            throw XCTSkip("Opt-in: set TEST_RUNNER_CAPTURA_REAL_AUDIO_TESTS=1 after allowing the microphone (see file header)")
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Microphone not granted. Run: xcrun simctl privacy <device> grant microphone org.example.captura")
        }
    }

    private func makeRecorder(chunkDuration: TimeInterval) -> (RecorderController, ChunkLog) {
        let controller = RecorderController(directory: directory, chunkDuration: chunkDuration)
        let log = ChunkLog()
        controller.onChunkClosed = { [weak controller] url in
            if let chunk = controller?.lastClosedChunk, chunk.url == url { log.chunks.append(chunk) }
        }
        self.controller = controller
        return (controller, log)
    }

    private func record(_ controller: RecorderController, seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        XCTAssertTrue(controller.state.isRecording, "state: \(controller.state)")
    }

    private func keepEvidence(_ urls: [URL], test: String = #function) throws {
        try RecorderEvidence.keep(urls, test: "Real" + test)
    }

    private func assertValidChunk(_ url: URL, expectedDuration: Double?, file: StaticString = #filePath, line: UInt = #line) throws {
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(size, 1024, "worker rejects audio of 1024 bytes or less", file: file, line: line)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".m4a"), file: file, line: line)
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC, file: file, line: line)
        XCTAssertEqual(audio.fileFormat.channelCount, 1, file: file, line: line)
        XCTAssertEqual(audio.fileFormat.sampleRate, 44_100, file: file, line: line)
        if let expectedDuration {
            XCTAssertEqual(Double(audio.length) / audio.fileFormat.sampleRate, expectedDuration, accuracy: 0.05, file: file, line: line)
        }
    }

    func testRecordsAClosedM4AChunk() async throws {
        try requireMicrophonePermission()
        let (controller, log) = makeRecorder(chunkDuration: 60)
        try await controller.start()
        try await record(controller, seconds: 2.5)
        let urlResult = await controller.stop()
        let url = try XCTUnwrap(urlResult)
        await controller.drainPendingWrites()

        XCTAssertEqual(controller.closedChunks(), [url])
        XCTAssertTrue(controller.quarantinedFiles().isEmpty)
        let chunk = try XCTUnwrap(log.chunks.first)
        XCTAssertGreaterThan(chunk.duration, 1.5)
        XCTAssertLessThan(chunk.duration, 3.5)
        try assertValidChunk(url, expectedDuration: chunk.duration)
        try keepEvidence([url])
    }

    func testRotationProducesContiguousChunks() async throws {
        try requireMicrophonePermission()
        let (controller, log) = makeRecorder(chunkDuration: 1.5)
        try await controller.start()
        try await record(controller, seconds: 4.0)
        await controller.stop()
        await controller.drainPendingWrites()

        let chunks = log.chunks
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertEqual(Set(controller.closedChunks()), Set(chunks.map(\.url)))
        for chunk in chunks.dropLast() {
            XCTAssertLessThanOrEqual(chunk.duration, 1.5 + 0.000_1)
            XCTAssertGreaterThan(chunk.duration, 1.2, "rotation must happen within one buffer of the limit")
        }
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(next.startedAt.timeIntervalSince(previous.startedAt), previous.duration, accuracy: 0.001)
        }
        for chunk in chunks {
            try assertValidChunk(chunk.url, expectedDuration: chunk.duration)
        }
        try keepEvidence(chunks.map(\.url))
    }

    func testCutChunkClosesAndKeepsRecording() async throws {
        try requireMicrophonePermission()
        let (controller, log) = makeRecorder(chunkDuration: 60)
        try await controller.start()
        try await record(controller, seconds: 1.5)
        let firstResult = await controller.cutChunk()
        let first = try XCTUnwrap(firstResult)
        try assertValidChunk(first, expectedDuration: nil)
        try await record(controller, seconds: 1.5)
        let secondResult = await controller.stop()
        let second = try XCTUnwrap(secondResult)
        await controller.drainPendingWrites()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(log.chunks.map(\.url), [first, second])
        try assertValidChunk(second, expectedDuration: log.chunks.last?.duration)
        try keepEvidence([first, second])
    }

    func testLaunchQuarantinesPlantedPartialFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "personal-capture-20261006-010203-0a0b0c0d-0000-4000-8000-000000000001.m4a.partial"
        let planted = directory.appendingPathComponent(name)
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: planted)

        let (controller, _) = makeRecorder(chunkDuration: 60)

        XCTAssertEqual(controller.recoveredOnLaunch.map(\.lastPathComponent), [name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: planted.path))
        XCTAssertTrue(controller.closedChunks().isEmpty, "a partial must never become uploadable")
        let quarantined = try XCTUnwrap(controller.quarantinedFiles().first)
        XCTAssertEqual(try Data(contentsOf: quarantined), bytes, "the original bytes are preserved")
        XCTAssertEqual(controller.state, .idle)
    }
}

@MainActor
private final class ChunkLog {
    var chunks: [ClosedChunk] = []
}
