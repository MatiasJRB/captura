import AuthenticationServices
import CapturaCore
import XCTest
@testable import Captura

@MainActor
final class GoogleSignInControllerTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        try await super.setUp()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
    }

    override func tearDown() async throws {
        window = nil
        try await super.tearDown()
    }

    private func makeController(
        info: [String: Any] = AppAuthFixtures.configuredInfo,
        store: TokenStore = InMemoryTokenStore(),
        transport: AppAuthStubTransport = AppAuthStubTransport(),
        web: FakeWebAuthenticationSession? = nil
    ) -> GoogleSignInController {
        let anchor = window
        return GoogleSignInController(infoDictionary: info, store: store, transport: transport, webSession: web ?? FakeWebAuthenticationSession(), anchorProvider: { anchor })
    }

    // MARK: Configuration

    func testFreshCloneShowsSetupMessageInsteadOfCrashing() {
        let controller = makeController(info: AppAuthFixtures.freshCloneInfo)
        guard case .notConfigured(let message) = controller.status else {
            return XCTFail("Expected notConfigured, got \(controller.status)")
        }
        XCTAssertTrue(message.hasPrefix("Falta configurar Google"))
        XCTAssertNil(controller.tokenProvider)
    }

    func testSignInWithoutConfigurationThrowsTheConfigurationError() async {
        let web = FakeWebAuthenticationSession()
        let controller = makeController(info: AppAuthFixtures.freshCloneInfo, web: web)
        do {
            try await controller.signIn()
            XCTFail("Expected a configuration error")
        } catch {
            XCTAssertEqual(error as? GoogleOAuthConfigurationError, .missingClientID)
        }
        XCTAssertNil(web.openedURL)
    }

    func testOnlyClientIDConfiguredStartsSignedOut() {
        let controller = makeController()
        XCTAssertEqual(controller.status, .signedOut)
        XCTAssertEqual(controller.configuration?.callbackScheme, AppAuthFixtures.reversedClientID)
    }

    func testStoredCredentialStartsSignedIn() {
        let store = InMemoryTokenStore(GoogleCredential(refreshToken: "r", accountEmail: AppAuthFixtures.email))
        XCTAssertEqual(makeController(store: store).status, .signedIn(email: AppAuthFixtures.email))
    }

    // MARK: Sign-in

    func testSignInOpensGoogleWithReversedClientIDCallbackScheme() async throws {
        let web = FakeWebAuthenticationSession()
        let controller = makeController(transport: AppAuthStubTransport([AppAuthFixtures.tokenResponse()]), web: web)
        try await controller.signIn()
        XCTAssertEqual(web.callbackScheme, AppAuthFixtures.reversedClientID)
        XCTAssertEqual(web.openedURL?.host, "accounts.google.com")
    }

    func testSignInLinksAccountAndStoresCredential() async throws {
        let store = InMemoryTokenStore()
        let controller = makeController(store: store, transport: AppAuthStubTransport([AppAuthFixtures.tokenResponse()]))
        let email = try await controller.signIn()
        XCTAssertEqual(email, AppAuthFixtures.email)
        XCTAssertEqual(controller.status, .signedIn(email: AppAuthFixtures.email))
        XCTAssertEqual(try store.load()?.refreshToken, "fixture-refresh-token")
        XCTAssertNil(controller.lastErrorMessage)
        XCTAssertFalse(controller.isWorking)
    }

    func testSignInExchangesCodeWithoutClientSecret() async throws {
        let transport = AppAuthStubTransport([AppAuthFixtures.tokenResponse()])
        let controller = makeController(transport: transport, web: FakeWebAuthenticationSession(.approve(code: "4/abc")))
        try await controller.signIn()
        let fields = try XCTUnwrap(transport.requests.first?.appFormFields)
        XCTAssertEqual(fields["code"], "4/abc")
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertNil(fields["client_secret"])
    }

    func testLinkedAccountProvidesAccessTokenForDrive() async throws {
        let controller = makeController(transport: AppAuthStubTransport([AppAuthFixtures.tokenResponse()]))
        try await controller.signIn()
        let provider = try XCTUnwrap(controller.tokenProvider)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "fixture-access-token")
    }

    func testCancelledSignInStaysSignedOutWithSpanishMessage() async {
        let controller = makeController(web: FakeWebAuthenticationSession(.fail(GoogleAuthError.cancelled)))
        do {
            try await controller.signIn()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .cancelled)
        }
        XCTAssertEqual(controller.status, .signedOut)
        XCTAssertEqual(controller.lastErrorMessage, GoogleAuthError.cancelled.userMessage)
    }

    func testSignInWithoutWindowFailsBeforeOpeningGoogle() async {
        let web = FakeWebAuthenticationSession()
        let controller = GoogleSignInController(infoDictionary: AppAuthFixtures.configuredInfo, store: InMemoryTokenStore(), transport: AppAuthStubTransport(), webSession: web, anchorProvider: { nil })
        do {
            try await controller.signIn()
            XCTFail("Expected presentationFailed")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .presentationFailed)
        }
        XCTAssertNil(web.openedURL)
    }

    // MARK: Sign-out and status

    func testSignOutRevokesAndReturnsToSignedOut() async throws {
        let store = InMemoryTokenStore(GoogleCredential(refreshToken: "fixture-refresh-token", accountEmail: AppAuthFixtures.email))
        let transport = AppAuthStubTransport([HTTPResponse(status: 200)])
        let controller = makeController(store: store, transport: transport)
        let outcome = try await controller.signOut()
        XCTAssertEqual(outcome, .revoked)
        XCTAssertEqual(controller.status, .signedOut)
        XCTAssertNil(try store.load())
        XCTAssertEqual(transport.requests.first?.url.absoluteString, "https://oauth2.googleapis.com/revoke")
    }

    func testOfflineSignOutStillUnlinksAndExplainsIt() async throws {
        let store = InMemoryTokenStore(GoogleCredential(refreshToken: "r", accountEmail: AppAuthFixtures.email))
        let controller = makeController(store: store)
        let outcome = try await controller.signOut()
        XCTAssertEqual(outcome, .localOnly)
        XCTAssertEqual(controller.status, .signedOut)
        XCTAssertNotNil(controller.lastErrorMessage)
    }

    func testRefreshStatusNoticesCredentialRemovedElsewhere() async throws {
        let store = InMemoryTokenStore(GoogleCredential(refreshToken: "r", accountEmail: AppAuthFixtures.email))
        let controller = makeController(store: store)
        try store.delete()
        await controller.refreshStatus()
        XCTAssertEqual(controller.status, .signedOut)
    }
}

@MainActor
final class SystemWebAuthenticationSessionTests: XCTestCase {
    func testCallbackURLIsReturned() throws {
        let url = URL(string: "\(AppAuthFixtures.reversedClientID):/oauth2redirect?state=s&code=c")!
        XCTAssertEqual(try SystemWebAuthenticationSession.result(callbackURL: url, error: nil).get(), url)
    }

    func testUserCancellationMapsToCancelled() {
        let result = SystemWebAuthenticationSession.result(callbackURL: nil, error: ASWebAuthenticationSessionError(.canceledLogin))
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? GoogleAuthError, .cancelled) }
    }

    func testPresentationErrorsMapToPresentationFailed() {
        for code in [ASWebAuthenticationSessionError.Code.presentationContextNotProvided, .presentationContextInvalid] {
            let result = SystemWebAuthenticationSession.result(callbackURL: nil, error: ASWebAuthenticationSessionError(code))
            XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? GoogleAuthError, .presentationFailed) }
        }
    }

    func testMissingURLAndErrorIsInvalidCallback() {
        XCTAssertThrowsError(try SystemWebAuthenticationSession.result(callbackURL: nil, error: nil).get()) {
            XCTAssertEqual($0 as? GoogleAuthError, .invalidCallback)
        }
    }

    func testSystemSessionForReversedClientIDSchemeCanStart() async throws {
        // Builds the real ASWebAuthenticationSession without presenting it.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let configuration = try GoogleOAuthConfiguration(infoDictionary: AppAuthFixtures.configuredInfo)
        let request = GoogleAuthorizationRequest(configuration: configuration)
        let context = GoogleSignInPresentationContext(anchor: UIWindow(windowScene: scene))
        let session = SystemWebAuthenticationSession.makeSession(url: request.url, callbackScheme: configuration.callbackScheme, context: context) { _, _ in }
        // A sheet cancelled by another test may still be animating out; give it up to 2 s.
        for _ in 0..<20 where !session.canStart {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(session.canStart)
        XCTAssertFalse(session.prefersEphemeralWebBrowserSession)
    }

    func testHostAppHasAWindowToAnchorTheSheet() {
        XCTAssertNotNil(GoogleSignInPresentationContext.foregroundWindow())
    }

    func testRealSessionStartsAndCancellingTheTaskReportsCancelled() async throws {
        // Starts the real system sheet, then cancels it. Reaching `.cancelled` (and not
        // `.presentationFailed`) proves `start()` succeeded with the app's window.
        // The `.invalid` host can never resolve, and the sheet first shows the system
        // consent alert, so no page is loaded.
        let anchor = try XCTUnwrap(GoogleSignInPresentationContext.foregroundWindow())
        let runner = SystemWebAuthenticationSession()
        let task = Task { @MainActor in
            try await runner.authenticate(url: URL(string: "https://captura.invalid/oauth")!, callbackScheme: AppAuthFixtures.reversedClientID, anchor: anchor)
        }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .cancelled)
        }
    }
}

final class GoogleAuthURLSessionTransportTests: XCTestCase {
    func testFormRequestIsTranslatedToURLRequest() throws {
        let body = Data("token=abc".utf8)
        let request = HTTPRequest(method: "POST", url: URL(string: "https://oauth2.googleapis.com/revoke")!, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: .data(body))
        let urlRequest = try GoogleAuthURLSessionTransport.urlRequest(for: request)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(urlRequest.httpBody, body)
        XCTAssertEqual(urlRequest.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testFileBodiesAreRefused() {
        let request = HTTPRequest(method: "PUT", url: URL(string: "https://oauth2.googleapis.com/token")!, body: .file(URL(fileURLWithPath: "/dev/null"), range: 0..<0))
        XCTAssertThrowsError(try GoogleAuthURLSessionTransport.urlRequest(for: request))
    }

    func testRedirectsAreRefused() async {
        let blocker = GoogleAuthRedirectBlocker()
        let response = HTTPURLResponse(url: URL(string: "https://oauth2.googleapis.com/token")!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let task = URLSession.shared.dataTask(with: URL(string: "https://oauth2.googleapis.com/token")!)
        let next = await blocker.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://attacker.test/")!))
        XCTAssertNil(next)
    }
}

/// Checks the Info.plist this build actually produced. Exactly one test runs per build:
/// a clean clone exercises the first, a build with `CAPTURA_GOOGLE_IOS_CLIENT_ID` set
/// (in Captura.local.xcconfig or on the xcodebuild command line) exercises the second.
@MainActor
final class GoogleAuthBuildConfigurationTests: XCTestCase {
    private func builtConfiguration() throws -> Result<GoogleOAuthConfiguration, GoogleOAuthConfigurationError> {
        GoogleOAuthConfiguration.load(infoDictionary: try XCTUnwrap(Bundle.main.infoDictionary))
    }

    func testUnconfiguredBuildShowsWhatToFillInsteadOfCrashing() throws {
        guard case .failure(let error) = try builtConfiguration() else {
            throw XCTSkip("This build has a Google client configured.")
        }
        XCTAssertTrue(error.userMessage.contains("CAPTURA_GOOGLE"), error.userMessage)
        let controller = GoogleSignInController(store: InMemoryTokenStore(), transport: AppAuthStubTransport())
        XCTAssertEqual(controller.status, .notConfigured(message: error.userMessage))
    }

    func testConfiguredBuildIsReadyToOpenGoogle() throws {
        guard case .success(let configuration) = try builtConfiguration() else {
            throw XCTSkip("This build has no Google client configured.")
        }
        XCTAssertTrue(configuration.callbackScheme.hasPrefix("com.googleusercontent.apps."))
        XCTAssertTrue(configuration.redirectURI.hasSuffix(":/oauth2redirect"))
        let controller = GoogleSignInController(store: InMemoryTokenStore(), transport: AppAuthStubTransport())
        XCTAssertEqual(controller.status, .signedOut)
        XCTAssertNotNil(controller.tokenProvider)
    }
}
