import AVFoundation
import XCTest
@testable import Captura

/// The real `AVAudioCaptureEngine` (input tap + converter) feeding the real
/// controller, writer and AAC encoder, driven by an `AVAudioEngine` in offline
/// manual-rendering mode. Runs anywhere: no microphone, no host permission.
@MainActor
final class OfflineEngineRecordingTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = try RecorderFixtures.temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Provides a continuous synthetic signal as the "hardware" input: a tone, or
    /// white noise (the hardest case for the encoder, so the largest files).
    private final class ToneSource {
        let buffer: AVAudioPCMBuffer
        private let noise: Bool
        private var phase = 0
        private var generator = SystemRandomNumberGenerator()

        init(format: AVAudioFormat, noise: Bool = false) {
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
            self.noise = noise
        }

        func next(_ frames: AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? {
            let count = min(frames, buffer.frameCapacity)
            buffer.frameLength = count
            let rate = Float(buffer.format.sampleRate)
            for channel in 0..<Int(buffer.format.channelCount) {
                for index in 0..<Int(count) {
                    buffer.floatChannelData![channel][index] = noise
                        ? Float.random(in: -0.3...0.3, using: &generator)
                        : 0.3 * sin(2 * .pi * 330 * Float(phase + index) / rate)
                }
            }
            phase += Int(count)
            return UnsafePointer(buffer.audioBufferList)
        }
    }

    private func makeOfflineEngine(hardware: AVAudioFormat, source: ToneSource) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: hardware, maximumFrameCount: 4096)
        let accepted = engine.inputNode.setManualRenderingInputPCMFormat(hardware) { frames in source.next(frames) }
        XCTAssertTrue(accepted)
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: hardware)
        return engine
    }

    private func render(_ engine: AVAudioEngine, seconds: Double) throws {
        let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var remaining = AVAudioFrameCount(seconds * engine.manualRenderingFormat.sampleRate)
        while remaining > 0 {
            let frames = min(4096, remaining)
            let status = try engine.renderOffline(frames, to: output)
            XCTAssertEqual(status, .success)
            remaining -= frames
        }
    }

    private func recordOffline(hardware: AVAudioFormat, seconds: Double, chunkDuration: TimeInterval, noise: Bool = false) async throws -> (RecorderController, [ClosedChunk]) {
        let source = ToneSource(format: hardware, noise: noise)
        let engine = try makeOfflineEngine(hardware: hardware, source: source)
        let capture = AVAudioCaptureEngine(engine: engine)
        let controller = RecorderController(
            directory: root.appendingPathComponent("Recordings", isDirectory: true),
            chunkDuration: chunkDuration,
            session: FakeRecordingSession(),
            makeEngine: { capture },
            notificationCenter: NotificationCenter(),
            isAppInForeground: { true }
        )
        var chunks: [ClosedChunk] = []
        controller.onChunkClosed = { [weak controller] url in
            if let chunk = controller?.lastClosedChunk, chunk.url == url { chunks.append(chunk) }
        }
        try await controller.start()
        try render(engine, seconds: seconds)
        // Offline taps may be delivered asynchronously; let them reach the writer.
        try await Task.sleep(nanoseconds: 300_000_000)
        await controller.stop()
        await controller.drainPendingWrites()
        return (controller, chunks)
    }

    func testHardwareRateAudioBecomesContiguousAACChunks() async throws {
        let hardware = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let (controller, chunks) = try await recordOffline(hardware: hardware, seconds: 3.2, chunkDuration: 1.0)

        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        XCTAssertEqual(Set(controller.closedChunks()), Set(chunks.map(\.url)))
        XCTAssertTrue(controller.quarantinedFiles().isEmpty)
        var decoded = 0.0
        for chunk in chunks {
            let file = try AVAudioFile(forReading: chunk.url)
            XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
            decoded += Double(file.length) / file.fileFormat.sampleRate
        }
        XCTAssertEqual(decoded, 3.2, accuracy: 0.1, "rotation must not drop or duplicate audio")
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(next.startedAt.timeIntervalSince(previous.startedAt), previous.duration, accuracy: 0.001)
        }
        try RecorderEvidence.keep(chunks.map(\.url), test: "Offline" + #function)
    }

    func testStereoHardwareInputIsRecordedAsMono() async throws {
        let hardware = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let (_, chunks) = try await recordOffline(hardware: hardware, seconds: 1.0, chunkDuration: 60)
        let chunk = try XCTUnwrap(chunks.first)
        let file = try AVAudioFile(forReading: chunk.url)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 1.0, accuracy: 0.05)
        try RecorderEvidence.keep([chunk.url], test: "Offline" + #function)
    }

    /// A full default chunk (15 minutes of worst-case noise) must stay far below the
    /// worker's 64 MiB limit and decode to the full duration. Renders offline in seconds.
    func testDefaultFifteenMinuteChunkFitsWorkerLimits() async throws {
        let hardware = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let (_, chunks) = try await recordOffline(
            hardware: hardware,
            seconds: ChunkRotationDefaults.seconds + 2,
            chunkDuration: ChunkRotationDefaults.seconds,
            noise: true
        )
        XCTAssertEqual(chunks.count, 2)
        let full = try XCTUnwrap(chunks.first)
        XCTAssertEqual(full.duration, 900, accuracy: 0.2)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: full.url.path)[.size] as? NSNumber).intValue
        XCTAssertLessThan(size, 10 * 1024 * 1024, "64 kbps for 15 minutes is about 7.2 MB")
        XCTAssertLessThan(size, 64 * 1024 * 1024, "worker MAX_AUDIO")
        let file = try AVAudioFile(forReading: full.url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 900, accuracy: 0.2)
        try RecorderEvidence.keep([full.url], test: "Offline" + #function)
    }
}

private enum ChunkRotationDefaults {
    /// Android `CaptureService.CHUNK_MS`, the recorder's default chunk length.
    static let seconds: TimeInterval = 15 * 60
}
