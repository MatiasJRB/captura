import AVFoundation

/// One chunk being encoded. Implementations are used from a single serial queue.
protocol AudioChunkFile: AnyObject {
    func write(_ buffer: AVAudioPCMBuffer) throws
    /// Finalizes the container. Throws when the result is not a readable, non-empty
    /// audio file: such a chunk must be quarantined and never reported as closed.
    func close() throws
}

protocol AudioChunkFileFactory: Sendable {
    func makeFile(at url: URL, format: RecordingFormat) throws -> AudioChunkFile
}

enum AudioChunkFileError: Error, Equatable {
    case alreadyClosed
    case formatMismatch
    case unreadableAfterClose(String)
    case notAAC
    case empty
}

/// AAC/M4A chunk written with `AVAudioFile`.
final class AACChunkFile: AudioChunkFile {
    private var file: AVAudioFile?
    private let url: URL
    private let processingFormat: AVAudioFormat

    init(url: URL, format: RecordingFormat) throws {
        self.url = url
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.file = file
        self.processingFormat = file.processingFormat
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw AudioChunkFileError.alreadyClosed }
        guard buffer.format.sampleRate == processingFormat.sampleRate,
              buffer.format.channelCount == processingFormat.channelCount,
              buffer.format.commonFormat == processingFormat.commonFormat else {
            throw AudioChunkFileError.formatMismatch
        }
        try file.write(from: buffer)
    }

    func close() throws {
        guard let file else { throw AudioChunkFileError.alreadyClosed }
        self.file = nil
        // iOS 18+: writes the MPEG-4 header (moov) and closes the descriptor now,
        // instead of whenever the object happens to be released.
        file.close()
        try AACChunkFile.verify(url)
    }

    /// Re-opens the closed file and checks it is a non-empty AAC stream.
    static func verify(_ url: URL) throws {
        let reader: AVAudioFile
        do {
            reader = try AVAudioFile(forReading: url)
        } catch {
            throw AudioChunkFileError.unreadableAfterClose((error as NSError).localizedDescription)
        }
        guard reader.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC else {
            throw AudioChunkFileError.notAAC
        }
        guard reader.length > 0 else { throw AudioChunkFileError.empty }
    }
}

struct AACChunkFileFactory: AudioChunkFileFactory {
    func makeFile(at url: URL, format: RecordingFormat) throws -> AudioChunkFile {
        try AACChunkFile(url: url, format: format)
    }
}
