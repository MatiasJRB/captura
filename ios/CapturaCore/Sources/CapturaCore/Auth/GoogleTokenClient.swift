import Foundation

/// A successful answer from Google's token endpoint.
public struct GoogleTokenResponse: Equatable, Sendable {
    public var accessToken: String
    public var expiresIn: TimeInterval
    public var refreshToken: String?
    public var idToken: String?
    /// Granted scopes; Google may grant fewer than requested (granular consent).
    public var scopes: Set<String>
    public var tokenType: String

    public init(accessToken: String, expiresIn: TimeInterval, refreshToken: String? = nil, idToken: String? = nil, scopes: Set<String> = [], tokenType: String = "Bearer") {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.scopes = scopes
        self.tokenType = tokenType
    }
}

/// Talks to Google's token and revocation endpoints as an iOS "installed app" client:
/// PKCE instead of a client secret, form-encoded bodies, JSON answers.
public struct GoogleTokenClient: Sendable {
    public let configuration: GoogleOAuthConfiguration
    public let endpoints: GoogleOAuthEndpoints
    private let transport: HTTPTransport

    public init(configuration: GoogleOAuthConfiguration, transport: HTTPTransport, endpoints: GoogleOAuthEndpoints = .google) {
        self.configuration = configuration
        self.transport = transport
        self.endpoints = endpoints
    }

    /// Redeems an authorization code. iOS clients have no client secret, so none is sent;
    /// the PKCE verifier proves this app started the flow.
    public func exchange(code: String, verifier: String) async throws -> GoogleTokenResponse {
        try await tokenRequest([
            ("code", code),
            ("client_id", configuration.clientID),
            ("redirect_uri", configuration.redirectURI),
            ("grant_type", "authorization_code"),
            ("code_verifier", verifier),
        ])
    }

    /// Gets a new access token. Throws `GoogleAuthError.invalidGrant` when the refresh
    /// token was revoked, expired or otherwise invalidated.
    public func refresh(refreshToken: String) async throws -> GoogleTokenResponse {
        try await tokenRequest([
            ("client_id", configuration.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    /// Revokes a refresh or access token. An already invalid token counts as revoked.
    public func revoke(token: String) async throws {
        let response = try await post(endpoints.revocation, form: [("token", token)])
        if (200..<300).contains(response.status) { return }
        if response.status == 400, GoogleTokenClient.errorCode(in: response.body) == "invalid_token" { return }
        throw GoogleAuthError.revocationFailed(status: response.status)
    }

    private func tokenRequest(_ form: [(String, String)]) async throws -> GoogleTokenResponse {
        let response = try await post(endpoints.token, form: form)
        guard (200..<300).contains(response.status) else {
            let error = GoogleTokenClient.errorCode(in: response.body)
            if error == "invalid_grant" { throw GoogleAuthError.invalidGrant }
            throw GoogleAuthError.tokenRequestFailed(status: response.status, error: error)
        }
        return try GoogleTokenClient.decodeTokenResponse(response.body)
    }

    private func post(_ url: URL, form: [(String, String)]) async throws -> HTTPResponse {
        // Defence in depth: endpoints are validated on creation and checked again here.
        guard GoogleOAuthEndpoints.isAllowed(url) else {
            throw GoogleAuthError.endpointNotAllowed(url.absoluteString)
        }
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: .data(Data(OAuthFormEncoding.encode(form).utf8))
        )
        return try await transport.send(request)
    }

    static func decodeTokenResponse(_ body: Data) throws -> GoogleTokenResponse {
        struct Payload: Decodable {
            let access_token: String?
            let expires_in: Double?
            let refresh_token: String?
            let id_token: String?
            let scope: String?
            let token_type: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body),
              let accessToken = payload.access_token, !accessToken.isEmpty,
              let expiresIn = payload.expires_in, expiresIn >= 0,
              payload.token_type?.lowercased() == "bearer" else {
            throw GoogleAuthError.malformedTokenResponse
        }
        let scopes = Set((payload.scope ?? "").split(separator: " ").map(String.init))
        return GoogleTokenResponse(
            accessToken: accessToken,
            expiresIn: expiresIn,
            refreshToken: payload.refresh_token.flatMap { $0.isEmpty ? nil : $0 },
            idToken: payload.id_token.flatMap { $0.isEmpty ? nil : $0 },
            scopes: scopes,
            tokenType: "Bearer"
        )
    }

    static func errorCode(in body: Data) -> String? {
        struct Payload: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Payload.self, from: body))?.error
    }
}
