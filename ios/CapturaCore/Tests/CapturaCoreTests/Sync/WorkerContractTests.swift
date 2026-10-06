import XCTest
@testable import CapturaCore

/// Mirrors `worker/test_worker.py` and the rules of `verify_folder`, `verify_audio`,
/// `validate_bytes` and `identifier`.
final class WorkerContractTests: XCTestCase {
    private let data = Fixture.bytes(4_200)
    private var sums: FileChecksums { Checksums.compute(data: data) }

    private var audio: DriveFileMetadata {
        DriveFileMetadata(
            id: "audio_1", name: Fixture.chunkName(1), mimeType: "audio/mp4", size: sums.bytes,
            md5Checksum: sums.md5, parents: ["folder"],
            properties: ["personalCaptureAudio": "1", "sha256": sums.sha256, "captureKind": "ambient_audio"],
            shared: false, ownedByMe: true, trashed: false
        )
    }

    private var folder: DriveFileMetadata {
        DriveFileMetadata(
            id: "folder", name: "Captura · audios", mimeType: "application/vnd.google-apps.folder",
            properties: ["personalCaptureInbox": "1", "device": "test-device"],
            shared: false, ownedByMe: true, trashed: false
        )
    }

    private func assertAudioRejected(
        _ meta: DriveFileMetadata, as rejection: WorkerContract.Rejection, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try WorkerContract.verifyAudio(meta, folderID: "folder"), file: file, line: line) { error in
            XCTAssertEqual(error as? WorkerContract.Rejection, rejection, file: file, line: line)
        }
    }

    func testMaxAudioMatchesWorker() {
        XCTAssertEqual(WorkerContract.maxAudioBytes, 64 * 1024 * 1024)
    }

    func testValidAudioIsAccepted() throws {
        XCTAssertEqual(try WorkerContract.verifyAudio(audio, folderID: "folder"), sums.bytes)
    }

    func testLegacyM4AMimeTypeIsAccepted() throws {
        var meta = audio
        meta.mimeType = "audio/x-m4a"
        XCTAssertNoThrow(try WorkerContract.verifyAudio(meta, folderID: "folder"))
    }

    func testSharedAudioIsRejected() {
        var meta = audio
        meta.shared = true
        assertAudioRejected(meta, as: .invalidAudioMetadata)
    }

    func testAudioWithoutExplicitSharedFlagIsRejected() {
        var meta = audio
        meta.shared = nil
        assertAudioRejected(meta, as: .invalidAudioMetadata)
    }

    func testAudioNotOwnedIsRejected() {
        var meta = audio
        meta.ownedByMe = false
        assertAudioRejected(meta, as: .invalidAudioMetadata)
    }

    func testTrashedAudioIsRejected() {
        var meta = audio
        meta.trashed = true
        assertAudioRejected(meta, as: .invalidAudioMetadata)
    }

    func testAudioInAnotherFolderIsRejected() {
        var meta = audio
        meta.parents = ["other"]
        assertAudioRejected(meta, as: .invalidAudioMetadata)
    }

    func testAudioWithOtherMimeTypeIsRejected() {
        var meta = audio
        meta.mimeType = "audio/mpeg"
        assertAudioRejected(meta, as: .invalidAudioMetadata)
    }

    func testAudioWithoutCaptureMarkerIsRejected() {
        var meta = audio
        meta.properties["personalCaptureAudio"] = nil
        assertAudioRejected(meta, as: .invalidAudioMetadata)
    }

    func testUppercaseSHAIsRejected() {
        var meta = audio
        meta.properties["sha256"] = sums.sha256.uppercased()
        assertAudioRejected(meta, as: .invalidAudioMetadata)
    }

    func testShortMD5IsRejected() {
        var meta = audio
        meta.md5Checksum = String(sums.md5.dropLast())
        assertAudioRejected(meta, as: .invalidAudioMetadata)
    }

    func testAudioOfExactly1024BytesIsOutOfBounds() {
        var meta = audio
        meta.size = 1_024
        assertAudioRejected(meta, as: .audioSizeOutOfBounds)
    }

    func testAudioOf1025BytesIsAccepted() {
        var meta = audio
        meta.size = 1_025
        XCTAssertNoThrow(try WorkerContract.verifyAudio(meta, folderID: "folder"))
    }

    func testAudioAtMaxAudioIsAccepted() {
        var meta = audio
        meta.size = WorkerContract.maxAudioBytes
        XCTAssertNoThrow(try WorkerContract.verifyAudio(meta, folderID: "folder"))
    }

    func testAudioAboveMaxAudioIsOutOfBounds() {
        var meta = audio
        meta.size = WorkerContract.maxAudioBytes + 1
        assertAudioRejected(meta, as: .audioSizeOutOfBounds)
    }

    func testAudioWithUnsafeIDIsRejected() {
        var meta = audio
        meta.id = "../escape"
        assertAudioRejected(meta, as: .invalidDriveID)
    }

    func testIdentifierRules() {
        XCTAssertTrue(WorkerContract.isDriveIdentifier("abc_DEF-123"))
        XCTAssertFalse(WorkerContract.isDriveIdentifier(""))
        XCTAssertFalse(WorkerContract.isDriveIdentifier("../escape"))
        XCTAssertFalse(WorkerContract.isDriveIdentifier("a b"))
        XCTAssertTrue(WorkerContract.isDriveIdentifier(String(repeating: "a", count: 200)))
        XCTAssertFalse(WorkerContract.isDriveIdentifier(String(repeating: "a", count: 201)))
    }

    func testValidFolderIsAccepted() {
        XCTAssertNoThrow(try WorkerContract.verifyFolder(folder, expected: "folder"))
    }

    func testSharedFolderIsRejected() {
        var meta = folder
        meta.shared = true
        XCTAssertThrowsError(try WorkerContract.verifyFolder(meta)) {
            XCTAssertEqual($0 as? WorkerContract.Rejection, .folderNotPrivateCapture)
        }
    }

    func testFolderWithoutDeviceIsRejected() {
        var meta = folder
        meta.properties["device"] = ""
        XCTAssertThrowsError(try WorkerContract.verifyFolder(meta)) {
            XCTAssertEqual($0 as? WorkerContract.Rejection, .folderNotPrivateCapture)
        }
    }

    func testUnexpectedFolderIDIsRejected() {
        XCTAssertThrowsError(try WorkerContract.verifyFolder(folder, expected: "other")) {
            XCTAssertEqual($0 as? WorkerContract.Rejection, .wrongFolder)
        }
    }

    func testMatchingBytesAreValidated() throws {
        XCTAssertEqual(try WorkerContract.validateBytes(sums, against: audio), sums.sha256)
    }

    func testCorruptedBytesAreRejected() {
        let corrupted = Checksums.compute(data: data + Data("corruption".utf8))
        XCTAssertThrowsError(try WorkerContract.validateBytes(corrupted, against: audio)) {
            XCTAssertEqual($0 as? WorkerContract.Rejection, .downloadChecksumMismatch)
        }
    }
}
