import Foundation
import XCTest
@testable import CapturaCore

final class WorkerFeedbackTransportTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1000)
    let sha = String(repeating: "a", count: 64)
    let folder = """
    {"id":"phoneFolder","mimeType":"application/vnd.google-apps.folder","ownedByMe":true,"shared":false,"trashed":false,"properties":{"personalCaptureInbox":"1","device":"test-device"}}
    """

    func fixture() throws -> Data {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appendingPathComponent("tests/fixtures/worker-feedback/report.json"))
    }

    func metadata(_ bytes: Data, shared: Bool = false) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "id":"reportID", "mimeType":"application/json", "parents":["phoneFolder"],
            "ownedByMe":true, "shared":shared, "trashed":false,
            "size":String(bytes.count), "md5Checksum":Checksums.compute(data: bytes).md5,
            "properties":["personalCaptureFeedback":"1", "sourceFolder":"phoneFolder", "device":"test-device"]
        ])
        return String(decoding: data, as: UTF8.self)
    }

    func transport(bytes: Data, shared: Bool = false, duplicate: Bool = false, response: Data? = nil) throws -> ScriptedTransport {
        let t = ScriptedTransport()
        let meta = try metadata(bytes, shared: shared)
        t.on("GET", Drive.files + "/phoneFolder", status: 200, json: folder)
        t.on("GET", Drive.files + "?", status: 200, json: "{\"files\":[\(meta)\(duplicate ? "," + meta : "")]}")
        if !shared && !duplicate {
            t.on("GET", Drive.files + "/reportID?fields=", status: 200, json: meta)
            t.on("GET", Drive.files + "/reportID?alt=media", status: 200, json: String(decoding: response ?? bytes, as: UTF8.self))
        }
        return t
    }

    func testActualPythonSnapshotTravelsThroughDriveClient() async throws {
        let t = try transport(bytes: fixture())
        let client = DriveClient(transport: t) { _ in testToken }
        let result = try await client.workerFeedback(folderID: "phoneFolder", deviceID: "test-device", now: date)
        XCTAssertEqual(result.state(id: "audioID", sha: sha), "transcribed")
        XCTAssertNil(result.state(id: "audioID", sha: String(repeating: "b", count: 64)))
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "GET" })
        XCTAssertEqual(t.remainingSteps, 0)
    }

    func testMissingReportIsUnknown() async throws {
        let t = ScriptedTransport()
        t.on("GET", Drive.files + "/phoneFolder", status: 200, json: folder)
        t.on("GET", Drive.files + "?", status: 200, json: "{\"files\":[]}")
        let result = try await DriveClient(transport: t) { _ in testToken }.workerFeedback(folderID: "phoneFolder", deviceID: "test-device", now: date)
        XCTAssertEqual(result, .unavailable)
    }

    func testMediaChangedAfterMetadataCannotBeDisplayed() async throws {
        let bytes = try fixture()
        let changed = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "audioID", with: "audioZZ").utf8)
        let t = try transport(bytes: bytes, response: changed)
        do {
            _ = try await DriveClient(transport: t) { _ in testToken }.workerFeedback(folderID: "phoneFolder", deviceID: "test-device", now: date)
            XCTFail("checksum mismatch must be rejected")
        } catch { XCTAssertEqual(error as? DriveError, .invalidResponse) }
    }

    func testSharedAndDuplicateReportsAreNotDownloaded() async throws {
        for duplicate in [false, true] {
            let t = try transport(bytes: fixture(), shared: !duplicate, duplicate: duplicate)
            do {
                _ = try await DriveClient(transport: t) { _ in testToken }.workerFeedback(folderID: "phoneFolder", deviceID: "test-device", now: date)
                XCTFail("report must be rejected")
            } catch { XCTAssertEqual(error as? DriveError, .invalidResponse) }
            XCTAssertEqual(t.requests.count, 2)
        }
    }

    func testExpiredAndFutureReportsCannotKeepOldSuccess() throws {
        let bytes = try fixture()
        XCTAssertEqual(WorkerFeedback.parse(bytes, now: date.addingTimeInterval(3601)), .unavailable)
        XCTAssertEqual(WorkerFeedback.parse(bytes, now: date.addingTimeInterval(-61)), .unavailable)
        XCTAssertEqual(WorkerFeedback.parse(bytes, now: date, folderID: "otherFolder"), .unavailable)
        XCTAssertEqual(WorkerFeedback.parse(bytes, now: date, deviceID: "other-device"), .unavailable)
    }

    func testConflictingReceiptsCannotFabricateCompletion() throws {
        var report = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String:Any])
        report["records"] = [
            ["id":"audioID", "sha256":sha, "state":"transcribed"],
            ["id":"audioID", "sha256":sha, "state":"error"]
        ]
        let value = WorkerFeedback.parse(try JSONSerialization.data(withJSONObject: report), now: date)
        XCTAssertNil(value.state(id: "audioID", sha: sha))
    }
}
