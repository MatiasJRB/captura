import Foundation

/// Google's OAuth 2.0 endpoints for installed apps, restricted to an allowlist so that a
/// refresh token or authorization code can never be sent anywhere else.
public struct GoogleOAuthEndpoints: Equatable, Sendable {
    /// The only hosts that may receive OAuth parameters or tokens.
    public static let allowedHosts: Set<String> = ["accounts.google.com", "oauth2.googleapis.com"]

    public static let google = GoogleOAuthEndpoints(
        uncheckedAuthorization: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        token: URL(string: "https://oauth2.googleapis.com/token")!,
        revocation: URL(string: "https://oauth2.googleapis.com/revoke")!
    )

    public let authorization: URL
    public let token: URL
    public let revocation: URL

    /// Fails with `GoogleAuthError.endpointNotAllowed` unless every URL is an
    /// `https://` URL on an allowed host, without credentials or a custom port.
    public init(authorization: URL, token: URL, revocation: URL) throws {
        for url in [authorization, token, revocation] where !GoogleOAuthEndpoints.isAllowed(url) {
            throw GoogleAuthError.endpointNotAllowed(url.absoluteString)
        }
        self.init(uncheckedAuthorization: authorization, token: token, revocation: revocation)
    }

    private init(uncheckedAuthorization authorization: URL, token: URL, revocation: URL) {
        self.authorization = authorization
        self.token = token
        self.revocation = revocation
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              allowedHosts.contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return false }
        return true
    }
}
