import XCTest
@testable import CapturaCore

final class DriveClientErrorTests: XCTestCase {
    private func generateIDError(_ transport: ScriptedTransport, client: DriveClient? = nil) async -> Error? {
        do {
            _ = try await (client ?? makeClient(transport)).generateID()
            return nil
        } catch {
            return error
        }
    }

    private func status(_ code: Int, json: String = "") async -> DriveError? {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.generate, status: code, json: json)
        return await generateIDError(transport) as? DriveError
    }

    // MARK: Authorization

    func testUnauthorizedTwiceNeedsReauthorization() async {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.generate, status: 401)
        transport.on("GET", Drive.generate, status: 401)
        let error = await generateIDError(transport)
        XCTAssertEqual(error as? DriveError, .needsReauthorization)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testUnauthorizedOnceRefreshesTheTokenAndRetries() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.generate, status: 401)
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("fresh1"))
        let tokens = TokenRecorder()
        let client = DriveClient(transport: transport, token: tokens.provider([testToken]))

        let id = try await client.generateID()

        XCTAssertEqual(id, "fresh1")
        XCTAssertEqual(tokens.forcedRefreshes, [false, true])
    }

    func testMissingDriveScopeNeedsReauthorization() async {
        let error = await status(403, json: #"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#)
        XCTAssertEqual(error, .needsReauthorization)
    }

    func testTokenProviderFailureIsTokenUnavailable() async {
        struct Offline: Error {}
        let transport = ScriptedTransport()
        let client = DriveClient(transport: transport) { _ in throw Offline() }
        let error = await generateIDError(transport, client: client)
        XCTAssertEqual(error as? DriveError, .tokenUnavailable)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTokenProviderCanReportRevokedGrant() async {
        let transport = ScriptedTransport()
        let client = DriveClient(transport: transport) { _ in throw DriveError.needsReauthorization }
        let error = await generateIDError(transport, client: client)
        XCTAssertEqual(error as? DriveError, .needsReauthorization)
    }

    func testEmptyTokenNeedsReauthorization() async {
        let transport = ScriptedTransport()
        let client = DriveClient(transport: transport) { _ in "" }
        let error = await generateIDError(transport, client: client)
        XCTAssertEqual(error as? DriveError, .needsReauthorization)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTokenWithLineBreakIsNeverSentAsHeader() async {
        let transport = ScriptedTransport()
        let client = DriveClient(transport: transport) { _ in "token\r\nX-Injected: 1" }
        let error = await generateIDError(transport, client: client)
        XCTAssertEqual(error as? DriveError, .needsReauthorization)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Retryable vs failed

    func testTooManyRequestsIsRetryable() async {
        let error = await status(429)
        XCTAssertEqual(error, .retryable(status: 429))
        XCTAssertEqual(error?.isRetryable, true)
    }

    func testServerErrorIsRetryable() async {
        let error = await status(503)
        XCTAssertEqual(error, .retryable(status: 503))
    }

    func testForbiddenRateLimitIsRetryable() async {
        let error = await status(403, json: #"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#)
        XCTAssertEqual(error, .retryable(status: 403))
    }

    func testForbiddenQuotaIsRetryable() async {
        let error = await status(403, json: #"{"error":{"status":"RATE_LIMIT_EXCEEDED"}}"#)
        XCTAssertEqual(error, .retryable(status: 403))
    }

    func testFullDriveIsRetryableAndNotTheAudiosFault() async {
        let error = await status(403, json: #"{"error":{"errors":[{"domain":"global","reason":"storageQuotaExceeded"}],"code":403}}"#)
        XCTAssertEqual(error, .storageFull)
        XCTAssertEqual(error?.isRetryable, true)
        XCTAssertEqual(error?.code, "drive-storage-full")
    }

    func testProjectDailyLimitIsRetryable() async {
        let error = await status(403, json: #"{"error":{"errors":[{"domain":"usageLimits","reason":"dailyLimitExceeded"}],"code":403}}"#)
        XCTAssertEqual(error, .retryable(status: 403))
    }

    func testOtherForbiddenIsFailed() async {
        let error = await status(403, json: #"{"error":{"errors":[{"reason":"forbidden"}]}}"#)
        XCTAssertEqual(error, .failed(status: 403))
        XCTAssertEqual(error?.isRetryable, false)
    }

    func testBadRequestIsFailed() async {
        let error = await status(400)
        XCTAssertEqual(error, .failed(status: 400))
    }

    func testTransportFailureBecomesConnectionFailedWithoutTheURL() async {
        let transport = ScriptedTransport()
        transport.on("PUT", Drive.session) { request in
            throw URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: request.url])
        }
        do {
            _ = try await makeClient(transport).uploadStatus(session: URL(string: Drive.session)!, totalBytes: 2_000)
            XCTFail("a dropped connection must fail")
        } catch {
            XCTAssertEqual(error as? DriveError, .connectionFailed)
            XCTAssertFalse(String(describing: error).contains("fixture-session"), "session URIs must not leak into errors")
            XCTAssertFalse(String(reflecting: error).contains("fixture-session"))
        }
    }

    // MARK: Responses

    func testOversizedResponseIsRejected() async {
        let error = await status(200, json: String(repeating: "x", count: DriveClient.maxResponseBytes + 1))
        XCTAssertEqual(error, .oversizedResponse)
    }

    func testGeneratedIDMustBeASafeIdentifier() async {
        let error = await status(200, json: Drive.generatedIDs("../escape"))
        XCTAssertEqual(error, .invalidResponse)
    }

    func testMetadataRefusesUnsafeIDWithoutRequest() async {
        let transport = ScriptedTransport()
        do {
            _ = try await makeClient(transport).metadata(id: "../escape")
            XCTFail("unsafe IDs must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidIdentifier)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMetadataRequestsTheWorkerFields() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("abc"), status: 404)
        let meta = try await makeClient(transport).metadata(id: "abc")
        XCTAssertNil(meta)
        XCTAssertEqual(
            transport.requests[0].url.absoluteString,
            "https://www.googleapis.com/drive/v3/files/abc?fields=id,name,mimeType,size,md5Checksum,parents,properties,shared,ownedByMe,trashed"
        )
    }

    func testCancelledTaskSendsNothing() async {
        let transport = ScriptedTransport()
        let client = makeClient(transport)
        let task = Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.generateID()
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled task must not reach the network")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
