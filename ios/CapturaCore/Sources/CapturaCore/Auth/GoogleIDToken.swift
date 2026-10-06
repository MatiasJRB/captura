import Foundation

/// The Google account confirmed by a sign-in.
public struct GoogleAccount: Equatable, Sendable {
    public let email: String
    /// Google Workspace domain from the ID token, if the account belongs to one.
    public let hostedDomain: String?

    public init(email: String, hostedDomain: String?) {
        self.email = email
        self.hostedDomain = hostedDomain
    }
}

/// Reads the identity claims of a Google ID token.
///
/// The signature is deliberately not verified: the token is only ever taken from the
/// body of our own HTTPS POST to `https://oauth2.googleapis.com/token`, a direct TLS
/// channel to Google, which Google documents as sufficient to trust the token. The
/// authorization code it was issued for was itself bound to this app by PKCE. Never pass
/// an ID token obtained from anywhere else (a URL, a file, another app) to this type.
public struct GoogleIDToken: Equatable, Sendable {
    public static let issuers: Set<String> = ["https://accounts.google.com", "accounts.google.com"]

    public let issuer: String?
    public let audience: String?
    public let email: String?
    public let emailVerified: Bool
    public let hostedDomain: String?

    public init(jwt: String) throws {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = OAuthBase64URL.decode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload),
              let claims = object as? [String: Any] else {
            throw GoogleAuthError.invalidIDToken
        }
        issuer = claims["iss"] as? String
        // `aud` may be a string or, per OpenID Connect, an array with one entry.
        if let single = claims["aud"] as? String {
            audience = single
        } else if let many = claims["aud"] as? [String], many.count == 1 {
            audience = many[0]
        } else {
            audience = nil
        }
        email = (claims["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch claims["email_verified"] {
        case let flag as Bool: emailVerified = flag
        case let text as String: emailVerified = text.lowercased() == "true"
        default: emailVerified = false
        }
        hostedDomain = (claims["hd"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    /// Checks issuer, audience, a verified email and, when configured, the Workspace
    /// domain. The `hd` request parameter can be edited client-side, so the claim is the
    /// only trustworthy domain check.
    public func account(for configuration: GoogleOAuthConfiguration) throws -> GoogleAccount {
        guard let issuer, GoogleIDToken.issuers.contains(issuer),
              audience == configuration.clientID else {
            throw GoogleAuthError.invalidIDToken
        }
        guard let email else { throw GoogleAuthError.missingEmail }
        guard emailVerified else { throw GoogleAuthError.unverifiedEmail }
        if let expected = configuration.hostedDomain, hostedDomain != expected {
            throw GoogleAuthError.hostedDomainMismatch(expected: expected, actual: hostedDomain)
        }
        return GoogleAccount(email: email, hostedDomain: hostedDomain)
    }
}
