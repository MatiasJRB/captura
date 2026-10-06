import Foundation
import XCTest
@testable import CapturaCore

/// Keeps `tests/fixtures/ios_contract/` equal to what the iOS uploader produces now.
/// `tests/test_ios_contract.py` proves the unmodified worker imports that fixture, so
/// together they pin the contract across languages. See `ContractScenario`.
final class WorkerFixtureContractTests: XCTestCase {
    static let writeVariable = "CAPTURA_WRITE_CONTRACT_FIXTURES"

    func testCommittedFixtureMatchesWhatTheUploaderProducesNow() async throws {
        let produced = try await ContractScenario.run().fixtureFiles
        let directory = try ContractFixture.directory()
        if ProcessInfo.processInfo.environment[Self.writeVariable] == "1" {
            try ContractFixture.write(produced, to: directory)
            return
        }
        let problems = try ContractFixture.differences(expected: produced, in: directory)
        XCTAssertTrue(problems.isEmpty, """
            tests/fixtures/ios_contract/ no longer matches what the iOS uploader produces:
            \(problems.joined(separator: "\n"))
            If the change is intended, regenerate the fixture and run tests/test_ios_contract.py:
              cd ios/CapturaCore && \(Self.writeVariable)=1 swift test --filter WorkerFixtureContractTests
            """)
    }

    func testScenarioProducesTheSameFixtureEveryTime() async throws {
        let first = try await ContractScenario.run().fixtureFiles
        let second = try await ContractScenario.run().fixtureFiles
        XCTAssertEqual(first, second)
    }

    func testInterruptedUploadResumesItsSessionOnTheNextRun() async throws {
        let outcome = try await ContractScenario.run()
        let (interrupted, resumed, idle) = (outcome.summaries[0], outcome.summaries[1], outcome.summaries[2])

        XCTAssertEqual(interrupted.stopReason, .retryLater(code: DriveError.connectionFailed.code))
        XCTAssertEqual(interrupted.uploaded, 0)
        XCTAssertEqual(resumed.uploaded, 3)
        XCTAssertNil(resumed.stopReason)
        XCTAssertEqual(resumed.remaining, 0)
        XCTAssertEqual(resumed.needsReview, 0)
        XCTAssertEqual(idle.uploaded, 0)
        XCTAssertEqual(idle.remaining, 0)
        // One session per file: the interrupted one was resumed, not restarted. The fake
        // also refuses any chunk that does not start at the byte Drive already holds.
        XCTAssertEqual(outcome.uploadSessions, 3)
    }

    func testPartialFileNeverReachesDrive() async throws {
        let outcome = try await ContractScenario.run()
        let partial = ContractScenario.recordingChunk.name
        XCTAssertTrue(partial.hasSuffix(CaptureNaming.partialSuffix), "precondition: \(partial)")

        XCTAssertNil(outcome.queueItems.first { $0.fileName == partial })
        let driveNames = outcome.driveFiles.values.compactMap { $0["name"] as? String }
        XCTAssertFalse(driveNames.contains { $0.hasSuffix(CaptureNaming.partialSuffix) }, "\(driveNames)")
        let phone = try fixtureJSON(outcome, "phone.json")
        let entry = try XCTUnwrap((phone["files"] as? [[String: Any]])?.first { $0["name"] as? String == partial })
        XCTAssertTrue(entry["drive_file_id"] is NSNull)
    }

    func testEveryOriginalIsInDriveByteForByteWithItsCaptureKind() async throws {
        let outcome = try await ContractScenario.run()
        XCTAssertEqual(outcome.queueItems.map(\.fileName), ContractScenario.uploadableFiles.map(\.name).sorted())
        for file in ContractScenario.uploadableFiles {
            let item = try XCTUnwrap(outcome.queueItems.first { $0.fileName == file.name })
            XCTAssertEqual(item.state, .verified, file.name)
            let id = try XCTUnwrap(item.driveFileID)
            XCTAssertEqual(outcome.driveContent[id], file.bytes, file.name)
            let properties = try XCTUnwrap(outcome.driveFiles[id]?["properties"] as? [String: String])
            XCTAssertEqual(properties[DriveMetadata.captureKindPropertyKey], CaptureKind.from(fileName: file.name).rawValue)
        }
        let note = try XCTUnwrap(outcome.queueItems.first { $0.fileName == ContractScenario.dictatedNote.name })
        XCTAssertEqual(note.kind, .dictatedNote)
    }

    func testExportedDriveStatePassesTheSwiftMirrorOfTheWorkerRules() async throws {
        let outcome = try await ContractScenario.run()
        let drive = try fixtureJSON(outcome, "drive.json")
        XCTAssertEqual(drive["folder_id"] as? String, outcome.folderID)
        let files = try XCTUnwrap(drive["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 4)
        var audios = 0
        for object in files {
            let meta = try DriveFileMetadata.decode(JSONSerialization.data(withJSONObject: object))
            if meta.mimeType == DriveMetadata.folderMimeType {
                XCTAssertNoThrow(try WorkerContract.verifyFolder(meta, expected: outcome.folderID))
                XCTAssertEqual(meta.parents, [ContractScenario.myDriveRootID])
                continue
            }
            audios += 1
            XCTAssertTrue(object["size"] is String, "Drive encodes int64 as a JSON string")
            XCTAssertNoThrow(try WorkerContract.verifyAudio(meta, folderID: outcome.folderID))
            let id = try XCTUnwrap(meta.id)
            let hex = try XCTUnwrap(outcome.fixtureFiles["media/\(id).hex"])
            XCTAssertEqual(hex, ContractScenario.hexLines(try XCTUnwrap(outcome.driveContent[id])))
            let stored = Checksums.compute(data: try XCTUnwrap(outcome.driveContent[id]))
            XCTAssertNoThrow(try WorkerContract.validateBytes(stored, against: meta))
        }
        XCTAssertEqual(audios, 3)
    }

    func testHexLinesWrapEvery32Bytes() {
        let data = Data((0..<33).map { UInt8($0) })
        let text = String(decoding: ContractScenario.hexLines(data), as: UTF8.self)
        XCTAssertEqual(text, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n20\n")
        XCTAssertEqual(ContractScenario.hexLines(Data()), Data())
    }

    private func fixtureJSON(_ outcome: ContractScenario.Outcome, _ path: String) throws -> [String: Any] {
        let data = try XCTUnwrap(outcome.fixtureFiles[path], path)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Reads, compares and (only on request) rewrites `tests/fixtures/ios_contract/`.
enum ContractFixture {
    struct LocationError: Error, CustomStringConvertible {
        let description: String
    }

    private static let thisFile = #filePath

    /// `<repo>/tests/fixtures/ios_contract`, found from this source file's location.
    static func directory() throws -> URL {
        var root = URL(fileURLWithPath: thisFile)
        // Contract/<file> -> CapturaCoreTests -> Tests -> CapturaCore -> ios -> repo
        for _ in 0..<6 { root.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: root.appending(path: "worker/worker.py").path) else {
            throw LocationError(description: "repository root not found from \(thisFile)")
        }
        return root.appending(path: "tests/fixtures/ios_contract", directoryHint: .isDirectory)
    }

    /// Regular, non-hidden files below `directory`, by relative path.
    static func read(_ directory: URL) throws -> [String: Data] {
        guard let paths = FileManager.default.enumerator(atPath: directory.path) else { return [:] }
        var files: [String: Data] = [:]
        while let path = paths.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            var isDirectory: ObjCBool = false
            let url = directory.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            files[path] = try Data(contentsOf: url)
        }
        return files
    }

    /// Byte-exact comparison: one line per missing, changed or unexpected file.
    static func differences(expected: [String: Data], in directory: URL) throws -> [String] {
        let committed = try read(directory)
        var problems: [String] = []
        for path in expected.keys.sorted() {
            switch committed[path] {
            case nil: problems.append("missing: \(path)")
            case let data? where data != expected[path]: problems.append("changed: \(path)")
            default: break
            }
        }
        for path in committed.keys.sorted() where expected[path] == nil {
            problems.append("unexpected: \(path)")
        }
        return problems
    }

    /// Writes every produced file and removes committed files that are no longer produced.
    static func write(_ files: [String: Data], to directory: URL) throws {
        for path in try read(directory).keys where files[path] == nil {
            try FileManager.default.removeItem(at: directory.appending(path: path))
        }
        for (path, data) in files {
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}
