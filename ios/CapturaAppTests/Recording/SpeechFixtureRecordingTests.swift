import AVFoundation
import CapturaCore
import XCTest
@testable import Captura

/// Opt-in end-to-end speech proof that needs no microphone at all. A speech file made on
/// the Mac (for example with `say`) is played as the "hardware" input of an
/// `AVAudioEngine` in offline manual-rendering mode, at 48 kHz like the iPhone's
/// microphone, and goes through the production path below the microphone: the input
/// tap and converter of `AVAudioCaptureEngine`, `RecorderController` (start, rotation,
/// stop), `ChunkWriter` and the AAC encoder. Rendering keeps pace with the tap, which
/// is usually far faster than real time. Only the audio session is a fake. The closed chunks are copied out so the Mac
/// worker can transcribe them.
///
///     say -v "Flo (Español (México))" -o /tmp/e2e/speech.aiff "Hola Berna, …"
///     TEST_RUNNER_CAPTURA_SPEECH_FIXTURE=/tmp/e2e/speech.aiff \
///     TEST_RUNNER_CAPTURA_SPEECH_OUT=/tmp/e2e/out \
///     TEST_RUNNER_CAPTURA_SPEECH_CHUNK_SECONDS=4 \
///         xcodebuild test ... -only-testing:CapturaAppTests/SpeechFixtureRecordingTests
///
/// `CAPTURA_SPEECH_CHUNK_SECONDS` is validated like the app's `-CapturaChunkSeconds`
/// (2–900 seconds); without it the 15-minute default applies. The chunks and a
/// `chunks.json` (name, start offset, frames, duration) land in
/// `<out>/<fixture name>-<chunk length>/`, which the test replaces on every run.
/// Use synthetic speech only, never a recording of real people.
@MainActor
final class SpeechFixtureRecordingTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = try RecorderFixtures.temporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSpeechFixtureBecomesClosedChunksThroughTheProductionCapturePath() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["CAPTURA_SPEECH_FIXTURE"], !fixturePath.isEmpty,
              let outPath = environment["CAPTURA_SPEECH_OUT"], !outPath.isEmpty else {
            throw XCTSkip("Opt-in: set TEST_RUNNER_CAPTURA_SPEECH_FIXTURE and TEST_RUNNER_CAPTURA_SPEECH_OUT (see file header)")
        }
        var chunkDuration = ChunkRotation.defaultChunkDuration
        if let value = environment["CAPTURA_SPEECH_CHUNK_SECONDS"], !value.isEmpty {
            chunkDuration = try XCTUnwrap(
                LaunchOptions.parse([LaunchOptions.chunkFlag, value]).chunkSeconds,
                "CAPTURA_SPEECH_CHUNK_SECONDS must be a number of seconds in \(LaunchOptions.chunkRange)"
            )
        }

        let hardware = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let speech = try SpeechFile.load(URL(fileURLWithPath: fixturePath), as: hardware)
        // A short silence after the last word, like a person pausing before Detener.
        let targetFrames = speech.frameLength + AVAudioFrameCount(0.3 * hardware.sampleRate)
        let targetSeconds = Double(targetFrames) / hardware.sampleRate

        let source = SpeechSource(speech)
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: hardware, maximumFrameCount: 4096)
        let accepted = engine.inputNode.setManualRenderingInputPCMFormat(hardware) { frames in source.next(frames) }
        XCTAssertTrue(accepted)
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: hardware)
        let capture = CountingCaptureEngine(AVAudioCaptureEngine(engine: engine))

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
        // Offline taps arrive asynchronously and drop audio when rendering runs far ahead
        // of them, so each render waits until the converted audio caught up to within
        // 200 ms: as fast as the tap drains (usually many times real time), never ahead.
        // The tap only hands over full buffers, so after the target more silence is
        // rendered until all of the target reached the recorder; what stays in the tap
        // at Detener is silence, as on the phone, where up to one tap buffer is not saved.
        let ratio = RecordingFormat.standard.sampleRate / hardware.sampleRate
        let targetDelivered = Int64(Double(targetFrames) * ratio) - 512
        let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var rendered: AVAudioFrameCount = 0
        while rendered < targetFrames || capture.deliveredFrames < targetDelivered {
            XCTAssertLessThan(rendered, targetFrames + 4 * 4096, "the tap stopped delivering")
            guard rendered < targetFrames + 4 * 4096 else { break }
            try await capture.waitForFrames(Int64(Double(rendered) * ratio - 0.2 * RecordingFormat.standard.sampleRate), timeout: 2)
            let status = try engine.renderOffline(4096, to: output)
            XCTAssertEqual(status, .success)
            rendered += 4096
            if rendered >= targetFrames {
                try await capture.waitForFrames(targetDelivered, timeout: 0.5)
            }
        }
        await controller.stop()
        await controller.drainPendingWrites()
        let delivered = capture.deliveredFrames

        // Chunk lengths, formats and gapless rotation.
        let minimumChunks = Int((targetSeconds / chunkDuration).rounded(.up))
        XCTAssertGreaterThanOrEqual(chunks.count, minimumChunks)
        XCTAssertLessThanOrEqual(chunks.count, minimumChunks + 1)
        XCTAssertEqual(Set(controller.closedChunks()), Set(chunks.map(\.url)))
        XCTAssertTrue(controller.quarantinedFiles().isEmpty)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.frames }, delivered, "every delivered frame is written exactly once")
        var decodedSeconds = 0.0
        for chunk in chunks {
            let file = try AVAudioFile(forReading: chunk.url)
            XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
            XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, chunk.duration, accuracy: 0.01)
            decodedSeconds += Double(file.length) / file.fileFormat.sampleRate
        }
        for chunk in chunks.dropLast() {
            XCTAssertLessThanOrEqual(chunk.duration, chunkDuration + 0.000_1)
        }
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(next.startedAt.timeIntervalSince(previous.startedAt), previous.duration, accuracy: 0.001)
        }
        XCTAssertGreaterThanOrEqual(decodedSeconds, targetSeconds - 0.02, "the speech and the pause after it are all saved")

        try export(chunks, fixture: URL(fileURLWithPath: fixturePath), chunkDuration: chunkDuration, to: URL(fileURLWithPath: outPath, isDirectory: true))
    }

    private func export(_ chunks: [ClosedChunk], fixture: URL, chunkDuration: TimeInterval, to out: URL) throws {
        let label = chunkDuration == ChunkRotation.defaultChunkDuration ? "default" : "\(Int(chunkDuration))s"
        let folder = out.appendingPathComponent("\(fixture.deletingPathExtension().lastPathComponent)-\(label)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let firstStart = chunks.first?.startedAt ?? Date()
        var manifest: [[String: Any]] = []
        for chunk in chunks {
            let copy = folder.appendingPathComponent(chunk.url.lastPathComponent)
            try FileManager.default.copyItem(at: chunk.url, to: copy)
            manifest.append([
                "name": chunk.url.lastPathComponent,
                "start_offset_s": chunk.startedAt.timeIntervalSince(firstStart),
                "frames": chunk.frames,
                "duration_s": chunk.duration,
            ])
            print("SPEECH_CHUNK \(copy.path)")
        }
        let json = try JSONSerialization.data(withJSONObject: ["chunk_seconds": chunkDuration, "chunks": manifest], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: folder.appendingPathComponent("chunks.json"))
    }
}

/// The fixture decoded and resampled to the "hardware" format.
private enum SpeechFile {
    static func load(_ url: URL, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: decoded)
        let converter = try XCTUnwrap(AVAudioConverter(from: decoded.format, to: format))
        converter.downmix = true
        let ratio = format.sampleRate / decoded.format.sampleRate
        let capacity = AVAudioFrameCount((Double(decoded.frameLength) * ratio).rounded(.up)) + 4_096
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return decoded
        }
        if status == .error { throw error ?? CocoaError(.fileReadCorruptFile) }
        XCTAssertEqual(Double(output.frameLength), Double(decoded.frameLength) * ratio, accuracy: 64)
        return output
    }
}

/// Plays the speech into the offline engine's input node, then silence.
private final class SpeechSource {
    private let speech: AVAudioPCMBuffer
    private let buffer: AVAudioPCMBuffer
    private var position = 0

    init(_ speech: AVAudioPCMBuffer) {
        self.speech = speech
        buffer = AVAudioPCMBuffer(pcmFormat: speech.format, frameCapacity: 8192)!
    }

    func next(_ frames: AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? {
        let count = Int(min(frames, buffer.frameCapacity))
        buffer.frameLength = AVAudioFrameCount(count)
        let target = buffer.floatChannelData![0]
        let available = max(0, min(count, Int(speech.frameLength) - position))
        if available > 0 {
            target.update(from: speech.floatChannelData![0].advanced(by: position), count: available)
        }
        if available < count {
            target.advanced(by: available).update(repeating: 0, count: count - available)
        }
        position += count
        return UnsafePointer(buffer.audioBufferList)
    }
}

/// The production engine, counting the converted frames it hands to the recorder.
private final class CountingCaptureEngine: AudioCaptureEngine {
    private let inner: AVAudioCaptureEngine
    private let counter = FrameCounter()

    init(_ inner: AVAudioCaptureEngine) {
        self.inner = inner
    }

    var deliveredFrames: Int64 { counter.value }

    /// Returns once at least `frames` converted frames were delivered, or after `timeout`.
    func waitForFrames(_ frames: Int64, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while counter.value < frames, Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    var onConfigurationChange: (() -> Void)? {
        get { inner.onConfigurationChange }
        set { inner.onConfigurationChange = newValue }
    }

    func start(delivering format: AVAudioFormat, to sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let counter = self.counter
        try inner.start(delivering: format) { buffer in
            counter.add(Int64(buffer.frameLength))
            sink(buffer)
        }
    }

    func stop() {
        inner.stop()
    }
}

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: Int64 = 0

    var value: Int64 { lock.withLock { frames } }

    func add(_ count: Int64) {
        lock.withLock { frames += count }
    }
}
