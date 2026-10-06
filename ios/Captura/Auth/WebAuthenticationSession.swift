import AuthenticationServices
import CapturaCore
import Foundation
import Synchronization
import UIKit

/// Opens Google's sign-in page and returns the redirect URL. Abstracted so tests can
/// replace the system sheet.
@MainActor
protocol WebAuthenticationSessionRunning: AnyObject {
    func authenticate(url: URL, callbackScheme: String, anchor: ASPresentationAnchor) async throws -> URL
}

/// Returns a fixed window as the anchor for the Google sheet.
@MainActor
final class GoogleSignInPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }

    /// The key window of the foreground scene, falling back to any window of any scene.
    static func foregroundWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive } + scenes
        for scene in ordered {
            if let window = scene.keyWindow ?? scene.windows.first { return window }
        }
        return nil
    }
}

/// `ASWebAuthenticationSession` with the iOS 17.4+ `Callback` API. The sheet shares the
/// Safari session (not ephemeral) so an account already signed in to Google can be reused.
@MainActor
final class SystemWebAuthenticationSession: WebAuthenticationSessionRunning {
    private var activeSession: ASWebAuthenticationSession?
    private var activeContext: GoogleSignInPresentationContext?
    private var activeResume: GoogleSignInResumeOnce?

    func authenticate(url: URL, callbackScheme: String, anchor: ASPresentationAnchor) async throws -> URL {
        guard activeSession == nil else { throw GoogleAuthError.presentationFailed }
        try Task.checkCancellation()
        defer {
            activeSession = nil
            activeContext = nil
            activeResume = nil
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let resume = GoogleSignInResumeOnce(continuation)
                let context = GoogleSignInPresentationContext(anchor: anchor)
                let session = SystemWebAuthenticationSession.makeSession(url: url, callbackScheme: callbackScheme, context: context) { callbackURL, error in
                    resume.resume(with: SystemWebAuthenticationSession.result(callbackURL: callbackURL, error: error))
                }
                // The session and its context must stay alive until the sheet closes.
                activeSession = session
                activeContext = context
                activeResume = resume
                if !session.start() {
                    resume.resume(with: .failure(GoogleAuthError.presentationFailed))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelActiveSession() }
        }
    }

    /// A programmatic `cancel()` dismisses the sheet without calling the completion
    /// handler, so the waiting caller is resumed here.
    private func cancelActiveSession() {
        activeSession?.cancel()
        activeResume?.resume(with: .failure(GoogleAuthError.cancelled))
    }

    static func makeSession(
        url: URL,
        callbackScheme: String,
        context: GoogleSignInPresentationContext,
        completion: @escaping ASWebAuthenticationSession.CompletionHandler
    ) -> ASWebAuthenticationSession {
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme), completionHandler: completion)
        session.presentationContextProvider = context
        session.prefersEphemeralWebBrowserSession = false
        return session
    }

    /// Maps the sheet's outcome to a callback URL or a `GoogleAuthError`.
    nonisolated static func result(callbackURL: URL?, error: Error?) -> Result<URL, Error> {
        if let error {
            if let sessionError = error as? ASWebAuthenticationSessionError {
                switch sessionError.code {
                case .canceledLogin:
                    return .failure(GoogleAuthError.cancelled)
                case .presentationContextNotProvided, .presentationContextInvalid:
                    return .failure(GoogleAuthError.presentationFailed)
                @unknown default:
                    return .failure(error)
                }
            }
            return .failure(error)
        }
        guard let callbackURL else { return .failure(GoogleAuthError.invalidCallback) }
        return .success(callbackURL)
    }
}

/// Resumes a continuation at most once, whichever of the completion handler or a failed
/// `start()` comes first.
final class GoogleSignInResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<URL, Error>?>

    init(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<URL, Error>) {
        let pending = continuation.withLock { value -> CheckedContinuation<URL, Error>? in
            defer { value = nil }
            return value
        }
        pending?.resume(with: result)
    }
}
