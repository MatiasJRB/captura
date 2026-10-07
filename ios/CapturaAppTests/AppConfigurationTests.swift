import XCTest
@testable import Captura

final class AppConfigurationTests: XCTestCase {
    func testInfoPlistDeclaresBackgroundAudioAndMicrophonePurpose() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        // Both modes are available to a free Apple ID (Background Modes capability).
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["audio", "processing"])
        let purpose = try XCTUnwrap(info["NSMicrophoneUsageDescription"] as? String)
        XCTAssertFalse(purpose.isEmpty)
    }

    func testBackgroundSyncTaskIdentifierIsPermitted() {
        XCTAssertTrue(BackgroundSyncTask.isPermitted, "Info.plist must list \(BackgroundSyncTask.identifier)")
        XCTAssertEqual(BackgroundSyncTask.identifier, (Bundle.main.bundleIdentifier ?? "") + ".drive-sync")
    }

    func testTestHostIsDetectedSoTheAppStaysInert() {
        XCTAssertTrue(AppEnvironment.isHostingTests)
    }

    func testOAuthRedirectSchemeIsRegistered() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let reversed = try XCTUnwrap(info["CapturaGoogleReversedClientID"] as? String)
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains(reversed))
    }
}
