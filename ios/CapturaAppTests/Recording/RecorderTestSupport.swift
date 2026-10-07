import AVFoundation
import XCTest
@testable import Captura

/// Fictional audio only: synthetic tones, temporary directories, no microphone.
enum RecorderFixtures {
    static func temporaryDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captura-recorder-tests", isDirectory: true)
            .appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 440 Hz tone in the recorder's processing format.
    static func tone(frames: AVAudioFrameCount, format: RecordingFormat = .standard, phase: Int = 0) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            samples[index] = 0.2 * sin(2 * .pi * 440 * Float(phase + index) / Float(format.sampleRate))
        }
        return buffer
    }

    static func frames(seconds: Double, format: RecordingFormat = .standard) -> AVAudioFrameCount {
        AVAudioFrameCount((seconds * format.sampleRate).rounded())
    }

    static let fixedDate = Date(timeIntervalSince1970: 1_791_300_000)
}

/// Copies produced chunks where an external `ffprobe` can inspect them:
/// `$CAPTURA_RECORDER_EVIDENCE_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_CAPTURA_RECORDER_EVIDENCE_DIR`), else the app's Caches/RecorderEvidence.
enum RecorderEvidence {
    static func keep(_ urls: [URL], test: String) throws {
        let base: URL
        if let path = ProcessInfo.processInfo.environment["CAPTURA_RECORDER_EVIDENCE_DIR"], !path.isEmpty {
            base = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            base = URL.cachesDirectory.appendingPathComponent("RecorderEvidence", isDirectory: true)
        }
        let folder = base.appendingPathComponent(test.filter { $0.isLetter || $0.isNumber }, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls {
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
        print("RECORDER_EVIDENCE \(folder.path)")
    }
}

/// Thread-safe, controllable clock.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = RecorderFixtures.fixedDate) {
        current = start
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

final class FakeAudioCaptureEngine: AudioCaptureEngine {
    struct Failure: Error {}

    var onConfigurationChange: (() -> Void)?
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false
    private(set) var format: AVAudioFormat?
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Sink of a previous start, kept to simulate late buffers from a stopped tap.
    private(set) var previousSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var emittedFrames = 0

    func start(delivering format: AVAudioFormat, to sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        startCount += 1
        if let startError { throw startError }
        self.format = format
        previousSink = self.sink
        self.sink = sink
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    /// Emits a synthetic buffer as if it came from the microphone.
    func emit(frames: AVAudioFrameCount) {
        XCTAssertTrue(isRunning, "emitting while the fake engine is stopped")
        let buffer = RecorderFixtures.tone(frames: frames, phase: emittedFrames)
        emittedFrames += Int(frames)
        sink?(buffer)
    }

    func emit(seconds: Double, bufferSeconds: Double = 0.1) {
        let total = Int(RecorderFixtures.frames(seconds: seconds))
        let step = Int(RecorderFixtures.frames(seconds: bufferSeconds))
        var sent = 0
        while sent < total {
            let count = min(step, total - sent)
            emit(frames: AVAudioFrameCount(count))
            sent += count
        }
    }

    /// Delivers a buffer through the sink of the capture before the last restart.
    func emitLateBufferFromPreviousCapture(frames: AVAudioFrameCount) {
        previousSink?(RecorderFixtures.tone(frames: frames))
    }
}

final class FakeRecordingSession: RecordingAudioSession {
    struct Failure: Error {}

    var permission: MicrophonePermission = .granted
    var permissionAfterRequest: MicrophonePermission = .granted
    var isInputAvailable = true
    var activationError: Error?
    private(set) var requestCount = 0
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    /// Ordered log shared with the fake engine to check call order.
    var log: [String] = []

    func requestPermission() async -> MicrophonePermission {
        requestCount += 1
        permission = permissionAfterRequest
        return permission
    }

    func activateForRecording() throws {
        activateCount += 1
        log.append("activate")
        if let activationError { throw activationError }
    }

    func deactivate() {
        deactivateCount += 1
        log.append("deactivate")
    }
}

/// In-memory chunk that counts frames and writes placeholder bytes to disk so the
/// store can rename or quarantine it. Fictional content only.
final class FakeChunkFile: AudioChunkFile {
    let url: URL
    private let behavior: FakeChunkFileFactory.Behavior
    private(set) var frames: Int64 = 0
    private(set) var closed = false

    init(url: URL, behavior: FakeChunkFileFactory.Behavior) throws {
        self.url = url
        self.behavior = behavior
        try Data("fake-chunk".utf8).write(to: url)
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        if behavior.failWrites { throw FakeChunkFileFactory.Failure.write }
        frames += Int64(buffer.frameLength)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x41, count: Int(buffer.frameLength / 64) + 1))
        try handle.close()
    }

    func close() throws {
        closed = true
        if behavior.failClose { throw FakeChunkFileFactory.Failure.close }
    }
}

final class FakeChunkFileFactory: AudioChunkFileFactory, @unchecked Sendable {
    enum Failure: Error { case open, write, close }

    struct Behavior {
        var failOpen = false
        var failWrites = false
        var failClose = false
    }

    private let lock = NSLock()
    private var _behavior = Behavior()
    private var _files: [FakeChunkFile] = []

    var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }

    var files: [FakeChunkFile] { lock.withLock { _files } }

    func makeFile(at url: URL, format: RecordingFormat) throws -> AudioChunkFile {
        let behavior = self.behavior
        if behavior.failOpen { throw Failure.open }
        let file = try FakeChunkFile(url: url, behavior: behavior)
        lock.withLock { _files.append(file) }
        return file
    }
}

/// Collects writer events from the writer queue.
final class WriterEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ChunkWriterEvent] = []

    var events: [ChunkWriterEvent] { lock.withLock { _events } }

    var closed: [ClosedChunk] {
        events.compactMap { if case .closed(let chunk) = $0 { return chunk } else { return nil } }
    }

    var quarantined: [URL] {
        events.compactMap { if case .quarantined(let url, _) = $0 { return url } else { return nil } }
    }

    var opened: [Date] {
        events.compactMap { if case .opened(_, let date) = $0 { return date } else { return nil } }
    }

    func record(_ event: ChunkWriterEvent) {
        lock.withLock { _events.append(event) }
    }
}

extension ChunkWriter {
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            afterPendingWork { continuation.resume() }
        }
    }
}
