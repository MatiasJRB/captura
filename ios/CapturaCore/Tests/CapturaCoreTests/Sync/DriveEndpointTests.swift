import XCTest
@testable import CapturaCore

/// Mirrors `SyncTests.rejectsTokenExfiltrationEndpoints` and extends it to session URIs.
final class DriveEndpointTests: XCTestCase {
    private func allowed(_ string: String) -> Bool {
        DriveEndpoint.isAllowed(URL(string: string)!)
    }

    func testFixedEndpointsAreAllowed() {
        XCTAssertTrue(DriveEndpoint.isAllowed(DriveEndpoint.api))
        XCTAssertTrue(DriveEndpoint.isAllowed(DriveEndpoint.generateIDs))
        XCTAssertTrue(DriveEndpoint.isAllowed(DriveEndpoint.createFile))
        XCTAssertTrue(DriveEndpoint.isAllowed(DriveEndpoint.resumableUpload))
    }

    func testPlainHTTPIsRejected() {
        XCTAssertFalse(allowed("http://www.googleapis.com/"))
    }

    func testOtherHostIsRejected() {
        XCTAssertFalse(allowed("https://evil.example/"))
    }

    func testLookalikeHostSuffixIsRejected() {
        XCTAssertFalse(allowed("https://www.googleapis.com.evil.example/"))
    }

    func testUserInfoIsRejected() {
        XCTAssertFalse(allowed("https://user@www.googleapis.com/"))
        XCTAssertFalse(allowed("https://user:secret@www.googleapis.com/"))
    }

    func testHostHiddenBehindUserInfoIsRejected() {
        XCTAssertFalse(allowed("https://www.googleapis.com@evil.example/"))
    }

    func testNonStandardPortIsRejected() {
        XCTAssertFalse(allowed("https://www.googleapis.com:8443/"))
    }

    func testExplicitPort443IsAllowed() {
        XCTAssertTrue(allowed("https://www.googleapis.com:443/upload/drive/v3/files?upload_id=x"))
    }

    func testRelativeURLIsRejected() {
        XCTAssertFalse(allowed("/upload/drive/v3/files?upload_id=x"))
    }

    func testEvilSessionURIIsNeverContacted() async {
        let transport = ScriptedTransport()
        let client = makeClient(transport)
        do {
            _ = try await client.uploadStatus(session: URL(string: "https://evil.example/upload?upload_id=x")!, totalBytes: 2_000)
            XCTFail("an off-host session URI must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidEndpoint)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testEvilLocationHeaderFromUploadStartIsRefused() async throws {
        let directory = try TemporaryDirectory()
        let name = Fixture.chunkName(1)
        let data = Fixture.bytes(4_000)
        let url = try Fixture.write(data, named: name, in: directory.url)
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": "https://evil.example/upload?upload_id=stolen"])
        let upload = DriveUpload(fileID: "fileId1", name: name, fileURL: url, checksums: Checksums.compute(data: data))
        do {
            _ = try await makeClient(transport).beginUpload(upload, folderID: "folder")
            XCTFail("an off-host Location must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidEndpoint)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testPlainHTTPLocationHeaderIsRefused() async throws {
        let directory = try TemporaryDirectory()
        let name = Fixture.chunkName(2)
        let data = Fixture.bytes(4_000)
        let url = try Fixture.write(data, named: name, in: directory.url)
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: [
            "Location": "http://www.googleapis.com/upload/drive/v3/files?upload_id=x",
        ])
        let upload = DriveUpload(fileID: "fileId1", name: name, fileURL: url, checksums: Checksums.compute(data: data))
        do {
            _ = try await makeClient(transport).beginUpload(upload, folderID: "folder")
            XCTFail("a plain-HTTP Location must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidEndpoint)
        }
    }
}
