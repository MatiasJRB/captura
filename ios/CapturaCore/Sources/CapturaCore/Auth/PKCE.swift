import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) with the S256 method.
///
/// Google requires PKCE for installed apps; it replaces the client secret that an iOS
/// client does not have. The verifier never leaves the device until the token exchange.
public struct PKCE: Equatable, Sendable {
    public static let method = "S256"
    public static let allowedVerifierLengths = 43...128
    /// 64 random bytes encode to 86 Base64URL characters, well inside the allowed range.
    static let generatedByteCount = 64

    public let verifier: String
    public let challenge: String

    /// Returns `nil` unless the verifier has 43–128 characters from the unreserved set
    /// `[A-Z] [a-z] [0-9] - . _ ~`.
    public init?(verifier: String) {
        guard PKCE.isValidVerifier(verifier) else { return nil }
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    public static func generate() -> PKCE {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    public static func generate<Generator: RandomNumberGenerator>(using generator: inout Generator) -> PKCE {
        let bytes = OAuthRandom.bytes(count: generatedByteCount, using: &generator)
        let verifier = OAuthBase64URL.encode(Data(bytes))
        // Base64URL output only contains unreserved characters, so this cannot fail.
        return PKCE(verifier: verifier)!
    }

    /// `BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))`, without padding.
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return OAuthBase64URL.encode(Data(digest))
    }

    public static func isValidVerifier(_ verifier: String) -> Bool {
        guard allowedVerifierLengths.contains(verifier.utf8.count) else { return false }
        return verifier.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", ".", "_", "~": return true
            default: return false
            }
        }
    }
}
