import XCTest
@testable import CapturaCore

final class UploadQueueTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var captures: URL!
    private var store: URL!
    private let now = Fixture.baseDate

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
        captures = try temp.subdirectory("captures")
        store = try temp.subdirectory("store")
    }

    override func tearDown() {
        temp = nil
    }

    private func makeQueue(sealer: any SecretSealer = IdentitySecretSealer()) throws -> UploadQueue {
        try UploadQueue(storeDirectory: store, capturesRoot: captures, sealer: sealer)
    }

    @discardableResult
    private func writeChunk(_ index: Int, bytes: Int = 4_000, in directory: URL? = nil) throws -> URL {
        try Fixture.write(Fixture.bytes(bytes, seed: UInt8(index % 250)), named: Fixture.chunkName(index), in: directory ?? captures)
    }

    private func assertRefused(_ url: URL, as expected: UploadQueueError, line: UInt = #line) async throws {
        let queue = try makeQueue()
        do {
            try await queue.enqueue(fileAt: url, now: now)
            XCTFail("\(url.lastPathComponent) must be refused", line: line)
        } catch {
            XCTAssertEqual(error as? UploadQueueError, expected, line: line)
        }
        let count = await queue.items().count
        XCTAssertEqual(count, 0, line: line)
    }

    // MARK: Enqueue

    func testEnqueueRecordsChecksumsKindAndPath() async throws {
        let url = try writeChunk(1)
        let queue = try makeQueue()

        let item = try await queue.enqueue(fileAt: url, now: now)

        let expected = try Checksums.compute(fileAt: url)
        XCTAssertEqual(item.id, Fixture.chunkName(1))
        XCTAssertEqual(item.relativePath, Fixture.chunkName(1))
        XCTAssertEqual(item.checksums, expected)
        XCTAssertEqual(item.kind, .ambientAudio)
        XCTAssertEqual(item.state, .pending)
        XCTAssertEqual(item.createdAt, now)
        XCTAssertNil(item.driveFileID)
    }

    func testEnqueueKeepsSubdirectoryInRelativePath() async throws {
        let day = try temp.subdirectory("captures/2026-10-06")
        let url = try writeChunk(1, in: day)
        let item = try await makeQueue().enqueue(fileAt: url, now: now)
        XCTAssertEqual(item.relativePath, "2026-10-06/\(Fixture.chunkName(1))")
    }

    func testPartialFileIsRefused() async throws {
        let url = try Fixture.write(Fixture.bytes(4_000), named: Fixture.chunkName(1) + ".partial", in: captures)
        try await assertRefused(url, as: .partialFile)
    }

    func testUnknownFileNameIsRefused() async throws {
        let url = try Fixture.write(Fixture.bytes(4_000), named: "voice-memo.m4a", in: captures)
        try await assertRefused(url, as: .notACaptureFile)
    }

    func testFileOf1024BytesIsRefused() async throws {
        try await assertRefused(try writeChunk(1, bytes: 1_024), as: .tooSmall)
    }

    func testFileOf1025BytesIsAccepted() async throws {
        let item = try await makeQueue().enqueue(fileAt: try writeChunk(1, bytes: 1_025), now: now)
        XCTAssertEqual(item.bytes, 1_025)
    }

    func testFileAboveWorkerLimitIsRefused() async throws {
        let url = captures.appending(component: Fixture.chunkName(1))
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(WorkerContract.maxAudioBytes + 1))
        try handle.close()
        try await assertRefused(url, as: .tooLarge)
    }

    func testFileOutsideCapturesRootIsRefused() async throws {
        let elsewhere = try temp.subdirectory("elsewhere")
        try await assertRefused(try writeChunk(1, in: elsewhere), as: .outsideCapturesRoot)
    }

    func testSymbolicLinkIsRefused() async throws {
        let elsewhere = try temp.subdirectory("elsewhere")
        let target = try writeChunk(1, in: elsewhere)
        let link = captures.appending(component: Fixture.chunkName(2))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await assertRefused(link, as: .notARegularFile)
    }

    func testNoteNamesAreAcceptedWithTheirKinds() async throws {
        let queue = try makeQueue()
        let note = try await queue.enqueue(fileAt: try Fixture.write(Fixture.bytes(3_000), named: Fixture.noteName, in: captures), now: now)
        let draft = try await queue.enqueue(fileAt: try Fixture.write(Fixture.bytes(3_000), named: Fixture.draftNoteName, in: captures), now: now)
        XCTAssertEqual(note.kind, .dictatedNote)
        XCTAssertEqual(draft.kind, .noteInterrupted)
    }

    func testEnqueueingTheSameFileTwiceKeepsOneItem() async throws {
        let url = try writeChunk(1)
        let queue = try makeQueue()
        let first = try await queue.enqueue(fileAt: url, now: now)
        let second = try await queue.enqueue(fileAt: url, now: now.addingTimeInterval(60))
        let count = await queue.items().count
        XCTAssertEqual(first, second)
        XCTAssertEqual(count, 1)
    }

    func testChangedBytesUnderAKnownNameAreRefused() async throws {
        let url = try writeChunk(1)
        let queue = try makeQueue()
        let original = try await queue.enqueue(fileAt: url, now: now)
        try Fixture.bytes(4_000, seed: 99).write(to: url)
        do {
            try await queue.enqueue(fileAt: url, now: now)
            XCTFail("different bytes under the same name must be refused")
        } catch {
            XCTAssertEqual(error as? UploadQueueError, .contentChanged)
        }
        let stored = await queue.item(id: original.id)
        XCTAssertEqual(stored, original)
    }

    func testVerifiedFileIsNotQueuedForUploadAgain() async throws {
        let url = try writeChunk(1)
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: url, now: now)
        try await queue.markVerified(item.id, driveFileID: "drive1", at: now)

        let again = try await queue.enqueue(fileAt: url, now: now)
        let eligible = await queue.eligible(now: now, ignoringBackoff: true)

        XCTAssertEqual(again.state, .verified)
        XCTAssertEqual(again.driveFileID, "drive1")
        XCTAssertTrue(eligible.isEmpty)
    }

    // MARK: Discover

    func testDiscoverQueuesOnlyClosedCaptureFiles() async throws {
        try writeChunk(1)
        try writeChunk(2)
        try Fixture.write(Fixture.bytes(4_000), named: Fixture.chunkName(3) + ".partial", in: captures)
        try writeChunk(4, bytes: 512)
        try Fixture.write(Fixture.bytes(4_000), named: "readme.txt", in: captures)
        try Fixture.write(Fixture.bytes(4_000), named: "." + Fixture.chunkName(5), in: captures)
        let queue = try makeQueue()

        let added = try await queue.discover(now: now)

        XCTAssertEqual(added.map(\.id), [Fixture.chunkName(1), Fixture.chunkName(2)])
    }

    func testDiscoverSkipsFilesAlreadyQueued() async throws {
        try writeChunk(1)
        let queue = try makeQueue()
        _ = try await queue.discover(now: now)
        try writeChunk(2)
        let added = try await queue.discover(now: now)
        XCTAssertEqual(added.map(\.id), [Fixture.chunkName(2)])
    }

    func testDiscoverFindsFilesInSubdirectories() async throws {
        let day = try temp.subdirectory("captures/day")
        try writeChunk(1, in: day)
        let added = try await makeQueue().discover(now: now)
        XCTAssertEqual(added.map(\.relativePath), ["day/\(Fixture.chunkName(1))"])
    }

    // MARK: Persistence

    func testQueueSurvivesReload() async throws {
        let url = try writeChunk(1)
        let first = try makeQueue()
        let item = try await first.enqueue(fileAt: url, now: now)
        try await first.assignDriveFileID("drive1", to: item.id)
        try await first.setSessionURI(URL(string: Drive.session)!, for: item.id)
        try await first.recordFailure(item.id, code: "drive-retry-later-503", rejected: false, now: now)
        let saved = await first.item(id: item.id)

        let reloaded = try makeQueue()
        let restored = await reloaded.item(id: item.id)
        let session = await reloaded.sessionURI(for: item.id)

        XCTAssertEqual(restored, saved)
        XCTAssertEqual(session, URL(string: Drive.session)!)
    }

    func testItemInterruptedWhileUploadingReloadsAsPending() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.markUploading(item.id)

        let reloaded = try makeQueue()
        let state = await reloaded.item(id: item.id)?.state

        XCTAssertEqual(state, .pending)
    }

    func testStoreUsesTheDocumentedFileName() async throws {
        let queue = try makeQueue()
        try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        XCTAssertEqual(queue.storeURL.lastPathComponent, "upload-queue.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.storeURL.path))
    }

    func testWritesLeaveNoTemporaryFilesBehind() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.assignDriveFileID("drive1", to: item.id)
        try await queue.markUploading(item.id)
        try await queue.markVerified(item.id, driveFileID: "drive1", at: now)

        let files = try FileManager.default.contentsOfDirectory(atPath: store.path)

        XCTAssertEqual(files, ["upload-queue.json"])
    }

    func testFailedWriteKeepsPreviousStoreAndMemory() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        let before = try Data(contentsOf: queue.storeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }

        do {
            try await queue.assignDriveFileID("drive1", to: item.id)
            XCTFail("writing into a read-only directory must fail")
        } catch {
            XCTAssertEqual(error as? UploadQueueError, .writeFailed)
        }

        let inMemory = await queue.item(id: item.id)
        XCTAssertEqual(try Data(contentsOf: queue.storeURL), before)
        XCTAssertNil(inMemory?.driveFileID, "memory must not run ahead of disk")
    }

    func testCorruptStoreIsReportedNotDiscarded() throws {
        try Data("{not json".utf8).write(to: store.appending(component: UploadQueue.storeFileName))
        XCTAssertThrowsError(try makeQueue()) { XCTAssertEqual($0 as? UploadQueueError, .corruptStore) }
        XCTAssertEqual(try Data(contentsOf: store.appending(component: UploadQueue.storeFileName)), Data("{not json".utf8))
    }

    func testUnknownStoreVersionIsRefused() throws {
        try Data(#"{"version":2,"items":[]}"#.utf8).write(to: store.appending(component: UploadQueue.storeFileName))
        XCTAssertThrowsError(try makeQueue()) { XCTAssertEqual($0 as? UploadQueueError, .unsupportedStoreVersion(2)) }
    }

    // MARK: Sealed sessions

    func testSessionURIIsSealedOnDisk() async throws {
        let queue = try makeQueue(sealer: ReversingSealer())
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.setSessionURI(URL(string: Drive.session)!, for: item.id)

        let raw = String(decoding: try Data(contentsOf: queue.storeURL), as: UTF8.self)
        let opened = await queue.sessionURI(for: item.id)

        XCTAssertFalse(raw.contains("fixture-session"))
        XCTAssertEqual(opened, URL(string: Drive.session)!)
    }

    func testUnopenableSessionIsTreatedAsAbsent() async throws {
        let item = try await makeQueue().enqueue(fileAt: try writeChunk(1), now: now)
        try await makeQueue().setSessionURI(URL(string: Drive.session)!, for: item.id)
        let unsealable = try makeQueue(sealer: FailingSealer())
        let session = await unsealable.sessionURI(for: item.id)
        XCTAssertNil(session)
    }

    func testVerificationClearsTheSession() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.setSessionURI(URL(string: Drive.session)!, for: item.id)
        try await queue.markVerified(item.id, driveFileID: "drive1", at: now)
        let session = await queue.sessionURI(for: item.id)
        XCTAssertNil(session)
    }

    // MARK: Failures, backoff and quarantine

    func testFailuresBackOffExponentially() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        var delays: [TimeInterval] = []
        for _ in 0..<3 {
            let updated = try await queue.recordFailure(item.id, code: "drive-connection-failed", rejected: false, now: now)
            delays.append(try XCTUnwrap(updated.nextAttemptAt).timeIntervalSince(now))
        }
        XCTAssertEqual(delays, [30, 60, 120])
    }

    func testBackoffIsCappedAtFiveHours() {
        XCTAssertEqual(UploadBackoff.standard.delay(afterFailures: 40), 5 * 60 * 60)
    }

    func testTransientFailuresNeverQuarantine() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        var last = item
        for _ in 0..<6 {
            last = try await queue.recordFailure(item.id, code: "drive-retry-later-503", rejected: false, now: now)
        }
        XCTAssertEqual(last.state, .pending)
        XCTAssertEqual(last.attempts, 6)
        XCTAssertEqual(last.rejections, 0)
    }

    func testThirdRejectionQuarantines() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        let second = try await queue.recordFailure(item.id, code: "drive-http-400", rejected: true, now: now)
        _ = try await queue.recordFailure(item.id, code: "drive-http-400", rejected: true, now: now)
        let third = try await queue.recordFailure(item.id, code: "drive-http-400", rejected: true, now: now)
        XCTAssertEqual(second.state, .pending)
        XCTAssertEqual(third.state, .quarantined)
        XCTAssertEqual(third.lastError, "drive-http-400")
        XCTAssertNil(third.nextAttemptAt)
    }

    func testEligibleSkipsItemsStillInBackoff() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.recordFailure(item.id, code: "drive-connection-failed", rejected: false, now: now)
        let early = await queue.eligible(now: now.addingTimeInterval(29))
        let later = await queue.eligible(now: now.addingTimeInterval(30))
        let waiting = await queue.waitingForBackoff(now: now.addingTimeInterval(29))
        XCTAssertTrue(early.isEmpty)
        XCTAssertEqual(later.map(\.id), [item.id])
        XCTAssertEqual(waiting, 1)
    }

    func testManualRequestIgnoresBackoff() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.recordFailure(item.id, code: "drive-connection-failed", rejected: false, now: now)
        let eligible = await queue.eligible(now: now, ignoringBackoff: true)
        XCTAssertEqual(eligible.map(\.id), [item.id])
    }

    func testEligibleItemsAreOrderedOldestNameFirst() async throws {
        let queue = try makeQueue()
        try await queue.enqueue(fileAt: try writeChunk(3), now: now)
        try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.enqueue(fileAt: try writeChunk(2), now: now)
        let ids = await queue.eligible(now: now).map(\.id)
        XCTAssertEqual(ids, [Fixture.chunkName(1), Fixture.chunkName(2), Fixture.chunkName(3)])
    }

    func testQuarantinedItemIsNotEligible() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.quarantine(item.id, code: "changed-audio")
        let eligible = await queue.eligible(now: now, ignoringBackoff: true)
        XCTAssertTrue(eligible.isEmpty)
    }

    func testReviewedQuarantinedItemCanBeRetried() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.quarantine(item.id, code: "remote-receipt-mismatch")
        let retried = try await queue.retryQuarantined(item.id)
        XCTAssertEqual(retried.state, .pending)
        XCTAssertEqual(retried.rejections, 0)
    }

    func testRetryingARemoteReceiptProblemStartsANewRemoteCopy() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.assignDriveFileID("driveOld0001", to: item.id)
        try await queue.setSessionURI(URL(string: "https://www.googleapis.com/upload/drive/v3/files?upload_id=old"), for: item.id)
        for code in ["remote-receipt-mismatch", "remote-file-not-private"] {
            try await queue.quarantine(item.id, code: code)
            let retried = try await queue.retryQuarantined(item.id)
            XCTAssertEqual(retried.state, .pending)
            XCTAssertNil(retried.driveFileID, code)
            XCTAssertNil(retried.sealedSessionURI, code)
        }
    }

    func testRetryingOtherProblemsKeepsTheRemoteCopy() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.assignDriveFileID("driveOld0001", to: item.id)
        try await queue.recordFailure(item.id, code: "drive-http-400", rejected: true, now: now)
        try await queue.quarantine(item.id, code: "drive-http-400")
        let retried = try await queue.retryQuarantined(item.id)
        XCTAssertEqual(retried.driveFileID, "driveOld0001", "the same ID keeps a retry from creating a duplicate")
    }

    func testForgettingRemoteUploadsKeepsVerifiedReceipts() async throws {
        let queue = try makeQueue()
        let pending = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        let quarantined = try await queue.enqueue(fileAt: try writeChunk(2), now: now)
        let verified = try await queue.enqueue(fileAt: try writeChunk(3), now: now)
        let session = URL(string: "https://www.googleapis.com/upload/drive/v3/files?upload_id=s")
        for (index, id) in [pending.id, quarantined.id].enumerated() {
            try await queue.assignDriveFileID("drive000\(index)", to: id)
            try await queue.setSessionURI(session, for: id)
        }
        try await queue.quarantine(quarantined.id, code: "remote-receipt-mismatch")
        try await queue.markVerified(verified.id, driveFileID: "driveDone01", at: now)

        try await queue.forgetRemoteUploads()

        let reloaded = try makeQueue()
        for id in [pending.id, quarantined.id] {
            let stored = await reloaded.item(id: id)
            XCTAssertNil(stored?.driveFileID)
            XCTAssertNil(stored?.sealedSessionURI)
        }
        let done = await reloaded.item(id: verified.id)
        XCTAssertEqual(done?.driveFileID, "driveDone01")
        XCTAssertEqual(done?.state, .verified)
        let stillQuarantined = await reloaded.item(id: quarantined.id)?.state
        XCTAssertEqual(stillQuarantined, .quarantined)
    }

    func testForgettingOnlySessionsKeepsDriveFileIDs() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.assignDriveFileID("driveKeep01", to: item.id)
        try await queue.setSessionURI(URL(string: "https://www.googleapis.com/upload/drive/v3/files?upload_id=s"), for: item.id)

        try await queue.forgetRemoteUploads(keepingFileIDs: true)

        let stored = await queue.item(id: item.id)
        XCTAssertEqual(stored?.driveFileID, "driveKeep01")
        XCTAssertNil(stored?.sealedSessionURI)
    }

    func testVerifiedItemIgnoresLaterFailures() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.markVerified(item.id, driveFileID: "drive1", at: now)
        let afterFailure = try await queue.recordFailure(item.id, code: "x", rejected: true, now: now)
        let afterQuarantine = try await queue.quarantine(item.id, code: "x")
        XCTAssertEqual(afterFailure.state, .verified)
        XCTAssertEqual(afterQuarantine.state, .verified)
    }

    func testFirstDriveFileIDIsKept() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        try await queue.assignDriveFileID("drive1", to: item.id)
        let updated = try await queue.assignDriveFileID("drive2", to: item.id)
        XCTAssertEqual(updated.driveFileID, "drive1")
    }

    func testUnsafeDriveFileIDIsRefused() async throws {
        let queue = try makeQueue()
        let item = try await queue.enqueue(fileAt: try writeChunk(1), now: now)
        do {
            try await queue.assignDriveFileID("../x", to: item.id)
            XCTFail("unsafe IDs must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidIdentifier)
        }
    }

    func testUnknownItemIsReported() async throws {
        do {
            try await makeQueue().markUploading("nope")
            XCTFail("unknown items must be reported")
        } catch {
            XCTAssertEqual(error as? UploadQueueError, .unknownItem)
        }
    }

    func testOnlyOneRunCanClaimTheQueue() async throws {
        let queue = try makeQueue()
        let first = await queue.claimRun()
        let second = await queue.claimRun()
        await queue.releaseRun()
        let third = await queue.claimRun()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertTrue(third)
    }

    func testTraversalInStoredPathIsRefused() throws {
        XCTAssertThrowsError(try UploadQueue.resolve(relativePath: "../\(Fixture.chunkName(1))", fileName: Fixture.chunkName(1), in: captures))
        XCTAssertThrowsError(try UploadQueue.resolve(relativePath: "/etc/\(Fixture.chunkName(1))", fileName: Fixture.chunkName(1), in: captures))
        XCTAssertThrowsError(try UploadQueue.resolve(relativePath: "other.m4a", fileName: Fixture.chunkName(1), in: captures))
    }
}

/// Fictional sealer: reverses and prefixes, so plaintext never reaches the file.
struct ReversingSealer: SecretSealer {
    func seal(_ secret: String) throws -> String { "sealed:" + String(secret.reversed()) }
    func open(_ sealed: String) throws -> String {
        guard sealed.hasPrefix("sealed:") else { throw CocoaError(.coderInvalidValue) }
        return String(sealed.dropFirst("sealed:".count).reversed())
    }
}

struct FailingSealer: SecretSealer {
    func seal(_ secret: String) throws -> String { throw CocoaError(.coderInvalidValue) }
    func open(_ sealed: String) throws -> String { throw CocoaError(.coderInvalidValue) }
}
