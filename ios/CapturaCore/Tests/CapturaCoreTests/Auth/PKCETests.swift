import XCTest
@testable import CapturaCore

final class PKCETests: XCTestCase {
    // RFC 7636, Appendix B.
    private let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    func testChallengeMatchesRFC7636AppendixBVector() {
        XCTAssertEqual(PKCE.challenge(for: rfcVerifier), rfcChallenge)
    }

    func testInitFromRFCVerifierKeepsVerifierAndDerivesChallenge() throws {
        let pkce = try XCTUnwrap(PKCE(verifier: rfcVerifier))
        XCTAssertEqual(pkce.verifier, rfcVerifier)
        XCTAssertEqual(pkce.challenge, rfcChallenge)
    }

    func testMethodIsS256() {
        XCTAssertEqual(PKCE.method, "S256")
    }

    func testGeneratedVerifierHasEightySixUnreservedCharacters() {
        let pkce = PKCE.generate()
        XCTAssertEqual(pkce.verifier.count, 86)
        XCTAssertTrue(PKCE.isValidVerifier(pkce.verifier))
    }

    func testGeneratedChallengeMatchesItsVerifier() {
        let pkce = PKCE.generate()
        XCTAssertEqual(pkce.challenge, PKCE.challenge(for: pkce.verifier))
    }

    func testGeneratedVerifiersAreDifferentEachTime() {
        let verifiers = Set((0..<50).map { _ in PKCE.generate().verifier })
        XCTAssertEqual(verifiers.count, 50)
    }

    func testChallengeIsBase64URLWithoutPadding() {
        let challenge = PKCE.generate().challenge
        XCTAssertEqual(challenge.count, 43)
        XCTAssertNil(challenge.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testVerifierShorterThanFortyThreeCharactersIsRejected() {
        XCTAssertNil(PKCE(verifier: String(repeating: "a", count: 42)))
    }

    func testVerifierLongerThanOneHundredTwentyEightCharactersIsRejected() {
        XCTAssertNil(PKCE(verifier: String(repeating: "a", count: 129)))
    }

    func testBoundaryVerifierLengthsAreAccepted() {
        XCTAssertNotNil(PKCE(verifier: String(repeating: "a", count: 43)))
        XCTAssertNotNil(PKCE(verifier: String(repeating: "a", count: 128)))
    }

    func testVerifierWithReservedCharactersIsRejected() {
        let base = String(repeating: "a", count: 50)
        for character in ["+", "/", "=", " ", "%", "ñ"] {
            XCTAssertNil(PKCE(verifier: base + character), "accepted \(character)")
        }
    }

    func testVerifierWithAllUnreservedPunctuationIsAccepted() {
        XCTAssertNotNil(PKCE(verifier: String(repeating: "Az9-._~", count: 7)))
    }

    func testGenerationWithSeededGeneratorIsDeterministic() {
        var first = SeededGenerator(seed: 7)
        var second = SeededGenerator(seed: 7)
        XCTAssertEqual(PKCE.generate(using: &first), PKCE.generate(using: &second))
    }
}

final class OAuthEncodingTests: XCTestCase {
    func testBase64URLEncodingUsesURLSafeAlphabetWithoutPadding() {
        XCTAssertEqual(OAuthBase64URL.encode(Data([0xfb, 0xff, 0xfe])), "-__-")
        XCTAssertEqual(OAuthBase64URL.encode(Data("a".utf8)), "YQ")
    }

    func testBase64URLDecodingRestoresPadding() {
        XCTAssertEqual(OAuthBase64URL.decode("YQ"), Data("a".utf8))
        XCTAssertEqual(OAuthBase64URL.decode("-__-"), Data([0xfb, 0xff, 0xfe]))
    }

    func testBase64URLDecodingRejectsStandardAlphabetAndImpossibleLength() {
        XCTAssertNil(OAuthBase64URL.decode("+//+"))
        XCTAssertNil(OAuthBase64URL.decode("YQ=="))
        XCTAssertNil(OAuthBase64URL.decode("YQABC"))
    }

    func testFormEncodingEscapesEverythingButUnreservedCharacters() {
        XCTAssertEqual(OAuthFormEncoding.escape("a+b c/d:e@f&g=h~i.j_k-l"), "a%2Bb%20c%2Fd%3Ae%40f%26g%3Dh~i.j_k-l")
    }

    func testFormEncodingKeepsPairOrder() {
        XCTAssertEqual(OAuthFormEncoding.encode([("b", "2"), ("a", "1")]), "b=2&a=1")
    }

    func testFormDecodingRoundTripsEncodedPairs() throws {
        let pairs = [("code", "4/0Ab+c d"), ("empty", "")]
        let decoded = try XCTUnwrap(OAuthFormEncoding.decode(OAuthFormEncoding.encode(pairs)))
        XCTAssertEqual(decoded.map(\.0), ["code", "empty"])
        XCTAssertEqual(decoded.map(\.1), ["4/0Ab+c d", ""])
    }

    func testURLSafeTokenHasFortyThreeCharactersAndIsUnique() {
        let tokens = Set((0..<50).map { _ in OAuthRandom.urlSafeToken() })
        XCTAssertEqual(tokens.count, 50)
        XCTAssertTrue(tokens.allSatisfy { $0.count == 43 && PKCE.isValidVerifier($0) })
    }
}

/// Deterministic SplitMix64, only for reproducibility tests.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
