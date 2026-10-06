import AVFoundation

/// Encoding used for every chunk: AAC-LC, mono, in an MPEG-4 audio (.m4a) container,
/// which the macOS worker accepts as `audio/mp4` and decodes with ffmpeg.
///
/// 44.1 kHz / 64 kbps keeps speech intelligible for whisper.cpp at ~7.2 MB per
/// 15-minute chunk, far below the worker's 64 MiB limit. The hardware input rate
/// (usually 48 kHz) is converted before writing so every chunk has the same format.
struct RecordingFormat: Equatable, Sendable {
    var sampleRate: Double
    var bitRate: Int

    static let standard = RecordingFormat(sampleRate: 44_100, bitRate: 64_000)

    /// The PCM format buffers must have when they reach the file writer
    /// (deinterleaved Float32 mono, the processing format of `AVAudioFile`).
    var processingFormat: AVAudioFormat {
        // Standard formats are always valid for a positive rate and one channel.
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    /// Settings for `AVAudioFile(forWriting:settings:...)`. The file type is explicit
    /// because chunks are written under a ".partial" name, so the extension cannot be
    /// used to infer the container.
    var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
            AVAudioFileTypeKey: kAudioFileM4AType,
        ]
    }
}
