import XCTest
@testable import CapturaCore

final class GoogleAuthorizationRequestURLTests: XCTestCase {
    private let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")!

    private func makeRequest(hostedDomain: String? = nil, loginHint: String? = nil, state: String = "fixture-state") -> GoogleAuthorizationRequest {
        GoogleAuthorizationRequest(configuration: AuthFixtures.configuration(hostedDomain: hostedDomain), loginHint: loginHint, state: state, pkce: pkce)
    }

    private func parameters(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func testURLTargetsGoogleAuthorizationEndpoint() {
        let url = makeRequest().url
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
    }

    func testURLContainsCodeFlowParameters() {
        let parameters = parameters(makeRequest().url)
        XCTAssertEqual(parameters["client_id"], AuthFixtures.clientID)
        XCTAssertEqual(parameters["redirect_uri"], AuthFixtures.redirectURI)
        XCTAssertEqual(parameters["response_type"], "code")
        XCTAssertEqual(parameters["state"], "fixture-state")
    }

    func testURLContainsS256CodeChallenge() {
        let parameters = parameters(makeRequest().url)
        XCTAssertEqual(parameters["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(parameters["code_challenge_method"], "S256")
    }

    func testURLNeverContainsTheVerifier() {
        XCTAssertFalse(makeRequest().url.absoluteString.contains(pkce.verifier))
    }

    func testScopeRequestsOpenIDEmailAndDriveFileOnly() {
        XCTAssertEqual(parameters(makeRequest().url)["scope"], "openid email https://www.googleapis.com/auth/drive.file")
    }

    func testURLHasNoClientSecretOrOfflineAccessParameter() {
        let parameters = parameters(makeRequest().url)
        XCTAssertNil(parameters["client_secret"])
        XCTAssertNil(parameters["access_type"])
    }

    func testHostedDomainAddsHDParameter() {
        XCTAssertEqual(parameters(makeRequest(hostedDomain: "equipo.test").url)["hd"], "equipo.test")
    }

    func testNoHostedDomainOmitsHDParameter() {
        XCTAssertNil(parameters(makeRequest().url)["hd"])
    }

    func testLoginHintIsSentAndSkipsAccountPrompt() {
        let parameters = parameters(makeRequest(loginHint: "ana@equipo.test").url)
        XCTAssertEqual(parameters["login_hint"], "ana@equipo.test")
        XCTAssertNil(parameters["prompt"])
    }

    func testWithoutLoginHintGoogleAsksWhichAccount() {
        let parameters = parameters(makeRequest().url)
        XCTAssertNil(parameters["login_hint"])
        XCTAssertEqual(parameters["prompt"], "select_account")
    }

    func testBlankLoginHintIsIgnored() {
        XCTAssertNil(makeRequest(loginHint: "   ").loginHint)
    }

    func testQueryValuesArePercentEncodedStrictly() {
        let query = makeRequest(loginHint: "ana+drive@equipo.test").url.query ?? ""
        XCTAssertTrue(query.contains("login_hint=ana%2Bdrive%40equipo.test"))
        XCTAssertTrue(query.contains("scope=openid%20email%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file"))
        XCTAssertTrue(query.contains("redirect_uri=com.googleusercontent.apps.123456789012-abcdefghijklmnopqrstuvwxyz012345%3A%2Foauth2redirect"))
    }

    func testParametersKeepADeterministicOrder() {
        let names = makeRequest(hostedDomain: "equipo.test").queryItems.map(\.name)
        XCTAssertEqual(names, ["client_id", "redirect_uri", "response_type", "scope", "state", "code_challenge", "code_challenge_method", "hd", "prompt"])
    }

    func testEachDefaultRequestHasFreshStateAndVerifier() {
        let configuration = AuthFixtures.configuration()
        let first = GoogleAuthorizationRequest(configuration: configuration)
        let second = GoogleAuthorizationRequest(configuration: configuration)
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.pkce.verifier, second.pkce.verifier)
        XCTAssertEqual(first.state.count, 43)
    }
}

final class GoogleAuthorizationCallbackTests: XCTestCase {
    private let request = GoogleAuthorizationRequest(configuration: AuthFixtures.configuration(), state: "fixture-state")

    private func callback(_ query: String, scheme: String = AuthFixtures.reversedClientID, path: String = ":/oauth2redirect") -> URL {
        URL(string: scheme + path + "?" + query)!
    }

    func testValidCallbackReturnsCode() throws {
        XCTAssertEqual(try request.authorizationCode(from: callback("state=fixture-state&code=4/fixture-code&scope=openid")), "4/fixture-code")
    }

    func testPercentEncodedCodeIsDecoded() throws {
        XCTAssertEqual(try request.authorizationCode(from: callback("state=fixture-state&code=4%2Ffixture-code")), "4/fixture-code")
    }

    func testSchemeComparisonIgnoresCase() throws {
        let url = callback("state=fixture-state&code=c", scheme: AuthFixtures.reversedClientID.uppercased())
        XCTAssertEqual(try request.authorizationCode(from: url), "c")
    }

    func testWrongSchemeIsRejected() {
        XCTAssertThrowsAuthError(.invalidCallback, try request.authorizationCode(from: callback("state=fixture-state&code=c", scheme: "com.googleusercontent.apps.999-other")))
    }

    func testHTTPSCallbackIsRejected() {
        let url = URL(string: "https://accounts.google.com/oauth2redirect?state=fixture-state&code=c")!
        XCTAssertThrowsAuthError(.invalidCallback, try request.authorizationCode(from: url))
    }

    func testWrongPathIsRejected() {
        XCTAssertThrowsAuthError(.invalidCallback, try request.authorizationCode(from: callback("state=fixture-state&code=c", path: ":/other")))
    }

    func testCallbackWithHostIsRejected() {
        XCTAssertThrowsAuthError(.invalidCallback, try request.authorizationCode(from: callback("state=fixture-state&code=c", path: "://attacker.test/oauth2redirect")))
    }

    func testStateMismatchIsRejected() {
        XCTAssertThrowsAuthError(.stateMismatch, try request.authorizationCode(from: callback("state=other-state&code=c")))
    }

    func testMissingStateIsRejected() {
        XCTAssertThrowsAuthError(.stateMismatch, try request.authorizationCode(from: callback("code=c")))
    }

    func testDuplicateStateIsRejected() {
        XCTAssertThrowsAuthError(.stateMismatch, try request.authorizationCode(from: callback("state=fixture-state&state=fixture-state&code=c")))
    }

    func testErrorWithForeignStateReportsStateMismatch() {
        XCTAssertThrowsAuthError(.stateMismatch, try request.authorizationCode(from: callback("state=other-state&error=access_denied")))
    }

    func testAccessDeniedMapsToAccessDenied() {
        XCTAssertThrowsAuthError(.accessDenied, try request.authorizationCode(from: callback("state=fixture-state&error=access_denied")))
    }

    func testOtherErrorKeepsGoogleErrorCode() {
        XCTAssertThrowsAuthError(
            .authorizationFailed(code: "admin_policy_enforced"),
            try request.authorizationCode(from: callback("state=fixture-state&error=admin_policy_enforced"))
        )
    }

    func testErrorWinsOverCode() {
        XCTAssertThrowsAuthError(.accessDenied, try request.authorizationCode(from: callback("state=fixture-state&error=access_denied&code=c")))
    }

    func testMissingCodeIsRejected() {
        XCTAssertThrowsAuthError(.missingAuthorizationCode, try request.authorizationCode(from: callback("state=fixture-state")))
    }

    func testEmptyCodeIsRejected() {
        XCTAssertThrowsAuthError(.missingAuthorizationCode, try request.authorizationCode(from: callback("state=fixture-state&code=")))
    }

    func testDuplicateCodeIsRejected() {
        XCTAssertThrowsAuthError(.invalidCallback, try request.authorizationCode(from: callback("state=fixture-state&code=a&code=b")))
    }
}
