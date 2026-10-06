import Foundation

/// Whether a Google account is linked on this device.
public enum GoogleAuthState: Equatable, Sendable {
    case signedOut
    case signedIn(email: String)
}

/// Result of unlinking. The local credential is always removed first.
public enum GoogleSignOutOutcome: Equatable, Sendable {
    /// Google confirmed the grant was revoked (or it was already invalid).
    case revoked
    /// Unlinked on this device, but Google could not be reached or refused the revocation.
    case localOnly
    /// Nothing was linked.
    case notLinked
}

/// What a Drive client needs: a valid bearer token, and a way to drop it after a 401.
public protocol GoogleAccessTokenProviding: Sendable {
    func accessToken() async throws -> String
    func invalidateAccessToken() async
}

/// Owns the linked Google session: completes sign-in, caches the short-lived access token,
/// refreshes it with the stored refresh token and signs out.
///
/// Concurrent callers share one in-flight refresh. When Google answers `invalid_grant`
/// (revoked access, expired grant, Testing-mode consent screens after 7 days, ...), the
/// stored credential is deleted and `GoogleAuthError.reauthenticationRequired` is thrown,
/// so the app shows "Vincular Drive" again instead of retrying forever.
public actor AccessTokenProvider: GoogleAccessTokenProviding {
    /// Access tokens are refreshed this long before Google says they expire.
    public static let refreshMargin: TimeInterval = 60

    public nonisolated let configuration: GoogleOAuthConfiguration
    public nonisolated let endpoints: GoogleOAuthEndpoints
    private let tokenClient: GoogleTokenClient
    private let store: TokenStore
    private let now: @Sendable () -> Date

    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    private var cached: CachedToken?
    private var refreshTask: Task<String, Error>?
    /// Bumped on every sign-in and sign-out so stale refreshes cannot overwrite state.
    private var generation = 0

    public init(
        configuration: GoogleOAuthConfiguration,
        transport: HTTPTransport,
        store: TokenStore,
        endpoints: GoogleOAuthEndpoints = .google,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.endpoints = endpoints
        self.tokenClient = GoogleTokenClient(configuration: configuration, transport: transport, endpoints: endpoints)
        self.store = store
        self.now = now
    }

    /// A fresh authorization attempt to open in the system sign-in sheet.
    public nonisolated func makeAuthorizationRequest(loginHint: String? = nil) -> GoogleAuthorizationRequest {
        GoogleAuthorizationRequest(configuration: configuration, endpoints: endpoints, loginHint: loginHint)
    }

    public func state() throws -> GoogleAuthState {
        guard let credential = try store.load() else { return .signedOut }
        return .signedIn(email: credential.accountEmail)
    }

    /// Validates Google's redirect, redeems the code and stores the credential.
    ///
    /// The account is rejected (and the fresh grant revoked best-effort) when Drive access
    /// was not granted, the email is not verified or the Workspace domain does not match.
    ///
    /// `login_hint` is only a hint: the person may pick another account in Google's
    /// sheet. When that replaces a stored account, the replaced account's grant is
    /// revoked best-effort, because once its refresh token is overwritten this device
    /// could never revoke it again. The same account's previous token is not revoked:
    /// that would end the new grant too.
    @discardableResult
    public func completeSignIn(callbackURL: URL, request: GoogleAuthorizationRequest) async throws -> GoogleAccount {
        guard request.configuration == configuration, request.endpoints == endpoints else {
            throw GoogleAuthError.invalidCallback
        }
        let code = try request.authorizationCode(from: callbackURL)
        let previous = try? store.load()
        let response = try await tokenClient.exchange(code: code, verifier: request.pkce.verifier)
        let account: GoogleAccount
        do {
            guard response.scopes.contains(GoogleAuthorizationRequest.driveFileScope) else {
                throw GoogleAuthError.driveScopeNotGranted
            }
            guard let idToken = response.idToken else { throw GoogleAuthError.invalidIDToken }
            account = try GoogleIDToken(jwt: idToken).account(for: configuration)
            guard let refreshToken = response.refreshToken else { throw GoogleAuthError.missingRefreshToken }
            try store.save(GoogleCredential(refreshToken: refreshToken, accountEmail: account.email))
        } catch {
            // Do not leave a live grant behind for an account this app refused.
            try? await tokenClient.revoke(token: response.refreshToken ?? response.accessToken)
            throw error
        }
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        cached = CachedToken(value: response.accessToken, expiresAt: now().addingTimeInterval(response.expiresIn))
        if let previous, !GoogleCredential.sameAccount(previous.accountEmail, account.email) {
            try? await tokenClient.revoke(token: previous.refreshToken)
        }
        return account
    }

    /// A bearer token valid for at least `refreshMargin` seconds.
    public func accessToken() async throws -> String {
        if let cached, now() < cached.expiresAt.addingTimeInterval(-AccessTokenProvider.refreshMargin) {
            return cached.value
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let credential = try store.load() else {
            cached = nil
            throw GoogleAuthError.signedOut
        }
        let generation = self.generation
        let task = Task { try await self.refresh(credential, generation: generation) }
        refreshTask = task
        return try await task.value
    }

    /// Drops the cached access token, e.g. after Drive answered 401.
    public func invalidateAccessToken() {
        cached = nil
    }

    /// Removes the credential from this device, then revokes it at Google best-effort.
    @discardableResult
    public func signOut() async throws -> GoogleSignOutOutcome {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        let accessToken = cached?.value
        cached = nil
        let credential = try? store.load()
        try store.delete()
        guard let token = credential?.refreshToken ?? accessToken else { return .notLinked }
        do {
            // Revoking the refresh token also revokes the access tokens issued from it.
            try await tokenClient.revoke(token: token)
            return .revoked
        } catch {
            return .localOnly
        }
    }

    private func refresh(_ credential: GoogleCredential, generation: Int) async throws -> String {
        let response: GoogleTokenResponse
        do {
            response = try await tokenClient.refresh(refreshToken: credential.refreshToken)
        } catch GoogleAuthError.invalidGrant {
            guard generation == self.generation else { return try await accessToken() }
            self.generation += 1
            refreshTask = nil
            cached = nil
            try? store.delete()
            throw GoogleAuthError.reauthenticationRequired
        } catch {
            guard generation == self.generation else { return try await accessToken() }
            refreshTask = nil
            throw error
        }
        // A sign-in or sign-out happened meanwhile: answer from the new state instead.
        guard generation == self.generation else { return try await accessToken() }
        refreshTask = nil
        if let rotated = response.refreshToken, rotated != credential.refreshToken {
            try? store.save(GoogleCredential(refreshToken: rotated, accountEmail: credential.accountEmail))
        }
        cached = CachedToken(value: response.accessToken, expiresAt: now().addingTimeInterval(response.expiresIn))
        return response.accessToken
    }
}
