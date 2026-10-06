import CryptoKit
import XCTest
@testable import CapturaCore

final class ChecksumsTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    func testEmptyFileHasReferenceDigests() throws {
        let url = try Fixture.write(Data(), named: "empty.bin", in: directory.url)
        let sums = try Checksums.compute(fileAt: url)
        XCTAssertEqual(sums.bytes, 0)
        XCTAssertEqual(sums.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sums.md5, "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testKnownVectorMatchesReferenceDigests() throws {
        let url = try Fixture.write(Data("abc".utf8), named: "abc.bin", in: directory.url)
        let sums = try Checksums.compute(fileAt: url)
        XCTAssertEqual(sums.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(sums.md5, "900150983cd24fb0d6963f7d28e17f72")
    }

    func testFileSpanningSeveralBlocksMatchesOneShotDigest() throws {
        let data = Fixture.bytes(3 * Checksums.blockSize + 1_234)
        let url = try Fixture.write(data, named: "multi.bin", in: directory.url)
        let sums = try Checksums.compute(fileAt: url)
        XCTAssertEqual(sums.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(sums.md5, Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testByteCountMatchesFileLength() throws {
        let url = try Fixture.write(Fixture.bytes(70_001), named: "count.bin", in: directory.url)
        XCTAssertEqual(try Checksums.compute(fileAt: url).bytes, 70_001)
    }

    func testDigestsAreLowercaseHexOfExpectedLength() throws {
        let sums = Checksums.compute(data: Fixture.bytes(5_000))
        XCTAssertTrue(WorkerContract.isLowercaseHex(sums.sha256, length: 64))
        XCTAssertTrue(WorkerContract.isLowercaseHex(sums.md5, length: 32))
    }

    func testFileAndDataDigestsAgree() throws {
        let data = Fixture.bytes(100_000, seed: 3)
        let url = try Fixture.write(data, named: "agree.bin", in: directory.url)
        XCTAssertEqual(try Checksums.compute(fileAt: url), Checksums.compute(data: data))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try Checksums.compute(fileAt: directory.url.appending(component: "absent.bin")))
    }

    func testCancelledTaskStopsHashing() async throws {
        let url = try Fixture.write(Fixture.bytes(200_000), named: "cancel.bin", in: directory.url)
        let task = Task { () throws -> FileChecksums in
            withUnsafeCurrentTask { $0?.cancel() }
            return try Checksums.compute(fileAt: url)
        }
        do {
            _ = try await task.value
            XCTFail("hashing should stop when the task is cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
