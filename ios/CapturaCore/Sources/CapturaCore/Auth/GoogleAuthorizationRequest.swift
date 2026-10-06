import Foundation

/// One authorization attempt: the URL opened in the system browser sheet plus the secrets
/// (`state`, PKCE verifier) needed to validate the callback and redeem the code.
///
/// Create a fresh request for every attempt and keep it in memory only.
public struct GoogleAuthorizationRequest: Equatable, Sendable {
    public static let driveFileScope = "https://www.googleapis.com/auth/drive.file"
    /// `openid email` yields an ID token with the account email; `drive.file` only covers
    /// files this app creates or opens, the same scope the Android app requests.
    public static let scopes = ["openid", "email", driveFileScope]

    public let configuration: GoogleOAuthConfiguration
    public let endpoints: GoogleOAuthEndpoints
    public let state: String
    public let pkce: PKCE
    public let loginHint: String?

    public init(
        configuration: GoogleOAuthConfiguration,
        endpoints: GoogleOAuthEndpoints = .google,
        loginHint: String? = nil,
        state: String = OAuthRandom.urlSafeToken(),
        pkce: PKCE = .generate()
    ) {
        self.configuration = configuration
        self.endpoints = endpoints
        let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.loginHint = (hint?.isEmpty ?? true) ? nil : hint
        self.state = state
        self.pkce = pkce
    }

    /// Ordered query parameters of the authorization URL.
    public var queryItems: [(name: String, value: String)] {
        var items: [(name: String, value: String)] = [
            ("client_id", configuration.clientID),
            ("redirect_uri", configuration.redirectURI),
            ("response_type", "code"),
            ("scope", GoogleAuthorizationRequest.scopes.joined(separator: " ")),
            ("state", state),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", PKCE.method),
        ]
        // `hd` only optimises Google's account picker; the ID token's `hd` claim is what
        // is actually enforced after the exchange.
        if let hostedDomain = configuration.hostedDomain { items.append(("hd", hostedDomain)) }
        if let loginHint {
            items.append(("login_hint", loginHint))
        } else {
            // Always let the person pick the account instead of silently reusing a session.
            items.append(("prompt", "select_account"))
        }
        return items
    }

    public var url: URL {
        let query = OAuthFormEncoding.encode(queryItems.map { ($0.name, $0.value) })
        // The authorization endpoint is a validated https URL and the query only contains
        // unreserved characters or percent-escapes, so this always parses.
        return URL(string: endpoints.authorization.absoluteString + "?" + query)!
    }

    /// Validates the redirect Google sent back and returns the authorization code.
    ///
    /// Checks, in order: scheme and path are this app's redirect URI, `state` matches,
    /// no OAuth `error` was returned, and exactly one non-empty `code` is present.
    public func authorizationCode(from callbackURL: URL) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == configuration.callbackScheme.lowercased(),
              components.host == nil || components.host == "",
              components.path == GoogleOAuthConfiguration.redirectPath else {
            throw GoogleAuthError.invalidCallback
        }
        let items = components.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }

        let states = values("state")
        guard states.count == 1, states[0] == state else { throw GoogleAuthError.stateMismatch }

        if let error = values("error").first {
            throw error == "access_denied" ? GoogleAuthError.accessDenied : GoogleAuthError.authorizationFailed(code: error)
        }

        let codes = values("code")
        guard codes.count <= 1 else { throw GoogleAuthError.invalidCallback }
        guard let code = codes.first, !code.isEmpty else { throw GoogleAuthError.missingAuthorizationCode }
        return code
    }
}
