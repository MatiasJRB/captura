import XCTest
@testable import CapturaCore

final class DriveClientUploadTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var upload: DriveUpload!
    private let session = URL(string: Drive.session)!
    private let quarter = Int(DriveClient.chunkGranularity)

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
        upload = try makeUpload(bytes: 4_000)
    }

    override func tearDown() {
        directory = nil
        upload = nil
    }

    private func makeUpload(bytes: Int, name: String = Fixture.chunkName(1)) throws -> DriveUpload {
        let data = Fixture.bytes(bytes)
        let url = try Fixture.write(data, named: name, in: directory.url)
        return DriveUpload(fileID: "fileId1", name: name, fileURL: url, checksums: Checksums.compute(data: data))
    }

    private func run(
        _ client: DriveClient, _ upload: DriveUpload, session: URL? = nil, sessions: SessionLog = SessionLog(),
        checkpoint: @escaping @Sendable (Int64) async throws -> Void = { _ in }
    ) async throws {
        try await client.upload(
            upload, folderID: "folder", session: session,
            sessionChanged: { sessions.append($0) }, checkpoint: checkpoint
        )
    }

    private func receipt(_ upload: DriveUpload, _ change: (inout String) -> Void = { _ in }) -> String {
        var json = Drive.audioJSON(id: upload.fileID, name: upload.name, checksums: upload.checksums)
        change(&json)
        return json
    }

    // MARK: Start

    func testBeginUploadSendsAndroidMetadataAndUploadHeaders() async throws {
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])

        let returned = try await makeClient(transport).beginUpload(upload, folderID: "folder")

        XCTAssertEqual(returned, session)
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")
        XCTAssertEqual(request.headers["Content-Type"], "application/json; charset=UTF-8")
        XCTAssertEqual(request.headers["X-Upload-Content-Type"], "audio/mp4")
        XCTAssertEqual(request.headers["X-Upload-Content-Length"], "4000")
        XCTAssertEqual(request.body, .data(DriveMetadata.fileJSON(
            id: "fileId1", name: upload.name, folderID: "folder", sha256: upload.checksums.sha256
        )))
    }

    func testBeginUploadWithoutLocationFails() async {
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200)
        do {
            _ = try await makeClient(transport).beginUpload(upload, folderID: "folder")
            XCTFail("a session without Location cannot continue")
        } catch {
            XCTAssertEqual(error as? DriveError, .missingUploadSession)
        }
    }

    func testBeginUploadRefusesNonCaptureNames() async throws {
        var other = upload!
        other.name = "notes.txt"
        let transport = ScriptedTransport()
        do {
            _ = try await makeClient(transport).beginUpload(other, folderID: "folder")
            XCTFail("only capture files may be uploaded")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidFileName)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Happy path

    func testSmallFileIsUploadedInOnePut() async throws {
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 200, json: #"{"id":"fileId1"}"#)

        try await run(makeClient(transport), upload)

        let put = transport.requests[1]
        XCTAssertEqual(put.headers["Content-Range"], "bytes 0-3999/4000")
        XCTAssertEqual(put.headers["Content-Type"], "audio/mp4")
        XCTAssertEqual(put.body, .file(upload.fileURL, range: 0..<4_000))
        XCTAssertEqual(transport.remainingSteps, 0)
    }

    func testNewSessionIsReportedForSealedStorage() async throws {
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 201)
        let sessions = SessionLog()

        try await run(makeClient(transport), upload, sessions: sessions)

        XCTAssertEqual(sessions.values, [session])
    }

    func testLargeFileIsUploadedInChunksFollowingServerRanges() async throws {
        let big = try makeUpload(bytes: 2 * quarter + 1_000, name: Fixture.chunkName(2))
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 308, headers: ["Range": "bytes=0-\(quarter - 1)"])
        transport.on("PUT", Drive.session, status: 308, headers: ["Range": "bytes=0-\(2 * quarter - 1)"])
        transport.on("PUT", Drive.session, status: 200)

        try await run(makeClient(transport, chunkSize: Int64(quarter)), big)

        let puts = transport.requests.dropFirst().map { $0.headers["Content-Range"] }
        XCTAssertEqual(puts, [
            "bytes 0-\(quarter - 1)/\(big.checksums.bytes)",
            "bytes \(quarter)-\(2 * quarter - 1)/\(big.checksums.bytes)",
            "bytes \(2 * quarter)-\(2 * quarter + 999)/\(big.checksums.bytes)",
        ])
        XCTAssertEqual(transport.requests[3].body, .file(big.fileURL, range: Int64(2 * quarter)..<big.checksums.bytes))
    }

    func testPartiallyPersistedChunkIsResentFromServerRange() async throws {
        let big = try makeUpload(bytes: quarter + 500, name: Fixture.chunkName(2))
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 308, headers: ["Range": "bytes=0-99"])
        transport.on("PUT", Drive.session, status: 308, headers: ["Range": "bytes=0-\(quarter + 99)"])
        transport.on("PUT", Drive.session, status: 200)

        try await run(makeClient(transport, chunkSize: Int64(quarter)), big)

        XCTAssertEqual(transport.requests[2].headers["Content-Range"], "bytes 100-\(quarter + 99)/\(big.checksums.bytes)")
        XCTAssertEqual(transport.requests[3].headers["Content-Range"], "bytes \(quarter + 100)-\(quarter + 499)/\(big.checksums.bytes)")
    }

    func testChunkSizeIsRoundedToGoogleGranularity() {
        XCTAssertEqual(makeClient(ScriptedTransport(), chunkSize: 1).chunkSize, 256 * 1024)
        XCTAssertEqual(makeClient(ScriptedTransport(), chunkSize: 600 * 1024).chunkSize, 512 * 1024)
        XCTAssertEqual(makeClient(ScriptedTransport()).chunkSize, 1024 * 1024)
    }

    // MARK: Resume

    /// Mirrors `SyncTests.resumesFromCanonicalServerRange`.
    func testStatusQueryReportsServerRange() async throws {
        let transport = ScriptedTransport()
        transport.on("PUT", Drive.session, status: 308, headers: ["range": "bytes=0-262143"])

        let status = try await makeClient(transport).uploadStatus(session: session, totalBytes: 400_000)

        XCTAssertEqual(status, .incomplete(nextByte: 262_144))
        XCTAssertEqual(transport.requests[0].headers["Content-Range"], "bytes */400000")
        XCTAssertEqual(transport.requests[0].body, .data(Data()))
    }

    func testStatusQueryWithoutRangeMeansNothingStored() async throws {
        let transport = ScriptedTransport()
        transport.on("PUT", Drive.session, status: 308)
        let status = try await makeClient(transport).uploadStatus(session: session, totalBytes: 400_000)
        XCTAssertEqual(status, .incomplete(nextByte: 0))
    }

    /// Mirrors `SyncTests.expiredSessionCanBeRestarted`.
    func testStatusQueryReportsExpiredAndCompleteSessions() async throws {
        let transport = ScriptedTransport()
        transport.on("PUT", Drive.session, status: 404)
        transport.on("PUT", Drive.session, status: 410)
        transport.on("PUT", Drive.session, status: 201, json: "{}")
        let client = makeClient(transport)
        let first = try await client.uploadStatus(session: session, totalBytes: 400_000)
        let second = try await client.uploadStatus(session: session, totalBytes: 400_000)
        let third = try await client.uploadStatus(session: session, totalBytes: 400_000)
        XCTAssertEqual(first, .expired)
        XCTAssertEqual(second, .expired)
        XCTAssertEqual(third, .complete)
    }

    /// Mirrors `SyncTests.malformedOrOversizedResumeRangeIsRejected`.
    func testMalformedOrOversizedRangeIsRejected() async {
        for range in ["bytes=0-999999", "garbage", "bytes=5-10", "bytes=0-", "bytes=0-12a", "bytes=0-99999999999999999999"] {
            let transport = ScriptedTransport()
            transport.on("PUT", Drive.session, status: 308, headers: ["Range": range])
            do {
                _ = try await makeClient(transport).uploadStatus(session: session, totalBytes: 100)
                XCTFail("range \(range) must be refused")
            } catch {
                XCTAssertEqual(error as? DriveError, .invalidUploadRange, range)
            }
        }
    }

    func testStoredSessionResumesFromServerRange() async throws {
        let big = try makeUpload(bytes: 2 * quarter, name: Fixture.chunkName(2))
        let transport = ScriptedTransport()
        transport.on("PUT", Drive.session, status: 308, headers: ["Range": "bytes=0-\(quarter - 1)"])
        transport.on("PUT", Drive.session, status: 200)
        let sessions = SessionLog()

        try await run(makeClient(transport, chunkSize: Int64(quarter)), big, session: session, sessions: sessions)

        XCTAssertEqual(transport.requests.count, 2, "no new session, only the missing bytes")
        XCTAssertEqual(transport.requests[1].headers["Content-Range"], "bytes \(quarter)-\(2 * quarter - 1)/\(2 * quarter)")
        XCTAssertEqual(sessions.values, [])
    }

    func testStoredSessionAlreadyCompleteSendsNoBytes() async throws {
        let transport = ScriptedTransport()
        transport.on("PUT", Drive.session, status: 200)

        try await run(makeClient(transport), upload, session: session)

        XCTAssertEqual(transport.requests.count, 1)
    }

    func testExpiredStoredSessionStartsANewSession() async throws {
        let transport = ScriptedTransport()
        transport.on("PUT", Drive.session, status: 404)
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session + "-2"])
        transport.on("PUT", Drive.session + "-2", status: 200)
        let sessions = SessionLog()

        try await run(makeClient(transport), upload, session: session, sessions: sessions)

        XCTAssertEqual(sessions.values, [nil, URL(string: Drive.session + "-2")!])
        XCTAssertEqual(transport.requests[2].headers["Content-Range"], "bytes 0-3999/4000")
    }

    func testSessionExpiringDuringUploadIsRestartedOnce() async throws {
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 404)
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session + "-2"])
        transport.on("PUT", Drive.session + "-2", status: 200)
        let sessions = SessionLog()

        try await run(makeClient(transport), upload, sessions: sessions)

        XCTAssertEqual(sessions.values, [session, nil, URL(string: Drive.session + "-2")!])
    }

    func testSessionExpiringTwiceGivesUp() async {
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 404)
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session + "-2"])
        transport.on("PUT", Drive.session + "-2", status: 410)
        do {
            try await run(makeClient(transport), upload)
            XCTFail("a second expiry must be reported")
        } catch {
            XCTAssertEqual(error as? DriveError, .sessionExpired)
        }
    }

    func testChunkWithoutProgressFails() async throws {
        let big = try makeUpload(bytes: 2 * quarter, name: Fixture.chunkName(2))
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 308)
        do {
            try await run(makeClient(transport, chunkSize: Int64(quarter)), big)
            XCTFail("an upload that does not advance must stop")
        } catch {
            XCTAssertEqual(error as? DriveError, .uploadNoProgress)
        }
    }

    func testAllBytesAcceptedWithoutCompletionIsConfirmedByStatusQuery() async throws {
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 308, headers: ["Range": "bytes=0-3999"])
        transport.on("PUT", Drive.session, status: 200)

        try await run(makeClient(transport), upload)

        XCTAssertEqual(transport.requests[2].headers["Content-Range"], "bytes */4000")
    }

    func testTamperedStoredSessionIsDroppedWithoutContactingIt() async throws {
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 200)
        let sessions = SessionLog()

        try await run(makeClient(transport), upload, session: URL(string: "https://evil.example/upload?upload_id=x")!, sessions: sessions)

        XCTAssertFalse(transport.requests.contains { $0.url.host == "evil.example" })
        XCTAssertEqual(sessions.values, [nil, session])
    }

    func testCheckpointRunsBeforeEveryChunkWithConfirmedBytes() async throws {
        let big = try makeUpload(bytes: 2 * quarter + 10, name: Fixture.chunkName(2))
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        transport.on("PUT", Drive.session, status: 308, headers: ["Range": "bytes=0-\(quarter - 1)"])
        transport.on("PUT", Drive.session, status: 308, headers: ["Range": "bytes=0-\(2 * quarter - 1)"])
        transport.on("PUT", Drive.session, status: 200)
        let progress = ProgressLog()

        try await run(makeClient(transport, chunkSize: Int64(quarter)), big) { progress.append($0) }

        XCTAssertEqual(progress.values, [0, Int64(quarter), Int64(2 * quarter)])
    }

    func testThrowingCheckpointStopsBeforeSendingBytes() async {
        let transport = ScriptedTransport()
        transport.on("POST", Drive.upload, status: 200, headers: ["Location": Drive.session])
        do {
            try await run(makeClient(transport), upload) { _ in throw CancellationError() }
            XCTFail("the checkpoint must be able to stop the upload")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(transport.requests.count, 1, "no PUT after the checkpoint refused")
    }

    // MARK: Verification

    func testMatchingReceiptIsVerified() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("fileId1"), status: 200, json: receipt(upload))
        let ok = try await makeClient(transport).verifyUpload(upload, folderID: "folder")
        XCTAssertTrue(ok)
    }

    /// Mirrors `SyncTests.missingFileIsPendingNotUploaded`.
    func testMissingRemoteFileIsPendingNotUploaded() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("fileId1"), status: 404)
        let ok = try await makeClient(transport).verifyUpload(upload, folderID: "folder")
        XCTAssertFalse(ok)
    }

    func testMetadataWithoutContentIsStillPending() async throws {
        let transport = ScriptedTransport()
        let json = #"{"id":"fileId1","size":"0","parents":["folder"],"shared":false,"ownedByMe":true,"trashed":false,"properties":{"personalCaptureAudio":"1","sha256":"\#(upload.checksums.sha256)"}}"#
        transport.on("GET", Drive.file("fileId1"), status: 200, json: json)
        let ok = try await makeClient(transport).verifyUpload(upload, folderID: "folder")
        XCTAssertFalse(ok)
    }

    /// Mirrors `SyncTests.existingRemoteWithWrongChecksumIsNotSuccess`.
    func testWrongMD5IsAReceiptMismatch() async {
        await assertVerification(json: receipt(upload) { $0 = $0.replacingOccurrences(of: self.upload.checksums.md5, with: String(repeating: "0", count: 32)) }, fails: .remoteReceiptMismatch)
    }

    func testWrongSHAIsAReceiptMismatch() async {
        await assertVerification(json: receipt(upload) { $0 = $0.replacingOccurrences(of: self.upload.checksums.sha256, with: String(repeating: "0", count: 64)) }, fails: .remoteReceiptMismatch)
    }

    func testWrongSizeIsAReceiptMismatch() async {
        await assertVerification(json: receipt(upload) { $0 = $0.replacingOccurrences(of: #""size":"4000""#, with: #""size":"4001""#) }, fails: .remoteReceiptMismatch)
    }

    func testWrongParentIsAReceiptMismatch() async {
        await assertVerification(json: receipt(upload) { $0 = $0.replacingOccurrences(of: #"["folder"]"#, with: #"["other"]"#) }, fails: .remoteReceiptMismatch)
    }

    func testSharedRemoteFileIsRejected() async {
        await assertVerification(json: receipt(upload) { $0 = $0.replacingOccurrences(of: #""shared":false"#, with: #""shared":true"#) }, fails: .remoteFileNotPrivate)
    }

    func testTrashedRemoteFileIsRejected() async {
        await assertVerification(json: receipt(upload) { $0 = $0.replacingOccurrences(of: #""trashed":false"#, with: #""trashed":true"#) }, fails: .remoteFileNotPrivate)
    }

    func testNoteWithoutMatchingKindIsRejected() async throws {
        let note = try makeUpload(bytes: 3_000, name: Fixture.noteName)
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("fileId1"), status: 200, json: Drive.audioJSON(
            id: "fileId1", name: note.name, checksums: note.checksums, captureKind: "ambient_audio"
        ))
        do {
            _ = try await makeClient(transport).verifyUpload(note, folderID: "folder")
            XCTFail("a note must keep its capture kind")
        } catch {
            XCTAssertEqual(error as? DriveError, .remoteNoteKindMismatch)
        }
    }

    func testReceiptTheWorkerWouldRefuseIsNotVerified() async {
        await assertVerification(
            json: receipt(upload) { $0 = $0.replacingOccurrences(of: #""mimeType":"audio/mp4""#, with: #""mimeType":"audio/mpeg""#) },
            fails: .workerWouldReject(.invalidAudioMetadata)
        )
    }

    private func assertVerification(json: String, fails expected: DriveError, line: UInt = #line) async {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("fileId1"), status: 200, json: json)
        do {
            _ = try await makeClient(transport).verifyUpload(upload, folderID: "folder")
            XCTFail("verification should fail with \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? DriveError, expected, line: line)
        }
    }
}

final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URL?] = []
    var values: [URL?] { lock.withLock { log } }
    func append(_ url: URL?) { lock.withLock { log.append(url) } }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Int64] = []
    var values: [Int64] { lock.withLock { log } }
    func append(_ value: Int64) { lock.withLock { log.append(value) } }
}
