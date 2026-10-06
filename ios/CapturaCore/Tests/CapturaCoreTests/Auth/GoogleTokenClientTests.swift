import XCTest
@testable import CapturaCore

final class GoogleTokenClientTests: XCTestCase {
    private func makeClient(_ transport: AuthStubTransport) -> GoogleTokenClient {
        GoogleTokenClient(configuration: AuthFixtures.configuration(), transport: transport)
    }

    // MARK: Code exchange

    func testExchangePostsFormToTokenEndpoint() async throws {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse()])
        _ = try await makeClient(transport).exchange(code: "4/fixture-code", verifier: "fixture-verifier")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(request.headers["Accept"], "application/json")
    }

    func testExchangeBodyCarriesCodeVerifierAndRedirect() async throws {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse()])
        _ = try await makeClient(transport).exchange(code: "4/fixture-code", verifier: "fixture-verifier")
        XCTAssertEqual(transport.requests.first?.formFields, [
            "code": "4/fixture-code",
            "client_id": AuthFixtures.clientID,
            "redirect_uri": AuthFixtures.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": "fixture-verifier",
        ])
    }

    func testExchangeNeverSendsClientSecret() async throws {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse()])
        _ = try await makeClient(transport).exchange(code: "c", verifier: "v")
        XCTAssertFalse(transport.requests.first?.bodyText.contains("client_secret") ?? true)
    }

    func testExchangeBodyEscapesReservedCharacters() async throws {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse()])
        _ = try await makeClient(transport).exchange(code: "4/a+b&c=d", verifier: "v")
        XCTAssertTrue(transport.requests.first?.bodyText.hasPrefix("code=4%2Fa%2Bb%26c%3Dd&") ?? false)
    }

    func testExchangeDecodesTokensAndGrantedScopes() async throws {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(expiresIn: 3599, idToken: "a.b.c")])
        let response = try await makeClient(transport).exchange(code: "c", verifier: "v")
        XCTAssertEqual(response.accessToken, AuthFixtures.accessToken)
        XCTAssertEqual(response.refreshToken, AuthFixtures.refreshToken)
        XCTAssertEqual(response.idToken, "a.b.c")
        XCTAssertEqual(response.expiresIn, 3599)
        XCTAssertTrue(response.scopes.contains("https://www.googleapis.com/auth/drive.file"))
    }

    // MARK: Refresh

    func testRefreshBodyCarriesRefreshTokenAndClientIDOnly() async throws {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(refreshToken: nil, idToken: nil)])
        _ = try await makeClient(transport).refresh(refreshToken: "stored-refresh")
        XCTAssertEqual(transport.requests.first?.formFields, [
            "client_id": AuthFixtures.clientID,
            "grant_type": "refresh_token",
            "refresh_token": "stored-refresh",
        ])
    }

    func testRefreshWithoutNewRefreshTokenDecodesNil() async throws {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(refreshToken: nil, idToken: nil)])
        let response = try await makeClient(transport).refresh(refreshToken: "stored-refresh")
        XCTAssertNil(response.refreshToken)
    }

    // MARK: Errors

    func testInvalidGrantMapsToInvalidGrant() async {
        let transport = AuthStubTransport([AuthFixtures.errorResponse(error: "invalid_grant", description: "Token has been expired or revoked.")])
        await assertThrowsAuthError(.invalidGrant) { try await makeClient(transport).refresh(refreshToken: "r") }
    }

    func testInvalidClientKeepsStatusAndErrorCode() async {
        let transport = AuthStubTransport([AuthFixtures.errorResponse(status: 401, error: "invalid_client")])
        await assertThrowsAuthError(.tokenRequestFailed(status: 401, error: "invalid_client")) {
            try await makeClient(transport).exchange(code: "c", verifier: "v")
        }
    }

    func testServerErrorWithoutJSONMapsToTokenRequestFailed() async {
        let transport = AuthStubTransport([HTTPResponse(status: 503, body: Data("<html>".utf8))])
        await assertThrowsAuthError(.tokenRequestFailed(status: 503, error: nil)) {
            try await makeClient(transport).refresh(refreshToken: "r")
        }
    }

    func testMissingAccessTokenIsMalformed() async {
        let body = try! JSONSerialization.data(withJSONObject: ["expires_in": 3599, "token_type": "Bearer"])
        let transport = AuthStubTransport([HTTPResponse(status: 200, body: body)])
        await assertThrowsAuthError(.malformedTokenResponse) { try await makeClient(transport).refresh(refreshToken: "r") }
    }

    func testMissingExpiryIsMalformed() async {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(expiresIn: nil)])
        await assertThrowsAuthError(.malformedTokenResponse) { try await makeClient(transport).refresh(refreshToken: "r") }
    }

    func testNonBearerTokenTypeIsMalformed() async {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(tokenType: "MAC")])
        await assertThrowsAuthError(.malformedTokenResponse) { try await makeClient(transport).refresh(refreshToken: "r") }
    }

    func testNonJSONSuccessBodyIsMalformed() async {
        let transport = AuthStubTransport([HTTPResponse(status: 200, body: Data("ok".utf8))])
        await assertThrowsAuthError(.malformedTokenResponse) { try await makeClient(transport).refresh(refreshToken: "r") }
    }

    func testTransportErrorPropagatesUnchanged() async {
        let transport = AuthStubTransport(results: [.failure(URLError(.notConnectedToInternet))])
        do {
            _ = try await makeClient(transport).refresh(refreshToken: "r")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // MARK: Revocation

    func testRevokePostsTokenFormToRevocationEndpoint() async throws {
        let transport = AuthStubTransport([HTTPResponse(status: 200)])
        try await makeClient(transport).revoke(token: "stored-refresh")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(request.formFields, ["token": "stored-refresh"])
    }

    func testRevokeTreatsInvalidTokenAsAlreadyRevoked() async throws {
        let transport = AuthStubTransport([AuthFixtures.errorResponse(error: "invalid_token")])
        try await makeClient(transport).revoke(token: "stale")
    }

    // MARK: Bodies Google actually returned (2026-10-06, fictional client ID, no credentials)

    func testGoogleUnknownClientAnswerTellsWhichSettingToFix() async {
        let body = Data("{\n  \"error\": \"invalid_client\",\n  \"error_description\": \"The OAuth client was not found.\"\n}".utf8)
        let transport = AuthStubTransport([HTTPResponse(status: 401, headers: ["Content-Type": "application/json; charset=utf-8"], body: body)])
        do {
            _ = try await makeClient(transport).exchange(code: "4/fixture-code", verifier: "v")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .tokenRequestFailed(status: 401, error: "invalid_client"))
            XCTAssertTrue(GoogleAuthError.userMessage(for: error).contains("CAPTURA_GOOGLE_IOS_CLIENT_ID"))
        }
    }

    func testGoogleAnswerForAlreadyDeadTokenCountsAsRevoked() async throws {
        let body = Data("{\n  \"error\": \"invalid_token\"\n}".utf8)
        let transport = AuthStubTransport([HTTPResponse(status: 400, body: body)])
        try await makeClient(transport).revoke(token: "fixture-refresh-token")
    }

    func testRevokeFailureThrowsRevocationFailed() async {
        let transport = AuthStubTransport([HTTPResponse(status: 500)])
        await assertThrowsAuthError(.revocationFailed(status: 500)) { try await makeClient(transport).revoke(token: "t") }
    }
}

final class GoogleOAuthEndpointsTests: XCTestCase {
    private let google = GoogleOAuthEndpoints.google

    func testDefaultEndpointsAreGoogleDocumentedURLs() {
        XCTAssertEqual(google.authorization.absoluteString, "https://accounts.google.com/o/oauth2/v2/auth")
        XCTAssertEqual(google.token.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(google.revocation.absoluteString, "https://oauth2.googleapis.com/revoke")
    }

    func testDefaultEndpointsPassTheAllowlist() {
        XCTAssertTrue([google.authorization, google.token, google.revocation].allSatisfy(GoogleOAuthEndpoints.isAllowed))
    }

    func testPlainHTTPIsRejected() {
        XCTAssertFalse(GoogleOAuthEndpoints.isAllowed(URL(string: "http://oauth2.googleapis.com/token")!))
    }

    func testOtherHostIsRejected() {
        XCTAssertFalse(GoogleOAuthEndpoints.isAllowed(URL(string: "https://www.googleapis.com/oauth2/v4/token")!))
    }

    func testLookalikeHostIsRejected() {
        XCTAssertFalse(GoogleOAuthEndpoints.isAllowed(URL(string: "https://oauth2.googleapis.com.attacker.test/token")!))
    }

    func testUserInfoInURLIsRejected() {
        XCTAssertFalse(GoogleOAuthEndpoints.isAllowed(URL(string: "https://user@oauth2.googleapis.com/token")!))
    }

    func testCustomPortIsRejected() {
        XCTAssertFalse(GoogleOAuthEndpoints.isAllowed(URL(string: "https://oauth2.googleapis.com:8443/token")!))
    }

    func testHostComparisonIgnoresCase() {
        XCTAssertTrue(GoogleOAuthEndpoints.isAllowed(URL(string: "https://OAuth2.GoogleAPIs.com/token")!))
    }

    func testInitWithDisallowedTokenEndpointThrows() {
        XCTAssertThrowsAuthError(
            .endpointNotAllowed("https://attacker.test/token"),
            try GoogleOAuthEndpoints(authorization: google.authorization, token: URL(string: "https://attacker.test/token")!, revocation: google.revocation)
        )
    }

    func testInitWithAllowedEndpointsSucceeds() throws {
        let endpoints = try GoogleOAuthEndpoints(authorization: google.authorization, token: google.token, revocation: google.revocation)
        XCTAssertEqual(endpoints, google)
    }
}
