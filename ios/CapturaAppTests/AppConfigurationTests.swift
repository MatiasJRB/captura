import XCTest

final class AppConfigurationTests: XCTestCase {
    func testInfoPlistDeclaresBackgroundAudioAndMicrophonePurpose() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["audio"])
        let purpose = try XCTUnwrap(info["NSMicrophoneUsageDescription"] as? String)
        XCTAssertFalse(purpose.isEmpty)
    }

    func testOAuthRedirectSchemeIsRegistered() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let reversed = try XCTUnwrap(info["CapturaGoogleReversedClientID"] as? String)
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains(reversed))
    }
}
