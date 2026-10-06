import XCTest
@testable import CapturaCore

final class GoogleOAuthConfigurationTests: XCTestCase {
    private typealias Key = GoogleOAuthConfiguration.InfoKey

    private func assertConfigurationError(
        _ expected: GoogleOAuthConfigurationError,
        clientID: String,
        reversedClientID: String? = nil,
        hostedDomain: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try GoogleOAuthConfiguration(clientID: clientID, reversedClientID: reversedClientID, hostedDomain: hostedDomain),
            file: file, line: line
        ) { error in
            XCTAssertEqual(error as? GoogleOAuthConfigurationError, expected, file: file, line: line)
        }
    }

    // MARK: Client ID

    func testValidClientIDDerivesReversedClientIDAndRedirectURI() throws {
        let configuration = try GoogleOAuthConfiguration(clientID: AuthFixtures.clientID)
        XCTAssertEqual(configuration.reversedClientID, AuthFixtures.reversedClientID)
        XCTAssertEqual(configuration.callbackScheme, AuthFixtures.reversedClientID)
        XCTAssertEqual(configuration.redirectURI, AuthFixtures.redirectURI)
    }

    func testRedirectURIUsesSingleSlashPath() throws {
        let configuration = try GoogleOAuthConfiguration(clientID: AuthFixtures.clientID)
        XCTAssertTrue(configuration.redirectURI.hasSuffix(":/oauth2redirect"))
        XCTAssertFalse(configuration.redirectURI.contains("://"))
    }

    func testSurroundingWhitespaceInClientIDIsTrimmed() throws {
        let configuration = try GoogleOAuthConfiguration(clientID: "  \(AuthFixtures.clientID)\n")
        XCTAssertEqual(configuration.clientID, AuthFixtures.clientID)
    }

    func testEmptyClientIDIsMissing() {
        assertConfigurationError(.missingClientID, clientID: "")
    }

    func testWhitespaceOnlyClientIDIsMissing() {
        assertConfigurationError(.missingClientID, clientID: "   ")
    }

    func testExampleFileClientIDIsPlaceholder() {
        assertConfigurationError(.placeholderClientID, clientID: "000000000000-example.apps.googleusercontent.com")
    }

    func testUnexpandedBuildSettingIsPlaceholder() {
        assertConfigurationError(.placeholderClientID, clientID: "$(CAPTURA_GOOGLE_IOS_CLIENT_ID)")
    }

    func testAllZeroProjectNumberIsPlaceholder() {
        assertConfigurationError(.placeholderClientID, clientID: "000000000000-abcdef.apps.googleusercontent.com")
    }

    func testClientIDWithoutGoogleSuffixIsMalformed() {
        assertConfigurationError(.malformedClientID("my-client-id"), clientID: "my-client-id")
    }

    func testClientIDWithInvalidCharactersIsMalformed() {
        let clientID = "123 456.apps.googleusercontent.com"
        assertConfigurationError(.malformedClientID(clientID), clientID: clientID)
    }

    func testBareGoogleSuffixIsMalformed() {
        assertConfigurationError(.malformedClientID(".apps.googleusercontent.com"), clientID: ".apps.googleusercontent.com")
    }

    // MARK: Reversed client ID

    func testMatchingReversedClientIDIsAccepted() throws {
        let configuration = try GoogleOAuthConfiguration(clientID: AuthFixtures.clientID, reversedClientID: AuthFixtures.reversedClientID)
        XCTAssertEqual(configuration.reversedClientID, AuthFixtures.reversedClientID)
    }

    func testReversedClientIDComparisonIgnoresCase() throws {
        let configuration = try GoogleOAuthConfiguration(clientID: AuthFixtures.clientID, reversedClientID: AuthFixtures.reversedClientID.uppercased())
        XCTAssertEqual(configuration.reversedClientID, AuthFixtures.reversedClientID)
    }

    func testBaseDefaultReversedClientIDIsReplacedByDerivedOne() throws {
        let configuration = try GoogleOAuthConfiguration(clientID: AuthFixtures.clientID, reversedClientID: "org.example.captura.oauth")
        XCTAssertEqual(configuration.reversedClientID, AuthFixtures.reversedClientID)
    }

    func testExampleFileReversedClientIDIsReplacedByDerivedOne() throws {
        let configuration = try GoogleOAuthConfiguration(
            clientID: AuthFixtures.clientID,
            reversedClientID: "com.googleusercontent.apps.000000000000-example"
        )
        XCTAssertEqual(configuration.reversedClientID, AuthFixtures.reversedClientID)
    }

    func testMismatchedReversedClientIDReportsExpectedValue() {
        assertConfigurationError(
            .reversedClientIDMismatch(expected: AuthFixtures.reversedClientID),
            clientID: AuthFixtures.clientID,
            reversedClientID: "com.googleusercontent.apps.999999999999-otherclient"
        )
    }

    // MARK: Hosted domain

    func testEmptyHostedDomainAcceptsAnyAccount() throws {
        let configuration = try GoogleOAuthConfiguration(clientID: AuthFixtures.clientID, hostedDomain: "")
        XCTAssertNil(configuration.hostedDomain)
    }

    func testHostedDomainIsTrimmedLowercasedAndLosesAtSign() throws {
        let configuration = try GoogleOAuthConfiguration(clientID: AuthFixtures.clientID, hostedDomain: "  @Equipo.Test ")
        XCTAssertEqual(configuration.hostedDomain, "equipo.test")
    }

    func testExampleHostedDomainIsPlaceholder() {
        assertConfigurationError(.placeholderHostedDomain, clientID: AuthFixtures.clientID, hostedDomain: "example.com")
    }

    func testHostedDomainWithSchemeIsMalformed() {
        assertConfigurationError(.malformedHostedDomain("https://equipo.test"), clientID: AuthFixtures.clientID, hostedDomain: "https://equipo.test")
    }

    func testHostedDomainWithoutDotIsMalformed() {
        assertConfigurationError(.malformedHostedDomain("equipo"), clientID: AuthFixtures.clientID, hostedDomain: "equipo")
    }

    func testHostedDomainWithEmailIsMalformed() {
        assertConfigurationError(.malformedHostedDomain("ana@equipo.test"), clientID: AuthFixtures.clientID, hostedDomain: "ana@equipo.test")
    }

    // MARK: Info.plist dictionaries

    func testFreshCloneBaseDefaultsReportMissingClientID() {
        // What Captura.base.xcconfig produces when no Captura.local.xcconfig exists.
        let info: [String: Any] = [Key.clientID: "", Key.reversedClientID: "org.example.captura.oauth", Key.hostedDomain: ""]
        XCTAssertEqual(GoogleOAuthConfiguration.load(infoDictionary: info), .failure(.missingClientID))
    }

    func testUneditedExampleFileReportsPlaceholder() {
        // What Captura.local.example.xcconfig produces when copied without editing.
        let info: [String: Any] = [
            Key.clientID: "000000000000-example.apps.googleusercontent.com",
            Key.reversedClientID: "com.googleusercontent.apps.000000000000-example",
            Key.hostedDomain: "",
        ]
        XCTAssertEqual(GoogleOAuthConfiguration.load(infoDictionary: info), .failure(.placeholderClientID))
    }

    func testOnlyTheClientIDIsNeededToConfigure() {
        // Pasting just the client ID into the copied example file is enough.
        let info: [String: Any] = [
            Key.clientID: AuthFixtures.clientID,
            Key.reversedClientID: "com.googleusercontent.apps.000000000000-example",
            Key.hostedDomain: "",
        ]
        let expected = try! GoogleOAuthConfiguration(clientID: AuthFixtures.clientID, reversedClientID: AuthFixtures.reversedClientID)
        XCTAssertEqual(GoogleOAuthConfiguration.load(infoDictionary: info), .success(expected))
    }

    func testFullyConfiguredDictionaryLoadsAllValues() throws {
        let info: [String: Any] = [
            Key.clientID: AuthFixtures.clientID,
            Key.reversedClientID: AuthFixtures.reversedClientID,
            Key.hostedDomain: "equipo.test",
        ]
        let configuration = try GoogleOAuthConfiguration(infoDictionary: info)
        XCTAssertEqual(configuration.clientID, AuthFixtures.clientID)
        XCTAssertEqual(configuration.reversedClientID, AuthFixtures.reversedClientID)
        XCTAssertEqual(configuration.hostedDomain, "equipo.test")
    }

    func testNilDictionaryReportsMissingClientID() {
        XCTAssertEqual(GoogleOAuthConfiguration.load(infoDictionary: nil), .failure(.missingClientID))
    }

    func testNonStringClientIDIsTreatedAsMissing() {
        XCTAssertEqual(GoogleOAuthConfiguration.load(infoDictionary: [Key.clientID: 42]), .failure(.missingClientID))
    }

    // MARK: Messages

    func testMissingClientIDMessageNamesFileAndSetting() {
        let message = GoogleOAuthConfigurationError.missingClientID.userMessage
        XCTAssertTrue(message.hasPrefix("Falta configurar Google"))
        XCTAssertTrue(message.contains("Captura.local.xcconfig"))
        XCTAssertTrue(message.contains("CAPTURA_GOOGLE_IOS_CLIENT_ID"))
    }

    func testPlaceholderClientIDMessageSaysItIsStillTheExample() {
        let message = GoogleOAuthConfigurationError.placeholderClientID.userMessage
        XCTAssertTrue(message.hasPrefix("Falta configurar Google"))
        XCTAssertTrue(message.contains("ejemplo"))
    }

    func testMismatchMessageIncludesTheExactValueToUse() {
        let message = GoogleOAuthConfigurationError.reversedClientIDMismatch(expected: AuthFixtures.reversedClientID).userMessage
        XCTAssertTrue(message.contains("CAPTURA_GOOGLE_REVERSED_CLIENT_ID"))
        XCTAssertTrue(message.hasSuffix(AuthFixtures.reversedClientID))
    }

    func testHostedDomainMessagesNameTheSetting() {
        XCTAssertTrue(GoogleOAuthConfigurationError.placeholderHostedDomain.userMessage.contains("CAPTURA_GOOGLE_HOSTED_DOMAIN"))
        XCTAssertTrue(GoogleOAuthConfigurationError.malformedHostedDomain("x").userMessage.contains("CAPTURA_GOOGLE_HOSTED_DOMAIN"))
    }
}
