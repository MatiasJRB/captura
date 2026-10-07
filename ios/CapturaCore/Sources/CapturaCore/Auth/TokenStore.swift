import Foundation
import Synchronization

/// What survives an app restart after linking Google: the long-lived refresh token and
/// the account it belongs to. Access tokens are never persisted.
public struct GoogleCredential: Codable, Equatable, Sendable {
    public var refreshToken: String
    public var accountEmail: String
    /// The ID token's `hd` claim at sign-in (nil for accounts outside Google Workspace,
    /// and for credentials stored before it was recorded).
    public var hostedDomain: String?

    public init(refreshToken: String, accountEmail: String, hostedDomain: String? = nil) {
        self.refreshToken = refreshToken
        self.accountEmail = accountEmail
        self.hostedDomain = hostedDomain
    }

    /// Whether this build may use the credential: when a Workspace domain is configured,
    /// only a credential issued for that domain. A link made before the domain was set
    /// (or changed) must not keep working.
    public func isAllowed(by configuration: GoogleOAuthConfiguration) -> Bool {
        guard let expected = configuration.hostedDomain else { return true }
        return hostedDomain == expected
    }

    /// Google account emails compare case-insensitively.
    public static func sameAccount(_ first: String, _ second: String) -> Bool {
        first.caseInsensitiveCompare(second) == .orderedSame
    }
}

/// Secure persistence for the linked Google credential. The app uses the Keychain;
/// tests use `InMemoryTokenStore`.
public protocol TokenStore: Sendable {
    func save(_ credential: GoogleCredential) throws
    func load() throws -> GoogleCredential?
    /// Succeeds when nothing is stored.
    func delete() throws
}

/// A process-local store for tests and previews. Nothing is written to disk.
public final class InMemoryTokenStore: TokenStore {
    private let credential: Mutex<GoogleCredential?>

    public init(_ credential: GoogleCredential? = nil) {
        self.credential = Mutex(credential)
    }

    public func save(_ credential: GoogleCredential) throws {
        self.credential.withLock { $0 = credential }
    }

    public func load() throws -> GoogleCredential? {
        credential.withLock { $0 }
    }

    public func delete() throws {
        credential.withLock { $0 = nil }
    }
}
