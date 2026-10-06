import CapturaCore
import Foundation
import Security

enum KeychainTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case corruptedItem
}

/// Keeps the Google refresh token and account email in the iOS Keychain.
///
/// One generic-password item, readable after the first unlock (so background uploads work
/// while the phone is locked), bound to this device: never synced to iCloud Keychain and
/// not restored onto another device from a backup.
struct KeychainTokenStore: TokenStore {
    static let accountName = "google-oauth"

    let service: String

    init(service: String = KeychainTokenStore.defaultService()) {
        self.service = service
    }

    /// `<bundle id>.google`, e.g. `org.example.captura.google`.
    static func defaultService(bundle: Bundle = .main) -> String {
        (bundle.bundleIdentifier ?? "org.example.captura") + ".google"
    }

    func save(_ credential: GoogleCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = baseQuery.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainTokenStoreError.unexpectedStatus(status) }
    }

    func load() throws -> GoogleCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainTokenStoreError.unexpectedStatus(status) }
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(GoogleCredential.self, from: data) else {
            throw KeychainTokenStoreError.corruptedItem
        }
        return credential
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: KeychainTokenStore.accountName,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
