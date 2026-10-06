import AVFoundation

/// Delivers microphone audio already converted to the recording format.
/// Small on purpose: the controller's rotation, interruption and state logic is
/// tested with a fake engine that emits synthetic buffers.
protocol AudioCaptureEngine: AnyObject {
    /// Starts the microphone. `sink` is called on an audio thread, in order, with
    /// buffers in exactly `format`. Throws when there is no usable input.
    func start(delivering format: AVAudioFormat, to sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    /// Stops the microphone. No `sink` call starts after this returns.
    func stop()
    /// Called on the main queue when the engine stopped because its I/O
    /// configuration changed (new input route, sample rate change).
    var onConfigurationChange: (() -> Void)? { get set }
}

/// `AVAudioEngine` input tap + `AVAudioConverter` (rate conversion and downmix to mono).
/// Confined to the main thread: the controller calls it from the main actor and the
/// configuration notification is delivered on the main queue. The tap block only
/// captures the converter pump and the sink, never `self`.
final class AVAudioCaptureEngine: AudioCaptureEngine, @unchecked Sendable {
    private let engine: AVAudioEngine
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    var onConfigurationChange: (() -> Void)?

    /// - Parameter engine: injectable so tests can drive the same tap and converter
    ///   with an engine in offline manual-rendering mode (no microphone).
    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        stop()
    }

    func start(delivering format: AVAudioFormat, to sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputAvailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw RecorderError.couldNotStart("unsupported input format \(inputFormat)")
        }
        converter.downmix = true
        let pump = ConverterPump(converter: converter)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.tapBlock(pump: pump, sink: sink))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    /// Built outside any actor context: the tap runs on an audio thread.
    private nonisolated static func tapBlock(
        pump: ConverterPump,
        sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            for converted in pump.convert(buffer) {
                sink(converted)
            }
        }
    }
}

/// Feeds one input buffer at a time through a stateful converter. The converter
/// keeps its resampling history between buffers, so conversion is continuous
/// across chunk boundaries. Only ever used from the tap's serial thread.
final class ConverterPump: @unchecked Sendable {
    private let converter: AVAudioConverter

    init(converter: AVAudioConverter) {
        self.converter = converter
    }

    /// Converts `input`, draining the converter until it yields nothing more so a
    /// large tap buffer never leaves converted audio behind. The converter still
    /// holds a few milliseconds of filter latency until the next buffer arrives
    /// (measured below 10 ms; see ConverterPumpTests), so only that tail is lost
    /// when capture stops. Rotation reuses the same converter and loses nothing.
    func convert(_ input: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        guard input.frameLength > 0 else { return [] }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        let feed = SingleInput(input)
        var outputs: [AVAudioPCMBuffer] = []
        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard let buffer = feed.take() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error || output.frameLength == 0 { break }
            outputs.append(output)
        }
        return outputs
    }
}

/// Hands one buffer to the converter exactly once. The converter calls its input
/// block synchronously inside `convert(to:error:withInputFrom:)`, on this thread.
private final class SingleInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
