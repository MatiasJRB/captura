import XCTest
@testable import CapturaCore

final class AccessTokenProviderTests: XCTestCase {
    private let storedCredential = GoogleCredential(refreshToken: AuthFixtures.refreshToken, accountEmail: AuthFixtures.email)

    private func makeProvider(
        transport: AuthStubTransport,
        store: InMemoryTokenStore = InMemoryTokenStore(),
        clock: AuthTestClock = AuthTestClock(),
        hostedDomain: String? = nil
    ) -> AccessTokenProvider {
        AccessTokenProvider(
            configuration: AuthFixtures.configuration(hostedDomain: hostedDomain),
            transport: transport,
            store: store,
            now: clock.function
        )
    }

    private func refreshResponse(_ token: String, expiresIn: Int = 3599) -> HTTPResponse {
        AuthFixtures.tokenResponse(accessToken: token, expiresIn: expiresIn, refreshToken: nil, idToken: nil)
    }

    // MARK: Sign-in

    func testCompleteSignInStoresRefreshTokenAndEmail() async throws {
        let store = InMemoryTokenStore()
        let provider = makeProvider(transport: AuthStubTransport([AuthFixtures.tokenResponse()]), store: store)
        let request = provider.makeAuthorizationRequest()
        let account = try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        XCTAssertEqual(account.email, AuthFixtures.email)
        XCTAssertEqual(try store.load(), storedCredential)
    }

    func testCompleteSignInSendsTheRequestVerifier() async throws {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse()])
        let provider = makeProvider(transport: transport)
        let request = provider.makeAuthorizationRequest()
        try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request, code: "4/xyz"), request: request)
        XCTAssertEqual(transport.requests.first?.formFields["code"], "4/xyz")
        XCTAssertEqual(transport.requests.first?.formFields["code_verifier"], request.pkce.verifier)
    }

    func testSignInAccessTokenIsUsedWithoutRefreshing() async throws {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse()])
        let provider = makeProvider(transport: transport)
        let request = provider.makeAuthorizationRequest()
        try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, AuthFixtures.accessToken)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSignInWithStateMismatchMakesNoNetworkRequest() async {
        let transport = AuthStubTransport()
        let provider = makeProvider(transport: transport)
        let request = provider.makeAuthorizationRequest()
        let forged = URL(string: "\(AuthFixtures.redirectURI)?state=forged&code=c")!
        await assertThrowsAuthError(.stateMismatch) { try await provider.completeSignIn(callbackURL: forged, request: request) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSignInWithRequestFromAnotherConfigurationIsRejected() async {
        let transport = AuthStubTransport()
        let provider = makeProvider(transport: transport)
        let foreign = GoogleAuthorizationRequest(configuration: AuthFixtures.configuration(hostedDomain: "equipo.test"))
        await assertThrowsAuthError(.invalidCallback) {
            try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: foreign), request: foreign)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSignInWithMatchingHostedDomainSucceeds() async throws {
        let idToken = AuthFixtures.idToken(AuthFixtures.claims(hostedDomain: "equipo.test"))
        let provider = makeProvider(transport: AuthStubTransport([AuthFixtures.tokenResponse(idToken: idToken)]), hostedDomain: "equipo.test")
        let request = provider.makeAuthorizationRequest()
        let account = try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        XCTAssertEqual(account, GoogleAccount(email: AuthFixtures.email, hostedDomain: "equipo.test"))
    }

    func testSignInWithOtherHostedDomainIsRejectedAndNothingIsStored() async {
        let store = InMemoryTokenStore()
        let idToken = AuthFixtures.idToken(AuthFixtures.claims(email: "ana@otro.test", hostedDomain: "otro.test"))
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(idToken: idToken), HTTPResponse(status: 200)])
        let provider = makeProvider(transport: transport, store: store, hostedDomain: "equipo.test")
        let request = provider.makeAuthorizationRequest()
        await assertThrowsAuthError(.hostedDomainMismatch(expected: "equipo.test", actual: "otro.test")) {
            try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        }
        XCTAssertNil(try store.load())
    }

    func testSigningInWithAnotherAccountRevokesThePreviousAccountsGrant() async throws {
        let store = InMemoryTokenStore(storedCredential)
        let other = AuthFixtures.idToken(AuthFixtures.claims(email: "beto@otra.test"))
        let transport = AuthStubTransport([
            AuthFixtures.tokenResponse(refreshToken: "fixture-other-refresh", idToken: other), HTTPResponse(status: 200),
        ])
        let provider = makeProvider(transport: transport, store: store)
        let request = provider.makeAuthorizationRequest(loginHint: AuthFixtures.email)

        let account = try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)

        XCTAssertEqual(account.email, "beto@otra.test")
        XCTAssertEqual(try store.load()?.refreshToken, "fixture-other-refresh")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.last?.url.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(transport.requests.last?.formFields["token"], AuthFixtures.refreshToken, "the replaced account's grant")
    }

    func testSigningInAgainWithTheSameAccountRevokesNothing() async throws {
        // Revoking the same account's previous token would end the new grant too.
        let store = InMemoryTokenStore(storedCredential)
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(refreshToken: "fixture-new-refresh")])
        let provider = makeProvider(transport: transport, store: store)
        let request = provider.makeAuthorizationRequest(loginHint: AuthFixtures.email)

        try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.load()?.refreshToken, "fixture-new-refresh")
    }

    func testFailedRevocationOfThePreviousAccountStillLinksTheNewOne() async throws {
        let store = InMemoryTokenStore(storedCredential)
        let other = AuthFixtures.idToken(AuthFixtures.claims(email: "beto@otra.test"))
        let transport = AuthStubTransport(results: [
            .success(AuthFixtures.tokenResponse(refreshToken: "fixture-other-refresh", idToken: other)),
            .failure(URLError(.notConnectedToInternet)),
        ])
        let provider = makeProvider(transport: transport, store: store)
        let request = provider.makeAuthorizationRequest()

        let account = try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)

        XCTAssertEqual(account.email, "beto@otra.test")
        XCTAssertEqual(try store.load()?.accountEmail, "beto@otra.test")
    }

    func testRejectedSignInRevokesTheFreshGrant() async {
        let idToken = AuthFixtures.idToken(AuthFixtures.claims(hostedDomain: "otro.test"))
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(idToken: idToken), HTTPResponse(status: 200)])
        let provider = makeProvider(transport: transport, hostedDomain: "equipo.test")
        let request = provider.makeAuthorizationRequest()
        _ = try? await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        XCTAssertEqual(transport.requests.last?.url.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(transport.requests.last?.formFields["token"], AuthFixtures.refreshToken)
    }

    func testRejectedSignInLeavesProviderSignedOut() async throws {
        let idToken = AuthFixtures.idToken(AuthFixtures.claims(hostedDomain: "otro.test"))
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(idToken: idToken), HTTPResponse(status: 200)])
        let provider = makeProvider(transport: transport, hostedDomain: "equipo.test")
        let request = provider.makeAuthorizationRequest()
        _ = try? await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        await assertThrowsAuthError(.signedOut) { try await provider.accessToken() }
    }

    func testSignInWithoutDriveScopeIsRejected() async {
        let store = InMemoryTokenStore()
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(scope: "openid https://www.googleapis.com/auth/userinfo.email"), HTTPResponse(status: 200)])
        let provider = makeProvider(transport: transport, store: store)
        let request = provider.makeAuthorizationRequest()
        await assertThrowsAuthError(.driveScopeNotGranted) {
            try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        }
        XCTAssertNil(try store.load())
    }

    func testSignInWithoutRefreshTokenIsRejected() async {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(refreshToken: nil), HTTPResponse(status: 200)])
        let provider = makeProvider(transport: transport)
        let request = provider.makeAuthorizationRequest()
        await assertThrowsAuthError(.missingRefreshToken) {
            try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        }
    }

    func testSignInWithoutIDTokenIsRejected() async {
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(idToken: nil), HTTPResponse(status: 200)])
        let provider = makeProvider(transport: transport)
        let request = provider.makeAuthorizationRequest()
        await assertThrowsAuthError(.invalidIDToken) {
            try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        }
    }

    func testMakeAuthorizationRequestUsesProviderConfiguration() {
        let provider = makeProvider(transport: AuthStubTransport(), hostedDomain: "equipo.test")
        let request = provider.makeAuthorizationRequest(loginHint: AuthFixtures.email)
        XCTAssertEqual(request.configuration, AuthFixtures.configuration(hostedDomain: "equipo.test"))
        XCTAssertEqual(request.loginHint, AuthFixtures.email)
    }

    // MARK: State

    func testStateIsSignedOutWithoutCredential() async throws {
        let state = try await makeProvider(transport: AuthStubTransport()).state()
        XCTAssertEqual(state, .signedOut)
    }

    func testStateReportsStoredAccountEmail() async throws {
        let provider = makeProvider(transport: AuthStubTransport(), store: InMemoryTokenStore(storedCredential))
        let state = try await provider.state()
        XCTAssertEqual(state, .signedIn(email: AuthFixtures.email))
    }

    // MARK: Access token cache and refresh

    func testAccessTokenWithoutCredentialThrowsSignedOut() async {
        let transport = AuthStubTransport()
        await assertThrowsAuthError(.signedOut) { try await makeProvider(transport: transport).accessToken() }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testFirstAccessTokenRefreshesWithStoredRefreshToken() async throws {
        let transport = AuthStubTransport([refreshResponse("fresh")])
        let provider = makeProvider(transport: transport, store: InMemoryTokenStore(storedCredential))
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "fresh")
        XCTAssertEqual(transport.requests.first?.formFields["refresh_token"], AuthFixtures.refreshToken)
        XCTAssertEqual(transport.requests.first?.formFields["grant_type"], "refresh_token")
    }

    func testAccessTokenIsCachedUntilSixtySecondsBeforeExpiry() async throws {
        let clock = AuthTestClock()
        let transport = AuthStubTransport([refreshResponse("first", expiresIn: 3600)])
        let provider = makeProvider(transport: transport, store: InMemoryTokenStore(storedCredential), clock: clock)
        _ = try await provider.accessToken()
        clock.advance(by: 3600 - 61)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "first")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testAccessTokenRefreshesWithinSixtySecondsOfExpiry() async throws {
        let clock = AuthTestClock()
        let transport = AuthStubTransport([refreshResponse("first", expiresIn: 3600), refreshResponse("second")])
        let provider = makeProvider(transport: transport, store: InMemoryTokenStore(storedCredential), clock: clock)
        _ = try await provider.accessToken()
        clock.advance(by: 3600 - 60)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "second")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testInvalidateForcesRefreshOnNextCall() async throws {
        let transport = AuthStubTransport([refreshResponse("first"), refreshResponse("second")])
        let provider = makeProvider(transport: transport, store: InMemoryTokenStore(storedCredential))
        _ = try await provider.accessToken()
        await provider.invalidateAccessToken()
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "second")
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let gate = AuthTestGate()
        let transport = AuthStubTransport { _ in
            await gate.wait()
            return AuthFixtures.tokenResponse(accessToken: "shared", refreshToken: nil, idToken: nil)
        }
        let provider = makeProvider(transport: transport, store: InMemoryTokenStore(storedCredential))
        async let first = provider.accessToken()
        async let second = provider.accessToken()
        async let third = provider.accessToken()
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        let tokens = try await [first, second, third]
        XCTAssertEqual(tokens, ["shared", "shared", "shared"])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRotatedRefreshTokenIsPersisted() async throws {
        let store = InMemoryTokenStore(storedCredential)
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(accessToken: "fresh", refreshToken: "rotated", idToken: nil)])
        _ = try await makeProvider(transport: transport, store: store).accessToken()
        XCTAssertEqual(try store.load(), GoogleCredential(refreshToken: "rotated", accountEmail: AuthFixtures.email))
    }

    // MARK: invalid_grant and transient failures

    func testInvalidGrantRequiresReauthentication() async {
        let transport = AuthStubTransport([AuthFixtures.errorResponse(error: "invalid_grant")])
        let provider = makeProvider(transport: transport, store: InMemoryTokenStore(storedCredential))
        await assertThrowsAuthError(.reauthenticationRequired) { try await provider.accessToken() }
    }

    func testInvalidGrantClearsTheStore() async {
        let store = InMemoryTokenStore(storedCredential)
        let transport = AuthStubTransport([AuthFixtures.errorResponse(error: "invalid_grant")])
        let provider = makeProvider(transport: transport, store: store)
        _ = try? await provider.accessToken()
        XCTAssertNil(try store.load())
        let state = try? await provider.state()
        XCTAssertEqual(state, .signedOut)
    }

    func testAfterInvalidGrantNoFurtherRefreshIsAttempted() async {
        let transport = AuthStubTransport([AuthFixtures.errorResponse(error: "invalid_grant")])
        let provider = makeProvider(transport: transport, store: InMemoryTokenStore(storedCredential))
        _ = try? await provider.accessToken()
        await assertThrowsAuthError(.signedOut) { try await provider.accessToken() }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testServerErrorDuringRefreshKeepsTheCredential() async {
        let store = InMemoryTokenStore(storedCredential)
        let transport = AuthStubTransport([HTTPResponse(status: 503)])
        let provider = makeProvider(transport: transport, store: store)
        await assertThrowsAuthError(.tokenRequestFailed(status: 503, error: nil)) { try await provider.accessToken() }
        XCTAssertEqual(try store.load(), storedCredential)
    }

    func testOfflineRefreshKeepsTheCredentialAndRetriesLater() async throws {
        let store = InMemoryTokenStore(storedCredential)
        let transport = AuthStubTransport(results: [.failure(URLError(.notConnectedToInternet)), .success(refreshResponse("later"))])
        let provider = makeProvider(transport: transport, store: store)
        _ = try? await provider.accessToken()
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "later")
        XCTAssertEqual(try store.load(), storedCredential)
    }

    // MARK: Sign-out

    func testSignOutRevokesRefreshTokenAndClearsStore() async throws {
        let store = InMemoryTokenStore(storedCredential)
        let transport = AuthStubTransport([HTTPResponse(status: 200)])
        let outcome = try await makeProvider(transport: transport, store: store).signOut()
        XCTAssertEqual(outcome, .revoked)
        XCTAssertNil(try store.load())
        XCTAssertEqual(transport.requests.first?.url.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(transport.requests.first?.formFields, ["token": AuthFixtures.refreshToken])
    }

    func testSignOutClearsStoreEvenWhenRevocationFails() async throws {
        let store = InMemoryTokenStore(storedCredential)
        let outcome = try await makeProvider(transport: AuthStubTransport([HTTPResponse(status: 500)]), store: store).signOut()
        XCTAssertEqual(outcome, .localOnly)
        XCTAssertNil(try store.load())
    }

    func testSignOutClearsStoreEvenWhenOffline() async throws {
        let store = InMemoryTokenStore(storedCredential)
        let transport = AuthStubTransport(results: [.failure(URLError(.notConnectedToInternet))])
        let outcome = try await makeProvider(transport: transport, store: store).signOut()
        XCTAssertEqual(outcome, .localOnly)
        XCTAssertNil(try store.load())
    }

    func testSignOutWithoutCredentialMakesNoRequest() async throws {
        let transport = AuthStubTransport()
        let outcome = try await makeProvider(transport: transport).signOut()
        XCTAssertEqual(outcome, .notLinked)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSignOutDropsTheCachedAccessToken() async throws {
        let transport = AuthStubTransport([refreshResponse("cached"), HTTPResponse(status: 200)])
        let provider = makeProvider(transport: transport, store: InMemoryTokenStore(storedCredential))
        _ = try await provider.accessToken()
        try await provider.signOut()
        await assertThrowsAuthError(.signedOut) { try await provider.accessToken() }
    }

    func testSignOutDuringRefreshDoesNotResurrectTheSession() async throws {
        let gate = AuthTestGate()
        let store = InMemoryTokenStore(storedCredential)
        let transport = AuthStubTransport { request in
            if request.url.path == "/token" {
                await gate.wait()
                return AuthFixtures.tokenResponse(accessToken: "late", refreshToken: "late-rotated", idToken: nil)
            }
            return HTTPResponse(status: 200)
        }
        let provider = makeProvider(transport: transport, store: store)
        let pending = Task { try await provider.accessToken() }
        while transport.requests.isEmpty { await Task.yield() }
        try await provider.signOut()
        await gate.open()
        await assertThrowsAuthError(.signedOut) { try await pending.value }
        XCTAssertNil(try store.load())
    }
}

final class InMemoryTokenStoreTests: XCTestCase {
    func testSaveThenLoadReturnsTheCredential() throws {
        let store = InMemoryTokenStore()
        let credential = GoogleCredential(refreshToken: "r", accountEmail: AuthFixtures.email)
        try store.save(credential)
        XCTAssertEqual(try store.load(), credential)
    }

    func testDeleteRemovesTheCredential() throws {
        let store = InMemoryTokenStore(GoogleCredential(refreshToken: "r", accountEmail: AuthFixtures.email))
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testDeleteOnEmptyStoreSucceeds() {
        XCTAssertNoThrow(try InMemoryTokenStore().delete())
    }
}

final class GoogleAuthErrorMessageTests: XCTestCase {
    private let everyError: [GoogleAuthError] = [
        .cancelled, .accessDenied, .authorizationFailed(code: "x"), .authorizationFailed(code: "admin_policy_enforced"),
        .invalidCallback, .stateMismatch, .missingAuthorizationCode, .presentationFailed, .endpointNotAllowed("https://attacker.test"),
        .invalidGrant, .tokenRequestFailed(status: 500, error: nil), .tokenRequestFailed(status: 401, error: "invalid_client"),
        .malformedTokenResponse, .missingRefreshToken, .driveScopeNotGranted, .invalidIDToken, .missingEmail, .unverifiedEmail,
        .hostedDomainMismatch(expected: "equipo.test", actual: nil), .revocationFailed(status: 500), .signedOut, .reauthenticationRequired,
    ]

    func testEveryErrorHasAMessage() {
        for error in everyError {
            XCTAssertFalse(error.userMessage.isEmpty, "\(error)")
        }
    }

    func testMessagesNeverEchoTheRejectedEndpoint() {
        XCTAssertFalse(GoogleAuthError.endpointNotAllowed("https://attacker.test").userMessage.contains("attacker"))
    }

    func testReauthenticationMessageTellsWhatToTap() {
        XCTAssertTrue(GoogleAuthError.reauthenticationRequired.userMessage.contains("Vincular Drive"))
    }

    func testSignedOutMessageMatchesAndroidWording() {
        XCTAssertEqual(GoogleAuthError.signedOut.userMessage, "Drive todavía no vinculado.")
    }

    func testHostedDomainMismatchNamesTheExpectedDomain() {
        XCTAssertTrue(GoogleAuthError.hostedDomainMismatch(expected: "equipo.test", actual: "otro.test").userMessage.contains("equipo.test"))
    }

    func testInvalidClientPointsToTheClientIDSetting() {
        XCTAssertTrue(GoogleAuthError.tokenRequestFailed(status: 401, error: "invalid_client").userMessage.contains("CAPTURA_GOOGLE_IOS_CLIENT_ID"))
    }

    func testURLErrorMessageMentionsTheConnection() {
        XCTAssertTrue(GoogleAuthError.userMessage(for: URLError(.notConnectedToInternet)).contains("conexión"))
    }

    func testConfigurationErrorMessagePassesThrough() {
        XCTAssertEqual(GoogleAuthError.userMessage(for: GoogleOAuthConfigurationError.missingClientID), GoogleOAuthConfigurationError.missingClientID.userMessage)
    }
}
