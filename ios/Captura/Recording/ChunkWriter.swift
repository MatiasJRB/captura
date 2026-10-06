import AVFoundation
import CapturaCore
import os

struct ClosedChunk: Equatable, Sendable {
    let url: URL
    let startedAt: Date
    let frames: Int64
    let duration: TimeInterval
}

enum ChunkOutcome: Equatable, Sendable {
    case closed(ClosedChunk)
    /// The chunk received no audio; its empty file was removed (like Android deleting
    /// an empty pending row). Nothing was recorded, so no original is lost.
    case discardedEmpty
    case quarantined(URL)

    var closedURL: URL? {
        if case .closed(let chunk) = self { return chunk.url }
        return nil
    }
}

enum ChunkWriterEvent: Equatable, Sendable {
    case opened(partial: URL, startedAt: Date)
    case closed(ClosedChunk)
    case quarantined(URL, reason: String)
    /// Writing stopped for capture `generation`; the open chunk was already closed
    /// or quarantined.
    case failed(String, generation: UInt64)
}

/// Writes converted PCM buffers into rotating `.partial` chunks.
///
/// Every operation runs on one serial queue, so buffers, rotations, manual cuts and
/// stops are strictly ordered: a buffer is written either to the chunk being closed
/// or to the next one, never dropped in between. Buffers carry the capture
/// `generation` they came from; after `finish()` buffers from that capture are
/// ignored, so a late buffer can never create a chunk after the user stopped.
final class ChunkWriter: @unchecked Sendable {
    /// Moves a buffer to the writer queue. The converter allocates a new buffer for
    /// every delivery and never touches it again, so the queue owns it exclusively.
    private struct BufferHandoff: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private struct OpenChunk {
        let file: AudioChunkFile
        let partialURL: URL
        let startedAt: Date
        var frames: Int64
    }

    private let store: RecordingStore
    private let format: RecordingFormat
    private let fileFactory: AudioChunkFileFactory
    private let now: @Sendable () -> Date
    private let events: @Sendable (ChunkWriterEvent) -> Void
    private let queue = DispatchQueue(label: "org.example.captura.recorder.writer", qos: .userInitiated)
    private let log = Logger(subsystem: "org.example.captura", category: "recorder")

    // Confined to `queue`.
    private var rotation: ChunkRotation
    private var current: OpenChunk?
    private var acceptedGeneration: UInt64?
    private var nextChunkStart: Date?

    init(
        store: RecordingStore,
        format: RecordingFormat,
        chunkDuration: TimeInterval,
        fileFactory: AudioChunkFileFactory,
        now: @escaping @Sendable () -> Date,
        events: @escaping @Sendable (ChunkWriterEvent) -> Void
    ) {
        self.store = store
        self.format = format
        self.fileFactory = fileFactory
        self.now = now
        self.events = events
        self.rotation = ChunkRotation(chunkDuration: chunkDuration, sampleRate: format.sampleRate)
    }

    /// Accepts buffers tagged with `generation` from now on.
    func begin(generation: UInt64) {
        queue.async {
            self.acceptedGeneration = generation
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        let handoff = BufferHandoff(buffer: buffer)
        queue.async {
            self.write(handoff.buffer, generation: generation)
        }
    }

    /// Closes the current chunk and keeps accepting buffers, which open a new chunk.
    func cut(completion: @escaping @Sendable (ChunkOutcome?) -> Void) {
        queue.async {
            let outcome = self.closeCurrent()
            self.rotation.reset()
            completion(outcome)
        }
    }

    /// Closes the current chunk and stops accepting buffers until the next `begin`.
    func finish(completion: @escaping @Sendable (ChunkOutcome?) -> Void) {
        queue.async {
            self.acceptedGeneration = nil
            let outcome = self.closeCurrent()
            self.rotation.reset()
            completion(outcome)
        }
    }

    /// Like `finish`, but waits on the calling thread for every buffer queued so far and
    /// the close. For app termination, where nothing asynchronous runs any more.
    @discardableResult
    func finishNow() -> ChunkOutcome? {
        queue.sync {
            acceptedGeneration = nil
            let outcome = closeCurrent()
            rotation.reset()
            return outcome
        }
    }

    func cut() async -> ChunkOutcome? {
        await withCheckedContinuation { continuation in
            cut { continuation.resume(returning: $0) }
        }
    }

    func finish() async -> ChunkOutcome? {
        await withCheckedContinuation { continuation in
            finish { continuation.resume(returning: $0) }
        }
    }

    /// Runs `block` after every operation queued so far.
    func afterPendingWork(_ block: @escaping @Sendable () -> Void) {
        queue.async(execute: block)
    }

    // MARK: - Queue-confined

    private func write(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        guard acceptedGeneration == generation, buffer.frameLength > 0 else { return }
        let frames = Int64(buffer.frameLength)
        if rotation.admit(frames: frames), let full = current {
            // Gapless rotation: the next chunk starts exactly where this one ends.
            nextChunkStart = full.startedAt.addingTimeInterval(Double(full.frames) / format.sampleRate)
            _ = closeCurrent()
        }
        if current == nil {
            let startedAt = nextChunkStart ?? now()
            nextChunkStart = nil
            do {
                try open(startedAt: startedAt)
            } catch {
                log.error("Could not create chunk: \(LogPrivacy.publicSummary(of: error), privacy: .public) \(String(describing: error), privacy: .private)")
                stopAfterFailure(generation: generation)
                return
            }
        }
        do {
            try current?.file.write(buffer)
            current?.frames += frames
        } catch {
            log.error("Could not write chunk: \(LogPrivacy.publicSummary(of: error), privacy: .public) \(String(describing: error), privacy: .private)")
            stopAfterFailure(generation: generation)
        }
    }

    private func open(startedAt: Date) throws {
        let name = CaptureNaming.chunkName(startedAt: startedAt)
        let partial = store.partialURL(forChunkNamed: name)
        let file = try fileFactory.makeFile(at: partial, format: format)
        store.protect(partial)
        current = OpenChunk(file: file, partialURL: partial, startedAt: startedAt, frames: 0)
        events(.opened(partial: partial, startedAt: startedAt))
    }

    private func stopAfterFailure(generation: UInt64) {
        acceptedGeneration = nil
        _ = closeCurrent()
        rotation.reset()
        events(.failed(RecorderMessages.writeFailed, generation: generation))
    }

    private func closeCurrent() -> ChunkOutcome? {
        guard let chunk = current else { return nil }
        current = nil
        if chunk.frames == 0 {
            try? chunk.file.close()
            try? FileManager.default.removeItem(at: chunk.partialURL)
            return .discardedEmpty
        }
        do {
            try chunk.file.close()
            let url = try store.finalize(partial: chunk.partialURL)
            let closed = ClosedChunk(
                url: url,
                startedAt: chunk.startedAt,
                frames: chunk.frames,
                duration: Double(chunk.frames) / format.sampleRate
            )
            events(.closed(closed))
            return .closed(closed)
        } catch {
            let reason = String(describing: error)
            log.error("Chunk quarantined: \(LogPrivacy.publicSummary(of: error), privacy: .public) \(reason, privacy: .private)")
            // If even the move fails, the `.partial` stays and is quarantined at next launch.
            let quarantined = (try? store.quarantine(chunk.partialURL)) ?? chunk.partialURL
            events(.quarantined(quarantined, reason: reason))
            return .quarantined(quarantined)
        }
    }
}
