import AuthenticationServices
import CapturaCore
import Foundation
import Observation
import UIKit

/// The app-facing Google account link: shows Google's sign-in sheet, keeps the linked
/// account in the Keychain and exposes the token provider the Drive client uses.
///
/// Linking only authorizes uploads; it never starts recording or uploading by itself.
@MainActor
@Observable
final class GoogleSignInController {
    enum Status: Equatable {
        /// This build has no usable Google client; `message` says what to fill in.
        case notConfigured(message: String)
        case signedOut
        case signedIn(email: String)
    }

    private(set) var status: Status
    private(set) var isWorking = false
    /// Spanish, ready to show; `nil` after a successful action.
    private(set) var lastErrorMessage: String?

    /// `nil` when Google is not configured in this build.
    let tokenProvider: AccessTokenProvider?
    private let configurationError: GoogleOAuthConfigurationError?
    private let webSession: WebAuthenticationSessionRunning
    private let anchorProvider: @MainActor () -> ASPresentationAnchor?

    init(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        store: TokenStore = KeychainTokenStore(),
        transport: HTTPTransport = GoogleAuthURLSessionTransport(),
        webSession: WebAuthenticationSessionRunning? = nil,
        anchorProvider: (@MainActor () -> ASPresentationAnchor?)? = nil
    ) {
        self.webSession = webSession ?? SystemWebAuthenticationSession()
        self.anchorProvider = anchorProvider ?? { GoogleSignInPresentationContext.foregroundWindow() }
        switch GoogleOAuthConfiguration.load(infoDictionary: infoDictionary) {
        case .success(let configuration):
            tokenProvider = AccessTokenProvider(configuration: configuration, transport: transport, store: store)
            configurationError = nil
            if let credential = try? store.load() {
                status = .signedIn(email: credential.accountEmail)
            } else {
                status = .signedOut
            }
        case .failure(let error):
            tokenProvider = nil
            configurationError = error
            status = .notConfigured(message: error.userMessage)
        }
    }

    var configuration: GoogleOAuthConfiguration? { tokenProvider?.configuration }

    /// Re-reads the Keychain, e.g. after a sync found the grant revoked.
    func refreshStatus() async {
        guard let tokenProvider else { return }
        if case .signedIn(let email)? = try? await tokenProvider.state() {
            status = .signedIn(email: email)
        } else {
            status = .signedOut
        }
    }

    /// Shows Google's sheet and links the chosen account. Returns its email.
    @discardableResult
    func signIn(loginHint: String? = nil) async throws -> String {
        guard let tokenProvider else { throw configurationError ?? GoogleOAuthConfigurationError.missingClientID }
        guard !isWorking else { throw GoogleAuthError.presentationFailed }
        isWorking = true
        defer { isWorking = false }
        do {
            guard let anchor = anchorProvider() else { throw GoogleAuthError.presentationFailed }
            let request = tokenProvider.makeAuthorizationRequest(loginHint: loginHint)
            let callbackURL = try await webSession.authenticate(
                url: request.url,
                callbackScheme: request.configuration.callbackScheme,
                anchor: anchor
            )
            let account = try await tokenProvider.completeSignIn(callbackURL: callbackURL, request: request)
            status = .signedIn(email: account.email)
            lastErrorMessage = nil
            return account.email
        } catch {
            lastErrorMessage = GoogleAuthError.userMessage(for: error)
            await refreshStatus()
            throw error
        }
    }

    /// Unlinks this device and asks Google to revoke the grant (best-effort).
    @discardableResult
    func signOut() async throws -> GoogleSignOutOutcome {
        guard let tokenProvider else { return .notLinked }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await tokenProvider.signOut()
            status = .signedOut
            lastErrorMessage = outcome == .localOnly ? GoogleAuthError.revocationFailed(status: 0).userMessage : nil
            return outcome
        } catch {
            lastErrorMessage = GoogleAuthError.userMessage(for: error)
            await refreshStatus()
            throw error
        }
    }
}
