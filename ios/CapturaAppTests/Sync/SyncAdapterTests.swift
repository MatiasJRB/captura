import CapturaCore
import Foundation
import XCTest
@testable import Captura

final class KeychainSecretSealerTests: XCTestCase {
    private var sealer: KeychainSecretSealer!
    private let sessionURI = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=fixture-session-123"

    override func setUp() {
        sealer = KeychainSecretSealer(service: "org.example.captura.tests.sealer.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? sealer.deleteKey()
    }

    func testSealedSessionOpensToTheSameURI() throws {
        let sealed = try sealer.seal(sessionURI)
        XCTAssertEqual(try sealer.open(sealed), sessionURI)
    }

    func testSealedValueDoesNotContainTheCapability() throws {
        let sealed = try sealer.seal(sessionURI)
        XCTAssertTrue(sealed.hasPrefix(KeychainSecretSealer.prefix))
        XCTAssertFalse(sealed.contains("upload_id"))
        XCTAssertFalse(sealed.contains("googleapis"))
        XCTAssertNotEqual(try sealer.seal(sessionURI), sealed, "AES-GCM uses a fresh nonce every time")
    }

    func testAnotherInstanceWithTheSameServiceSharesTheKey() throws {
        let sealed = try sealer.seal(sessionURI)
        let other = KeychainSecretSealer(service: sealer.service)
        XCTAssertEqual(try other.open(sealed), sessionURI)
    }

    func testTamperedValueCannotBeOpened() throws {
        let sealed = try sealer.seal(sessionURI)
        var bytes = try XCTUnwrap(Data(base64Encoded: String(sealed.dropFirst(KeychainSecretSealer.prefix.count))))
        // Flip one bit of the ciphertext (after the 12-byte nonce, before the 16-byte tag).
        bytes[14] ^= 0x01
        XCTAssertThrowsError(try sealer.open(KeychainSecretSealer.prefix + bytes.base64EncodedString()))
        XCTAssertThrowsError(try sealer.open(sessionURI), "plaintext is never accepted")
    }

    func testLosingTheKeyOnlyMakesOldSessionsUnreadable() throws {
        let sealed = try sealer.seal(sessionURI)
        try sealer.deleteKey()
        XCTAssertThrowsError(try sealer.open(sealed))
        let fresh = try sealer.seal(sessionURI)
        XCTAssertEqual(try sealer.open(fresh), sessionURI)
    }

    func testQueueStoresOnlySealedSessionURIs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("captura-sealer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captures = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let file = captures.appendingPathComponent("personal-capture-20261006-120000-00000000-0000-4000-8000-000000000002.m4a")
        try Data(repeating: 0x41, count: 4_096).write(to: file)
        let queue = try UploadQueue(storeDirectory: root.appendingPathComponent("Sync"), capturesRoot: captures, sealer: sealer)
        let item = try await queue.enqueue(fileAt: file)
        try await queue.setSessionURI(URL(string: sessionURI)!, for: item.id)
        let stored = try String(contentsOf: queue.storeURL, encoding: .utf8)
        XCTAssertFalse(stored.contains("upload_id"))
        let reopened = await queue.sessionURI(for: item.id)
        XCTAssertEqual(reopened?.absoluteString, sessionURI)
    }
}

final class SyncSettingsStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("captura-settings-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDeviceIDIsCreatedOnceAndSurvivesRestarts() throws {
        let first = SyncSettingsStore(directory: directory)
        XCTAssertTrue(first.isPersistent)
        XCTAssertTrue(DriveClient.isValidDeviceID(first.current.deviceID))
        XCTAssertNotNil(UUID(uuidString: first.current.deviceID))
        XCTAssertEqual(first.current.deviceID, first.current.deviceID.lowercased())
        let second = SyncSettingsStore(directory: directory)
        XCTAssertEqual(second.current.deviceID, first.current.deviceID)
    }

    func testFolderIDIsDurableBeforeSaveReturns() async throws {
        let store = SyncSettingsStore(directory: directory)
        let storage = store.folderIDStorage
        let initial = await storage.load()
        XCTAssertNil(initial)
        try await storage.save("fixtureFolder0001")
        // A new process would read the file, not the memory of this one.
        let reloaded = SyncSettingsStore(directory: directory)
        let loaded = await reloaded.folderIDStorage.load()
        XCTAssertEqual(loaded, "fixtureFolder0001")
    }

    func testPreferencesRoundTripIncludingDates() throws {
        let store = SyncSettingsStore(directory: directory)
        let requested = Date(timeIntervalSince1970: 1_791_300_000)
        try store.update {
            $0.automaticSync = true
            $0.manualRequestedAt = requested
            $0.lastMessage = "Sincronizado · originales conservados en el teléfono."
        }
        let reloaded = SyncSettingsStore(directory: directory).current
        XCTAssertTrue(reloaded.automaticSync)
        XCTAssertEqual(reloaded.manualRequestedAt, requested)
        XCTAssertEqual(reloaded.lastMessage, "Sincronizado · originales conservados en el teléfono.")
    }

    func testOnlyTheFirstLaunchIsANewInstall() throws {
        XCTAssertTrue(SyncSettingsStore(directory: directory).isNewInstall)
        XCTAssertFalse(SyncSettingsStore(directory: directory).isNewInstall)
    }

    func testUnreadableSettingsAreNotTakenForANewInstall() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(SyncSettingsStore.fileName))
        XCTAssertFalse(SyncSettingsStore(directory: directory).isNewInstall)
    }

    func testUnreadableFileIsKeptAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(SyncSettingsStore.fileName)
        try Data("not json".utf8).write(to: file)
        let store = SyncSettingsStore(directory: directory)
        XCTAssertTrue(store.isPersistent)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("sync-settings.unreadable-") })
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(aside), encoding: .utf8), "not json")
    }
}

final class NetworkConditionsMappingTests: XCTestCase {
    func testWiFiIsOnlineAndAllowsAutomaticSync() {
        XCTAssertEqual(
            NetworkMonitor.conditions(satisfied: true, wifi: true, wired: false, expensive: false, constrained: false),
            NetworkConditions(online: true, wifi: true)
        )
    }

    func testCellularIsOnlineButNotWiFi() {
        XCTAssertEqual(
            NetworkMonitor.conditions(satisfied: true, wifi: false, wired: false, expensive: true, constrained: false),
            NetworkConditions(online: true, wifi: false)
        )
    }

    func testPersonalHotspotAndLowDataModeDoNotCountAsWiFi() {
        XCTAssertFalse(NetworkMonitor.conditions(satisfied: true, wifi: true, wired: false, expensive: true, constrained: false).wifi)
        XCTAssertFalse(NetworkMonitor.conditions(satisfied: true, wifi: true, wired: false, expensive: false, constrained: true).wifi)
    }

    func testUnsatisfiedPathIsOffline() {
        XCTAssertEqual(
            NetworkMonitor.conditions(satisfied: false, wifi: true, wired: false, expensive: false, constrained: false),
            NetworkConditions(online: false, wifi: false)
        )
    }

    func testWiredEthernetCountsAsWiFi() {
        XCTAssertTrue(NetworkMonitor.conditions(satisfied: true, wifi: false, wired: true, expensive: false, constrained: false).wifi)
    }
}

final class DriveTokenSourceTests: XCTestCase {
    func testForceRefreshDropsTheCachedTokenBeforeAskingAgain() async throws {
        let provider = RecordingTokenProvider(result: .success("fixture-token"))
        let token = DriveTokenSource.make(provider)
        let first = try await token(false)
        XCTAssertEqual(first, "fixture-token")
        let second = try await token(true)
        XCTAssertEqual(second, "fixture-token")
        XCTAssertEqual(provider.calls, ["token", "invalidate", "token"])
    }

    func testRevokedGrantBecomesNeedsReauthorization() async {
        for error in [GoogleAuthError.reauthenticationRequired, .invalidGrant, .signedOut] {
            let token = DriveTokenSource.make(RecordingTokenProvider(result: .failure(error)))
            do {
                _ = try await token(false)
                XCTFail("Expected needsReauthorization for \(error)")
            } catch {
                XCTAssertEqual(error as? DriveError, .needsReauthorization)
            }
        }
    }

    func testOtherFailuresPassThroughForTheClientToClassify() async {
        let token = DriveTokenSource.make(RecordingTokenProvider(result: .failure(URLError(.notConnectedToInternet))))
        do {
            _ = try await token(false)
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    /// Invalid_grant from Google's token endpoint, end to end through the real provider.
    func testInvalidGrantFromGoogleUnlinksAndAsksForReauthorization() async throws {
        let store = InMemoryTokenStore(GoogleCredential(refreshToken: "fixture-refresh", accountEmail: AppAuthFixtures.email))
        let configuration = try GoogleOAuthConfiguration(clientID: AppAuthFixtures.clientID)
        let transport = AppAuthStubTransport([HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))])
        let provider = AccessTokenProvider(configuration: configuration, transport: transport, store: store)
        do {
            _ = try await DriveTokenSource.make(provider)(false)
            XCTFail("Expected needsReauthorization")
        } catch {
            XCTAssertEqual(error as? DriveError, .needsReauthorization)
        }
        XCTAssertNil(try store.load(), "the dead credential is removed")
    }
}

/// Logs calls in order. Fictional token only.
final class RecordingTokenProvider: GoogleAccessTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let result: Result<String, Error>

    init(result: Result<String, Error>) {
        self.result = result
    }

    var calls: [String] { lock.withLock { log } }

    func accessToken() async throws -> String {
        lock.withLock { log.append("token") }
        return try result.get()
    }

    func invalidateAccessToken() async {
        lock.withLock { log.append("invalidate") }
    }
}

/// Keychain items survive deleting the app; Application Support does not.
final class KeychainLeftoverTests: XCTestCase {
    private let service = "org.example.captura.tests.\(UUID().uuidString)"
    private var tokenStore: KeychainTokenStore!
    private var sealer: KeychainSecretSealer!

    override func setUp() {
        super.setUp()
        tokenStore = KeychainTokenStore(service: service + ".google")
        sealer = KeychainSecretSealer(service: service + ".sync")
    }

    override func tearDown() {
        try? tokenStore.delete()
        try? sealer.deleteKey()
        super.tearDown()
    }

    func testANewInstallDiscardsTheLinkAndSessionKeyOfADeletedInstall() throws {
        try tokenStore.save(GoogleCredential(refreshToken: AppAuthFixtures.refreshToken, accountEmail: AppAuthFixtures.email))
        let sealed = try sealer.seal("https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture")

        AppModel.discardKeychainLeftovers(tokenStore: tokenStore, sealer: sealer)

        XCTAssertNil(try tokenStore.load(), "the person links again explicitly")
        let reopened = KeychainSecretSealer(service: service + ".sync")
        XCTAssertThrowsError(try reopened.open(sealed), "the old session key is gone")
    }

    func testDiscardingWithNothingStoredIsHarmless() throws {
        AppModel.discardKeychainLeftovers(tokenStore: tokenStore, sealer: sealer)
        XCTAssertNil(try tokenStore.load())
    }
}
