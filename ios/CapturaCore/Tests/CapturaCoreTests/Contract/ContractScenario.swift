import Foundation
import XCTest
@testable import CapturaCore

/// The phone side of the cross-language contract with the unmodified macOS worker.
///
/// The real `UploadQueue`, `DriveClient` and `SyncEngine` upload fictional bytes to the
/// in-memory `FakeDriveServer`. The first upload is cut off mid-request and resumes on
/// the next run, a dictated note travels with two chunks, and a `.partial` file (a chunk
/// still being recorded) sits next to them. The resulting Drive state is exported the
/// way Drive v3 returns it to the worker and committed under `tests/fixtures/ios_contract/`,
/// where `tests/test_ios_contract.py` imports it with `worker/worker.py`.
enum ContractScenario {
    // Fictional values only. Changing any of them changes the committed fixture.
    static let deviceID = "6f9619ff-8b86-d011-b42d-00c04fc9c0de"
    /// Drive puts a file created without `parents` (the inbox folder) in My Drive.
    static let myDriveRootID = "fictionalMyDriveRoot"
    static let startedAt = Date(timeIntervalSince1970: 1_791_300_000)  // 2026-10-06 15:20:00 UTC
    static let bytesBeforeInterruption = 2_048
    static let utc = TimeZone(identifier: "UTC")!

    struct LocalFile {
        let name: String
        let bytes: Data
    }

    /// Cut off after `bytesBeforeInterruption` bytes on the first run; resumes on the second.
    static let firstChunk = LocalFile(
        name: CaptureNaming.chunkName(startedAt: startedAt, id: uuid(0xA1), timeZone: utc),
        bytes: fictionalAudio(count: 6_000, seed: 1)
    )
    static let secondChunk = LocalFile(
        name: CaptureNaming.chunkName(startedAt: startedAt.addingTimeInterval(900), id: uuid(0xA2), timeZone: utc),
        bytes: fictionalAudio(count: 4_500, seed: 2)
    )
    static let dictatedNote = LocalFile(
        name: "personal-capture-note-\(uuid(0xB1).uuidString.lowercased()).m4a",
        bytes: fictionalAudio(count: 3_000, seed: 3)
    )
    /// The chunk still being recorded. It must never reach Drive.
    static let recordingChunk = LocalFile(
        name: RecordingFiles.partialName(forChunkNamed: CaptureNaming.chunkName(
            startedAt: startedAt.addingTimeInterval(1_800), id: uuid(0xA3), timeZone: utc
        )),
        bytes: fictionalAudio(count: 2_500, seed: 4)
    )

    static var localFiles: [LocalFile] { [firstChunk, secondChunk, dictatedNote, recordingChunk] }
    static var uploadableFiles: [LocalFile] { [firstChunk, secondChunk, dictatedNote] }

    struct Outcome {
        /// Fixture contents by path relative to `tests/fixtures/ios_contract/`.
        var fixtureFiles: [String: Data]
        /// The interrupted run, the run that resumed, and a run with nothing left to do.
        var summaries: [SyncSummary]
        var uploadSessions: Int
        var queueItems: [UploadItem]
        var folderID: String
        /// Every Drive file and folder, as Drive returns it with the worker's `FIELDS`.
        var driveFiles: [String: [String: Any]]
        var driveContent: [String: Data]
    }

    static func run() async throws -> Outcome {
        let temp = try TemporaryDirectory()
        let captures = try temp.subdirectory("captures")
        for file in localFiles { try Fixture.write(file.bytes, named: file.name, in: captures) }

        let server = FakeDriveServer(myDriveRootID: myDriveRootID)
        server.inject(.dropNextChunk(persisting: bytesBeforeInterruption))
        let env = Environment(now: startedAt)
        let folders = FolderBox()
        let queue = try UploadQueue(storeDirectory: try temp.subdirectory("store"), capturesRoot: captures)
        let engine = SyncEngine(
            queue: queue, drive: makeClient(server), deviceID: deviceID,
            folderStorage: folders.storage, conditions: { env.conditions }, now: { env.now }
        )

        let interrupted = await engine.run(.automatic)
        env.now = env.now.addingTimeInterval(60 * 60)  // past the retry backoff
        let resumed = await engine.run(.automatic)
        let idle = await engine.run(.automatic)

        let folderID = try XCTUnwrap(folders.current)
        var driveFiles: [String: [String: Any]] = [:]
        var driveContent: [String: Data] = [:]
        for id in server.allIDs {
            driveFiles[id] = driveResponse(try XCTUnwrap(server.metadataJSON(of: id)))
            driveContent[id] = server.content(of: id)
        }
        let items = await queue.items()
        let fixtureFiles = try export(
            folderID: folderID, driveFiles: driveFiles, driveContent: driveContent,
            items: items, uploadSessions: server.sessionCount
        )
        withExtendedLifetime(temp) {}
        return Outcome(
            fixtureFiles: fixtureFiles, summaries: [interrupted, resumed, idle],
            uploadSessions: server.sessionCount, queueItems: items, folderID: folderID,
            driveFiles: driveFiles, driveContent: driveContent
        )
    }

    // MARK: - Export

    private static let driveFields = DriveMetadata.fields.split(separator: ",").map(String.init)

    /// `files.get` and `files.list` with the worker's `FIELDS` return those fields and no
    /// others; Drive omits `size` and `md5Checksum` for folders.
    static func driveResponse(_ stored: [String: Any]) -> [String: Any] {
        stored.filter { driveFields.contains($0.key) }
    }

    private static func export(
        folderID: String, driveFiles: [String: [String: Any]], driveContent: [String: Data],
        items: [UploadItem], uploadSessions: Int
    ) throws -> [String: Data] {
        var files: [String: Data] = ["README.md": Data(readme.utf8)]
        files["drive.json"] = try json([
            "folder_id": folderID,
            "files": driveFiles.keys.sorted().compactMap { driveFiles[$0] },
        ])
        for (id, meta) in driveFiles where meta["mimeType"] as? String != DriveMetadata.folderMimeType {
            files["media/\(id).hex"] = hexLines(driveContent[id] ?? Data())
        }

        let queued = Dictionary(uniqueKeysWithValues: items.map { ($0.fileName, $0) })
        let local: [[String: Any]] = localFiles.map { file in
            let sums = Checksums.compute(data: file.bytes)
            let item = queued[file.name]
            return [
                "name": file.name,
                "bytes": sums.bytes,
                "sha256": sums.sha256,
                "md5": sums.md5,
                "capture_kind": orNull(item?.kind.rawValue),
                "queue_state": orNull(item?.state.rawValue),
                "drive_file_id": orNull(item?.driveFileID),
            ]
        }
        files["phone.json"] = try json([
            "device_id": deviceID,
            "files": local,
            "resumed_upload": ["name": firstChunk.name, "bytes_sent_before_interruption": bytesBeforeInterruption],
            "upload_sessions_opened": uploadSessions,
        ])
        return files
    }

    private static func orNull(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    /// Lowercase hex, 32 bytes per line. The publication check refuses binary files and
    /// `.m4a`, so the uploaded bytes are committed as text.
    static func hexLines(_ data: Data) -> Data {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(data.count * 2 + data.count / 32 + 1)
        for (index, byte) in data.enumerated() {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
            if index % 32 == 31 || index == data.count - 1 { output.append(0x0A) }
        }
        return Data(output)
    }

    private static let readme = """
        # iOS uploader -> worker contract fixture

        Generated by `ios/CapturaCore/Tests/CapturaCoreTests/Contract/`. Do not edit by hand.

        The real `UploadQueue`, `DriveClient` and `SyncEngine` upload fictional bytes (not
        audio) to an in-memory Drive. The first upload is cut off mid-request and resumes on
        the next run; a dictated note travels with two chunks; a `.partial` file (a chunk
        still being recorded) stays on the phone. This directory holds the result:

        - `drive.json`: the inbox folder and every uploaded file as Drive v3 returns them
          with the worker's `FIELDS` (`size` as a string, no other fields).
        - `media/<id>.hex`: the bytes stored in Drive for each file, hex-encoded, because
          the publication check refuses binary and `.m4a` files.
        - `phone.json`: the phone's local files with their checksums, including the
          `.partial` file that must never reach Drive.

        `tests/test_ios_contract.py` serves this state to the unmodified `worker/worker.py`.
        The Swift test fails when the uploader's output no longer matches this directory.
        After an intended change, regenerate it and run both suites again:

            cd ios/CapturaCore
            CAPTURA_WRITE_CONTRACT_FIXTURES=1 swift test --filter WorkerFixtureContractTests

        """

    // MARK: - Fictional inputs

    private static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "6F9619FF-8B86-D011-B42D-%012X", index))!
    }

    /// Deterministic, non-repeating bytes. Not audio: the sync layer never decodes it.
    private static func fictionalAudio(count: Int, seed: UInt32) -> Data {
        var state = seed &* 2_654_435_761 &+ 0x5EED
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return Data(bytes)
    }
}
