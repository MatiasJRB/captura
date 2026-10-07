import XCTest
@testable import CapturaCore

final class CaptureNamingTests: XCTestCase {
    func testChunkNameMatchesAndroidPattern() {
        let date = Date(timeIntervalSince1970: 1_791_300_000)
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let name = CaptureNaming.chunkName(startedAt: date, id: id, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "personal-capture-20261006-152000-6f9619ff-8b86-d011-b42d-00c04fc964ff.m4a")
        XCTAssertTrue(CaptureNaming.isChunkName(name))
    }

    func testOrdinaryChunkIsAmbientAudio() {
        let name = CaptureNaming.chunkName(startedAt: Date())
        XCTAssertEqual(CaptureKind.from(fileName: name), .ambientAudio)
    }

    func testNoteNamesMapToNoteKinds() {
        let uuid = "6f9619ff-8b86-d011-b42d-00c04fc964ff"
        XCTAssertEqual(CaptureKind.from(fileName: "personal-capture-note-\(uuid).m4a"), .dictatedNote)
        XCTAssertEqual(CaptureKind.from(fileName: "personal-capture-note-draft-\(uuid).m4a"), .noteInterrupted)
    }

    func testPartialFileIsNotAChunkName() {
        let name = CaptureNaming.chunkName(startedAt: Date()) + CaptureNaming.partialSuffix
        XCTAssertFalse(CaptureNaming.isChunkName(name))
    }
}
