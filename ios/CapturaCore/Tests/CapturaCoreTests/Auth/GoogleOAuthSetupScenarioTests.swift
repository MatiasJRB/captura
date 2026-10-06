import Foundation
import XCTest
@testable import CapturaCore

/// Walks through the setup a new person follows, using the repository's real
/// `Captura.base.xcconfig`, `Captura.local.example.xcconfig` and `Info.plist`, and
/// expanding build settings the way Xcode does. If those files drift away from what the
/// auth code expects, these tests fail.
final class GoogleOAuthSetupScenarioTests: XCTestCase {
    private typealias Setting = GoogleOAuthConfiguration.BuildSetting

    private static let iosDirectory: URL = {
        // .../ios/CapturaCore/Tests/CapturaCoreTests/Auth/<this file>
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    private func xcconfig(_ name: String) throws -> [String: String] {
        let text = try String(contentsOf: Self.iosDirectory.appendingPathComponent("Config/\(name)"), encoding: .utf8)
        var settings: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            // In xcconfig files `//` starts a comment anywhere on the line.
            let line = rawLine.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            settings[key] = value
        }
        return settings
    }

    /// Build settings after `Captura.base.xcconfig` includes the local file (if any).
    private func buildSettings(local: [String: String]?) throws -> [String: String] {
        let base = try xcconfig("Captura.base.xcconfig")
        return base.merging(local ?? [:]) { _, local in local }
    }

    /// The Info.plist dictionary the build would produce for these settings.
    private func infoDictionary(_ settings: [String: String]) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.iosDirectory.appendingPathComponent("Support/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return plist.mapValues { value in
            guard var text = value as? String else { return value }
            for (key, setting) in settings {
                text = text.replacingOccurrences(of: "$(\(key))", with: setting)
            }
            return text
        }
    }

    private func exampleFileCopy(editing edits: [String: String] = [:]) throws -> [String: String] {
        try xcconfig("Captura.local.example.xcconfig").merging(edits) { _, edit in edit }
    }

    // MARK: Files agree with the code

    func testInfoPlistMapsTheThreeGoogleBuildSettings() throws {
        let data = try Data(contentsOf: Self.iosDirectory.appendingPathComponent("Support/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist[GoogleOAuthConfiguration.InfoKey.clientID] as? String, "$(\(Setting.clientID))")
        XCTAssertEqual(plist[GoogleOAuthConfiguration.InfoKey.reversedClientID] as? String, "$(\(Setting.reversedClientID))")
        XCTAssertEqual(plist[GoogleOAuthConfiguration.InfoKey.hostedDomain] as? String, "$(\(Setting.hostedDomain))")
    }

    func testExampleFileDeclaresEveryGoogleSetting() throws {
        let example = try xcconfig("Captura.local.example.xcconfig")
        XCTAssertNotNil(example[Setting.clientID])
        XCTAssertNotNil(example[Setting.reversedClientID])
        XCTAssertNotNil(example[Setting.hostedDomain])
    }

    // MARK: Step by step

    func testFreshCloneSaysWhichFileToCreate() throws {
        let info = try infoDictionary(try buildSettings(local: nil))
        let result = GoogleOAuthConfiguration.load(infoDictionary: info)
        XCTAssertEqual(result, .failure(.missingClientID))
        if case .failure(let error) = result {
            XCTAssertTrue(error.userMessage.contains("Captura.local.example.xcconfig"))
        }
    }

    func testCopiedButUneditedExampleSaysTheValueIsStillTheExample() throws {
        let info = try infoDictionary(try buildSettings(local: try exampleFileCopy()))
        XCTAssertEqual(GoogleOAuthConfiguration.load(infoDictionary: info), .failure(.placeholderClientID))
    }

    func testPastingOnlyTheClientIDIsEnough() throws {
        let local = try exampleFileCopy(editing: [Setting.clientID: AuthFixtures.clientID])
        let configuration = try GoogleOAuthConfiguration(infoDictionary: try infoDictionary(try buildSettings(local: local)))
        XCTAssertEqual(configuration.callbackScheme, AuthFixtures.reversedClientID)
        XCTAssertEqual(configuration.redirectURI, AuthFixtures.redirectURI)
        XCTAssertNil(configuration.hostedDomain)
    }

    func testPastingClientIDAndIOSURLSchemeFromGoogleConsoleWorks() throws {
        let local = try exampleFileCopy(editing: [
            Setting.clientID: AuthFixtures.clientID,
            Setting.reversedClientID: AuthFixtures.reversedClientID,
        ])
        let configuration = try GoogleOAuthConfiguration(infoDictionary: try infoDictionary(try buildSettings(local: local)))
        XCTAssertEqual(configuration.callbackScheme, AuthFixtures.reversedClientID)
    }

    func testRestrictingToAWorkspaceDomainSendsHDAndChecksTheClaim() throws {
        let local = try exampleFileCopy(editing: [Setting.clientID: AuthFixtures.clientID, Setting.hostedDomain: "equipo.test"])
        let configuration = try GoogleOAuthConfiguration(infoDictionary: try infoDictionary(try buildSettings(local: local)))
        XCTAssertEqual(configuration.hostedDomain, "equipo.test")
        let url = GoogleAuthorizationRequest(configuration: configuration).url.absoluteString
        XCTAssertTrue(url.contains("hd=equipo.test"))
    }

    func testURLSchemeFromAnotherClientNamesTheExactValueToUse() throws {
        let local = try exampleFileCopy(editing: [
            Setting.clientID: AuthFixtures.clientID,
            Setting.reversedClientID: "com.googleusercontent.apps.999999999999-otherclient",
        ])
        let result = GoogleOAuthConfiguration.load(infoDictionary: try infoDictionary(try buildSettings(local: local)))
        XCTAssertEqual(result, .failure(.reversedClientIDMismatch(expected: AuthFixtures.reversedClientID)))
    }

    func testCompleteFirstLinkWorksWithTheConfiguredValues() async throws {
        // From pasted client ID to a stored credential, with Google replaced by stubs.
        let local = try exampleFileCopy(editing: [Setting.clientID: AuthFixtures.clientID])
        let configuration = try GoogleOAuthConfiguration(infoDictionary: try infoDictionary(try buildSettings(local: local)))
        let store = InMemoryTokenStore()
        let transport = AuthStubTransport([AuthFixtures.tokenResponse(), AuthFixtures.tokenResponse(accessToken: "next", refreshToken: nil, idToken: nil)])
        let clock = AuthTestClock()
        let provider = AccessTokenProvider(configuration: configuration, transport: transport, store: store, now: clock.function)

        let request = provider.makeAuthorizationRequest()
        let account = try await provider.completeSignIn(callbackURL: AuthFixtures.callbackURL(for: request), request: request)
        clock.advance(by: 3600)
        let laterToken = try await provider.accessToken()

        XCTAssertEqual(account.email, AuthFixtures.email)
        XCTAssertEqual(try store.load()?.accountEmail, AuthFixtures.email)
        XCTAssertEqual(laterToken, "next")
    }
}
