import CapturaCore
import Security
import XCTest
@testable import Captura

final class KeychainTokenStoreTests: XCTestCase {
    private var store: KeychainTokenStore!
    private let credential = GoogleCredential(refreshToken: "fixture-refresh-token", accountEmail: AppAuthFixtures.email)

    override func setUp() {
        super.setUp()
        // A unique service per test so runs never touch the app's real item.
        store = KeychainTokenStore(service: "org.example.captura.tests.\(UUID().uuidString).google")
    }

    override func tearDown() {
        try? store.delete()
        store = nil
        super.tearDown()
    }

    func testSaveThenLoadReturnsTheCredential() throws {
        try store.save(credential)
        XCTAssertEqual(try store.load(), credential)
    }

    func testLoadWithoutItemReturnsNil() throws {
        XCTAssertNil(try store.load())
    }

    func testSavingAgainReplacesTheCredential() throws {
        try store.save(credential)
        let replacement = GoogleCredential(refreshToken: "rotated", accountEmail: "otra@equipo.test")
        try store.save(replacement)
        XCTAssertEqual(try store.load(), replacement)
    }

    func testDeleteRemovesTheCredential() throws {
        try store.save(credential)
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testDeleteWithoutItemSucceeds() {
        XCTAssertNoThrow(try store.delete())
    }

    func testItemIsDeviceOnlyAndReadableAfterFirstUnlock() throws {
        try store.save(credential)
        let attributes = try XCTUnwrap(storedAttributes())
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual((attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false, false)
    }

    func testItemUsesGenericPasswordWithServiceAndAccount() throws {
        try store.save(credential)
        let attributes = try XCTUnwrap(storedAttributes())
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, store.service)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, KeychainTokenStore.accountName)
    }

    func testStoresWithDifferentServicesAreIsolated() throws {
        try store.save(credential)
        let other = KeychainTokenStore(service: "org.example.captura.tests.\(UUID().uuidString).google")
        XCTAssertNil(try other.load())
    }

    func testCorruptedItemIsReportedInsteadOfCrashing() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: KeychainTokenStore.accountName,
            kSecValueData as String: Data("not json".utf8),
        ]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? KeychainTokenStoreError, .corruptedItem)
        }
    }

    func testDefaultServiceIsBundleIdentifierPlusGoogle() throws {
        let bundleID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertEqual(KeychainTokenStore.defaultService(), bundleID + ".google")
    }

    private func storedAttributes() -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: KeychainTokenStore.accountName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }
}
