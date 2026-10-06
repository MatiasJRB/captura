import XCTest
@testable import CapturaCore

final class GoogleIDTokenTests: XCTestCase {
    private func account(_ claims: [String: Any], hostedDomain: String? = nil) throws -> GoogleAccount {
        try GoogleIDToken(jwt: AuthFixtures.idToken(claims)).account(for: AuthFixtures.configuration(hostedDomain: hostedDomain))
    }

    func testValidTokenYieldsAccountEmail() throws {
        XCTAssertEqual(try account(AuthFixtures.claims()), GoogleAccount(email: AuthFixtures.email, hostedDomain: nil))
    }

    func testIssuerWithoutSchemeIsAccepted() throws {
        XCTAssertEqual(try account(AuthFixtures.claims(issuer: "accounts.google.com")).email, AuthFixtures.email)
    }

    func testForeignIssuerIsRejected() {
        XCTAssertThrowsAuthError(.invalidIDToken, try account(AuthFixtures.claims(issuer: "https://attacker.test")))
    }

    func testForeignAudienceIsRejected() {
        XCTAssertThrowsAuthError(.invalidIDToken, try account(AuthFixtures.claims(audience: "999-other.apps.googleusercontent.com")))
    }

    func testSingleEntryAudienceArrayIsAccepted() throws {
        XCTAssertEqual(try account(AuthFixtures.claims(audience: [AuthFixtures.clientID])).email, AuthFixtures.email)
    }

    func testMissingEmailIsRejected() {
        XCTAssertThrowsAuthError(.missingEmail, try account(AuthFixtures.claims(email: nil)))
    }

    func testUnverifiedEmailIsRejected() {
        XCTAssertThrowsAuthError(.unverifiedEmail, try account(AuthFixtures.claims(emailVerified: false)))
    }

    func testStringEmailVerifiedFlagIsAccepted() throws {
        XCTAssertEqual(try account(AuthFixtures.claims(emailVerified: "true")).email, AuthFixtures.email)
    }

    func testMatchingHostedDomainIsAcceptedIgnoringCase() throws {
        let result = try account(AuthFixtures.claims(hostedDomain: "Equipo.Test"), hostedDomain: "equipo.test")
        XCTAssertEqual(result.hostedDomain, "equipo.test")
    }

    func testDifferentHostedDomainIsRejected() {
        XCTAssertThrowsAuthError(
            .hostedDomainMismatch(expected: "equipo.test", actual: "otro.test"),
            try account(AuthFixtures.claims(email: "ana@otro.test", hostedDomain: "otro.test"), hostedDomain: "equipo.test")
        )
    }

    func testPersonalAccountIsRejectedWhenDomainIsConfigured() {
        // Consumer accounts carry no `hd` claim.
        XCTAssertThrowsAuthError(
            .hostedDomainMismatch(expected: "equipo.test", actual: nil),
            try account(AuthFixtures.claims(email: "ana@gmail.test"), hostedDomain: "equipo.test")
        )
    }

    func testHostedDomainClaimIsIgnoredWhenNoDomainIsConfigured() throws {
        XCTAssertEqual(try account(AuthFixtures.claims(hostedDomain: "otro.test")).email, AuthFixtures.email)
    }

    func testTokenWithTwoSegmentsIsRejected() {
        XCTAssertThrowsAuthError(.invalidIDToken, try GoogleIDToken(jwt: "a.b"))
    }

    func testPayloadThatIsNotBase64URLIsRejected() {
        XCTAssertThrowsAuthError(.invalidIDToken, try GoogleIDToken(jwt: "a.***.c"))
    }

    func testPayloadThatIsNotAJSONObjectIsRejected() {
        let payload = OAuthBase64URL.encode(Data("[1,2]".utf8))
        XCTAssertThrowsAuthError(.invalidIDToken, try GoogleIDToken(jwt: "a.\(payload).c"))
    }
}
