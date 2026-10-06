import AVFoundation
import CapturaCore
import XCTest
@testable import Captura

final class ChunkWriterTests: XCTestCase {
    private var root: URL!
    private var store: RecordingStore!
    private var factory: FakeChunkFileFactory!
    private var log: WriterEventLog!
    private var clock: TestClock!

    override func setUpWithError() throws {
        root = try RecorderFixtures.temporaryDirectory()
        store = RecordingStore(directory: root.appendingPathComponent("Recordings", isDirectory: true))
        try store.prepare()
        factory = FakeChunkFileFactory()
        log = WriterEventLog()
        clock = TestClock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeWriter(chunkDuration: TimeInterval = 1, fileFactory: AudioChunkFileFactory? = nil) -> ChunkWriter {
        let log = self.log!
        let clock = self.clock!
        return ChunkWriter(
            store: store,
            format: .standard,
            chunkDuration: chunkDuration,
            fileFactory: fileFactory ?? factory,
            now: { clock.now() },
            events: { log.record($0) }
        )
    }

    private func append(_ writer: ChunkWriter, seconds: Double, bufferSeconds: Double = 0.1, generation: UInt64 = 1) {
        let total = Int(RecorderFixtures.frames(seconds: seconds))
        let step = Int(RecorderFixtures.frames(seconds: bufferSeconds))
        var sent = 0
        while sent < total {
            let count = min(step, total - sent)
            writer.append(RecorderFixtures.tone(frames: AVAudioFrameCount(count), phase: sent), generation: generation)
            sent += count
        }
    }

    // MARK: - Naming and lifecycle

    func testOpenChunkIsWrittenUnderPartialName() async throws {
        let writer = makeWriter()
        writer.begin(generation: 1)
        append(writer, seconds: 0.2)
        await writer.drain()
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0 != "Quarantine" }
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasSuffix(".m4a.partial"), names[0])
        XCTAssertTrue(store.closedChunks().isEmpty)
    }

    func testChunkNameUsesTheTimeItsFirstBufferArrived() async throws {
        let writer = makeWriter()
        writer.begin(generation: 1)
        append(writer, seconds: 0.2)
        let outcome = await writer.finish()
        let chunk = try XCTUnwrap(log.closed.first)
        XCTAssertEqual(chunk.startedAt, RecorderFixtures.fixedDate)
        XCTAssertTrue(chunk.url.lastPathComponent.hasPrefix("personal-capture-"))
        XCTAssertEqual(outcome?.closedURL, chunk.url)
    }

    func testFinishRenamesPartialToFinalChunkName() async throws {
        let writer = makeWriter()
        writer.begin(generation: 1)
        append(writer, seconds: 0.3)
        let urlResult = await writer.finish()?.closedURL
        let url = try XCTUnwrap(urlResult)
        XCTAssertTrue(CaptureNaming.isChunkName(url.lastPathComponent))
        XCTAssertEqual(store.closedChunks(), [url])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".partial"))
    }

    func testClosedEventIsEmittedOnlyAfterRename() async throws {
        let writer = makeWriter()
        writer.begin(generation: 1)
        append(writer, seconds: 0.3)
        _ = await writer.finish()
        let chunk = try XCTUnwrap(log.closed.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.url.path))
        XCTAssertFalse(chunk.url.lastPathComponent.hasSuffix(".partial"))
    }

    func testEmptyChunkIsDiscardedWithoutReport() async throws {
        let writer = makeWriter()
        writer.begin(generation: 1)
        let outcome = await writer.finish()
        XCTAssertNil(outcome)
        XCTAssertTrue(log.closed.isEmpty)
        XCTAssertTrue(store.closedChunks().isEmpty)
    }

    // MARK: - Rotation

    func testRotationClosesChunkWhenDurationIsReached() async throws {
        let writer = makeWriter(chunkDuration: 1)
        writer.begin(generation: 1)
        append(writer, seconds: 2.5)
        _ = await writer.finish()
        XCTAssertEqual(log.closed.count, 3)
        XCTAssertEqual(log.closed[0].duration, 1, accuracy: 0.000_1)
        XCTAssertEqual(log.closed[1].duration, 1, accuracy: 0.000_1)
        XCTAssertEqual(log.closed[2].duration, 0.5, accuracy: 0.000_1)
    }

    func testRotationKeepsEveryFrame() async throws {
        let writer = makeWriter(chunkDuration: 0.75)
        writer.begin(generation: 1)
        append(writer, seconds: 3.3, bufferSeconds: 0.093)
        _ = await writer.finish()
        let written = log.closed.reduce(Int64(0)) { $0 + $1.frames }
        XCTAssertEqual(written, Int64(RecorderFixtures.frames(seconds: 3.3)))
        XCTAssertEqual(factory.files.reduce(Int64(0)) { $0 + $1.frames }, written)
    }

    func testRotatedChunkStartsExactlyWhereThePreviousEnded() async throws {
        let writer = makeWriter(chunkDuration: 1)
        writer.begin(generation: 1)
        append(writer, seconds: 1.5)
        clock.advance(by: 30) // wall clock drift must not create a gap or overlap
        append(writer, seconds: 1.5)
        _ = await writer.finish()
        let chunks = log.closed
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(next.startedAt.timeIntervalSince(previous.startedAt), previous.duration, accuracy: 0.000_1)
        }
    }

    func testRotationOnlyHappensBetweenBuffers() async throws {
        let writer = makeWriter(chunkDuration: 1)
        writer.begin(generation: 1)
        writer.append(RecorderFixtures.tone(frames: RecorderFixtures.frames(seconds: 0.7)), generation: 1)
        writer.append(RecorderFixtures.tone(frames: RecorderFixtures.frames(seconds: 0.7)), generation: 1)
        _ = await writer.finish()
        XCTAssertEqual(log.closed.map(\.duration), [0.7, 0.7].map { Double(RecorderFixtures.frames(seconds: $0)) / 44_100 })
    }

    // MARK: - Cut, finish, generations

    func testCutClosesCurrentChunkAndNextBufferOpensANewOne() async throws {
        let writer = makeWriter(chunkDuration: 60)
        writer.begin(generation: 1)
        append(writer, seconds: 0.5)
        let first = await writer.cut()
        append(writer, seconds: 0.5)
        let second = await writer.finish()
        XCTAssertNotNil(first?.closedURL)
        XCTAssertNotNil(second?.closedURL)
        XCTAssertNotEqual(first?.closedURL, second?.closedURL)
        XCTAssertEqual(store.closedChunks().count, 2)
    }

    func testCutResetsRotationCount() async throws {
        let writer = makeWriter(chunkDuration: 1)
        writer.begin(generation: 1)
        append(writer, seconds: 0.8)
        _ = await writer.cut()
        append(writer, seconds: 0.8)
        _ = await writer.finish()
        XCTAssertEqual(log.closed.count, 2)
        XCTAssertEqual(log.closed[1].duration, 0.8, accuracy: 0.000_1)
    }

    func testBuffersAfterFinishAreIgnored() async throws {
        let writer = makeWriter()
        writer.begin(generation: 1)
        append(writer, seconds: 0.2)
        _ = await writer.finish()
        append(writer, seconds: 0.2)
        await writer.drain()
        XCTAssertEqual(factory.files.count, 1)
        XCTAssertEqual(store.closedChunks().count, 1)
    }

    func testBuffersFromAStaleGenerationAreIgnored() async throws {
        let writer = makeWriter()
        writer.begin(generation: 2)
        append(writer, seconds: 0.2, generation: 1)
        await writer.drain()
        XCTAssertTrue(factory.files.isEmpty)
    }

    // MARK: - Failures

    func testCloseFailureQuarantinesChunkAndNeverReportsItClosed() async throws {
        factory.behavior.failClose = true
        let writer = makeWriter()
        writer.begin(generation: 1)
        append(writer, seconds: 0.3)
        let outcome = await writer.finish()
        guard case .quarantined(let url) = outcome else { return XCTFail("expected quarantine, got \(String(describing: outcome))") }
        XCTAssertTrue(log.closed.isEmpty)
        XCTAssertTrue(store.closedChunks().isEmpty)
        XCTAssertEqual(store.quarantinedFiles(), [url])
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".partial"))
    }

    func testWriteFailureReportsFailureAndStopsAccepting() async throws {
        let writer = makeWriter()
        writer.begin(generation: 7)
        factory.behavior.failWrites = true
        append(writer, seconds: 0.1, generation: 7)
        await writer.drain()
        XCTAssertEqual(log.events.last, .failed(RecorderMessages.writeFailed, generation: 7))
        factory.behavior.failWrites = false
        append(writer, seconds: 0.1, generation: 7)
        await writer.drain()
        XCTAssertEqual(factory.files.count, 1)
    }

    func testOpenFailureReportsFailure() async throws {
        factory.behavior.failOpen = true
        let writer = makeWriter()
        writer.begin(generation: 3)
        append(writer, seconds: 0.1, generation: 3)
        await writer.drain()
        XCTAssertEqual(log.events, [.failed(RecorderMessages.writeFailed, generation: 3)])
    }

    // MARK: - Real AAC encoding (no microphone)

    func testRealChunkIsMonoAACAt44100Hz() async throws {
        let writer = makeWriter(chunkDuration: 60, fileFactory: AACChunkFileFactory())
        writer.begin(generation: 1)
        append(writer, seconds: 1.0)
        let urlResult = await writer.finish()?.closedURL
        let url = try XCTUnwrap(urlResult)
        let file = try AVAudioFile(forReading: url)
        let description = file.fileFormat.streamDescription.pointee
        XCTAssertEqual(description.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 1.0, accuracy: 0.05)
    }

    func testRealChunkIsAnMPEG4Container() async throws {
        let writer = makeWriter(chunkDuration: 60, fileFactory: AACChunkFileFactory())
        writer.begin(generation: 1)
        append(writer, seconds: 0.5)
        let urlResult = await writer.finish()?.closedURL
        let url = try XCTUnwrap(urlResult)
        let header = try Data(contentsOf: url).prefix(12)
        XCTAssertEqual(String(decoding: header[4..<8], as: UTF8.self), "ftyp")
        XCTAssertEqual(String(decoding: header[8..<12], as: UTF8.self), "M4A ")
    }

    func testRealRotationProducesContiguousReadableChunks() async throws {
        let writer = makeWriter(chunkDuration: 0.5, fileFactory: AACChunkFileFactory())
        writer.begin(generation: 1)
        append(writer, seconds: 1.6)
        _ = await writer.finish()
        let chunks = log.closed
        XCTAssertEqual(chunks.count, 4)
        var decoded = 0.0
        for chunk in chunks {
            let file = try AVAudioFile(forReading: chunk.url)
            decoded += Double(file.length) / file.fileFormat.sampleRate
        }
        XCTAssertEqual(decoded, 1.6, accuracy: 0.05)
    }

    func testRealFileThatWasNeverFinalizedFailsVerification() throws {
        let url = root.appendingPathComponent("truncated.m4a.partial")
        try Data(repeating: 0, count: 4096).write(to: url)
        XCTAssertThrowsError(try AACChunkFile.verify(url))
    }
}
