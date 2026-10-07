import XCTest
@testable import CapturaCore

/// The JSON the phone writes must carry exactly the values `DriveApi.java` writes.
final class DriveMetadataTests: XCTestCase {
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFolderJSONHasExactlyTheAndroidFields() throws {
        let json = try object(DriveMetadata.folderJSON(id: "folderId1", deviceID: "device-1"))
        XCTAssertEqual(Set(json.keys), ["id", "name", "mimeType", "properties"])
        XCTAssertEqual(json["id"] as? String, "folderId1")
        XCTAssertEqual(json["name"] as? String, "Captura · audios")
        XCTAssertEqual(json["mimeType"] as? String, "application/vnd.google-apps.folder")
        XCTAssertEqual(json["properties"] as? [String: String], ["personalCaptureInbox": "1", "device": "device-1"])
    }

    func testFileJSONHasExactlyTheAndroidFields() throws {
        let name = Fixture.chunkName(3)
        let sha = String(repeating: "ab", count: 32)
        let json = try object(DriveMetadata.fileJSON(id: "fileId1", name: name, folderID: "folderId1", sha256: sha))
        XCTAssertEqual(Set(json.keys), ["id", "name", "mimeType", "parents", "properties"])
        XCTAssertEqual(json["id"] as? String, "fileId1")
        XCTAssertEqual(json["name"] as? String, name)
        XCTAssertEqual(json["mimeType"] as? String, "audio/mp4")
        XCTAssertEqual(json["parents"] as? [String], ["folderId1"])
        XCTAssertEqual(
            json["properties"] as? [String: String],
            ["personalCaptureAudio": "1", "sha256": sha, "captureKind": "ambient_audio"]
        )
    }

    func testDictatedNoteCarriesItsCaptureKind() throws {
        let json = try object(DriveMetadata.fileJSON(id: "f", name: Fixture.noteName, folderID: "d", sha256: "s"))
        XCTAssertEqual((json["properties"] as? [String: String])?["captureKind"], "dictated_note")
    }

    func testInterruptedNoteCarriesItsCaptureKind() throws {
        let json = try object(DriveMetadata.fileJSON(id: "f", name: Fixture.draftNoteName, folderID: "d", sha256: "s"))
        XCTAssertEqual((json["properties"] as? [String: String])?["captureKind"], "note_interrupted")
    }

    func testFolderNameIsEncodedAsUTF8() {
        let text = String(decoding: DriveMetadata.folderJSON(id: "f", deviceID: "d"), as: UTF8.self)
        XCTAssertTrue(text.contains("Captura · audios"))
    }

    func testJSONIsDeterministic() {
        XCTAssertEqual(
            DriveMetadata.fileJSON(id: "f", name: Fixture.chunkName(1), folderID: "d", sha256: "s"),
            DriveMetadata.fileJSON(id: "f", name: Fixture.chunkName(1), folderID: "d", sha256: "s")
        )
    }

    func testFieldsSelectorMatchesWorker() {
        XCTAssertEqual(DriveMetadata.fields, "id,name,mimeType,size,md5Checksum,parents,properties,shared,ownedByMe,trashed")
    }

    func testMetadataDecodesSizeSentAsString() throws {
        let meta = try DriveFileMetadata.decode(Data(#"{"id":"a","size":"4096"}"#.utf8))
        XCTAssertEqual(meta.size, 4_096)
    }

    func testMetadataDecodesSizeSentAsNumber() throws {
        let meta = try DriveFileMetadata.decode(Data(#"{"id":"a","size":40}"#.utf8))
        XCTAssertEqual(meta.size, 40)
    }

    func testMetadataToleratesMissingFields() throws {
        let meta = try DriveFileMetadata.decode(Data("{}".utf8))
        XCTAssertNil(meta.id)
        XCTAssertNil(meta.size)
        XCTAssertNil(meta.shared)
        XCTAssertEqual(meta.parents, [])
        XCTAssertEqual(meta.properties, [:])
    }

    func testMalformedMetadataIsInvalidResponse() {
        XCTAssertThrowsError(try DriveFileMetadata.decode(Data("not json".utf8))) {
            XCTAssertEqual($0 as? DriveError, .invalidResponse)
        }
    }
}
