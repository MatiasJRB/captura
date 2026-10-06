import CapturaCore
import CryptoKit
import Foundation
import Security
import Synchronization

/// Seals resumable-upload session URIs before the queue writes them to disk, like
/// Android's `SyncCrypto` (an AES-GCM key in the Android Keystore).
///
/// The 256-bit AES-GCM key lives in the Keychain, readable after the first unlock (so
/// background uploads work with the screen locked) and bound to this device: it is
/// never synced to iCloud Keychain nor restored onto another device. Losing the key
/// only means a stored session cannot be opened; the upload then starts a new session.
final class KeychainSecretSealer: SecretSealer {
    static let accountName = "upload-session-key"
    static let prefix = "v1:"

    let service: String
    private let cachedKey = Mutex<SymmetricKey?>(nil)

    init(service: String = KeychainSecretSealer.defaultService()) {
        self.service = service
    }

    /// `<bundle id>.sync`, e.g. `org.example.captura.sync`.
    static func defaultService(bundle: Bundle = .main) -> String {
        (bundle.bundleIdentifier ?? "org.example.captura") + ".sync"
    }

    func seal(_ secret: String) throws -> String {
        let key: SymmetricKey
        do {
            key = try existingKey() ?? createKey()
        } catch {
            // The queue stops the run as a local storage failure; the item stays pending.
            throw UploadQueueError.writeFailed
        }
        let box = try AES.GCM.seal(Data(secret.utf8), using: key)
        guard let combined = box.combined else { throw UploadQueueError.writeFailed }
        return Self.prefix + combined.base64EncodedString()
    }

    func open(_ sealed: String) throws -> String {
        guard sealed.hasPrefix(Self.prefix),
              let combined = Data(base64Encoded: String(sealed.dropFirst(Self.prefix.count))),
              let key = try existingKey()
        else { throw SealerError.cannotOpen }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(box, using: key)
            guard let text = String(data: plain, encoding: .utf8) else { throw SealerError.cannotOpen }
            return text
        } catch {
            throw SealerError.cannotOpen
        }
    }

    /// Removes the key (tests, or a deliberate reset). Stored sessions become unreadable.
    func deleteKey() throws {
        cachedKey.withLock { $0 = nil }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SealerError.keychain(status)
        }
    }

    enum SealerError: Error, Equatable {
        case cannotOpen
        case keychain(OSStatus)
    }

    // MARK: - Keychain

    private func existingKey() throws -> SymmetricKey? {
        if let key = cachedKey.withLock({ $0 }) { return key }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw SealerError.keychain(status)
        }
        let key = SymmetricKey(data: data)
        cachedKey.withLock { $0 = key }
        return key
    }

    private func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let stored = try existingKey() {
            // Another sealer instance created it first.
            return stored
        }
        guard status == errSecSuccess else { throw SealerError.keychain(status) }
        cachedKey.withLock { $0 = key }
        return key
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.accountName,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
