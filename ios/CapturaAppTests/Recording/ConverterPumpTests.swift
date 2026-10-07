import AVFoundation
import XCTest
@testable import Captura

/// The converter between the hardware input and the recording format, without a microphone.
final class ConverterPumpTests: XCTestCase {
    private let target = RecordingFormat.standard.processingFormat

    private func pump(from input: AVAudioFormat) throws -> ConverterPump {
        let converter = try XCTUnwrap(AVAudioConverter(from: input, to: target))
        converter.downmix = true
        return ConverterPump(converter: converter)
    }

    private func tone(frames: AVAudioFrameCount, sampleRate: Double, channels: AVAudioChannelCount, gains: [Float]? = nil, phase: Int = 0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let gain = gains?[channel] ?? 0.4
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = gain * sin(2 * .pi * 220 * Float(phase + index) / Float(sampleRate))
            }
        }
        return buffer
    }

    /// Feeds `count` buffers and returns the frames produced after each call.
    private func run(sampleRate: Double, channels: AVAudioChannelCount, bufferFrames: AVAudioFrameCount, count: Int) throws -> [Int] {
        let pump = try pump(from: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!)
        var produced: [Int] = []
        for call in 0..<count {
            let input = tone(frames: bufferFrames, sampleRate: sampleRate, channels: channels, phase: call * Int(bufferFrames))
            produced.append(pump.convert(input).reduce(0) { $0 + Int($1.frameLength) })
        }
        return produced
    }

    private func assertNoBacklog(sampleRate: Double, channels: AVAudioChannelCount, bufferFrames: AVAudioFrameCount, file: StaticString = #filePath, line: UInt = #line) throws {
        let calls = 40
        let produced = try run(sampleRate: sampleRate, channels: channels, bufferFrames: bufferFrames, count: calls)
        let expected = Double(calls) * Double(bufferFrames) * 44_100 / sampleRate
        let total = Double(produced.reduce(0, +))
        // The converter holds back a few milliseconds of filter latency, never more.
        XCTAssertEqual(total, expected, accuracy: 0.010 * 44_100, file: file, line: line)
        let perCall = Double(bufferFrames) * 44_100 / sampleRate
        XCTAssertEqual(Double(produced.last ?? 0), perCall, accuracy: 64, "backlog must not grow", file: file, line: line)
    }

    func testOutputIsMonoFloatAtRecordingRate() throws {
        let pump = try pump(from: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        let output = try XCTUnwrap(pump.convert(tone(frames: 4800, sampleRate: 48_000, channels: 2)).first)
        XCTAssertEqual(output.format.sampleRate, 44_100)
        XCTAssertEqual(output.format.channelCount, 1)
        XCTAssertEqual(output.format.commonFormat, .pcmFormatFloat32)
    }

    func testMatchingFormatHoldsBackLessThanTenMilliseconds() throws {
        let pump = try pump(from: target)
        let produced = pump.convert(RecorderFixtures.tone(frames: 4410)).reduce(0) { $0 + Int($1.frameLength) }
        XCTAssertGreaterThan(produced, 4410 - 441)
        XCTAssertLessThanOrEqual(produced, 4410)
    }

    func testNoBacklogAt44100HzMonoWith100MillisecondBuffers() throws {
        try assertNoBacklog(sampleRate: 44_100, channels: 1, bufferFrames: 4410)
    }

    func testNoBacklogAt44100HzStereoWith100MillisecondBuffers() throws {
        try assertNoBacklog(sampleRate: 44_100, channels: 2, bufferFrames: 4410)
    }

    func testNoBacklogAt48kHzMonoWith100MillisecondBuffers() throws {
        try assertNoBacklog(sampleRate: 48_000, channels: 1, bufferFrames: 4800)
    }

    func testNoBacklogAt48kHzWithLargeBuffers() throws {
        try assertNoBacklog(sampleRate: 48_000, channels: 1, bufferFrames: 19_200)
    }

    func testNoBacklogWhenUpsamplingFrom16kHz() throws {
        try assertNoBacklog(sampleRate: 16_000, channels: 1, bufferFrames: 4096)
    }

    func testStereoIsDownmixedNotTruncatedToTheLeftChannel() throws {
        let pump = try pump(from: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        let outputs = pump.convert(tone(frames: 4410, sampleRate: 44_100, channels: 2, gains: [0, 0.8]))
        let peak = outputs.flatMap { buffer in
            UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)).map(abs)
        }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "right-only audio must survive the mono conversion")
    }

    func testEmptyInputProducesNoBuffer() throws {
        let pump = try pump(from: target)
        let empty = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16)!
        XCTAssertTrue(pump.convert(empty).isEmpty)
    }
}
