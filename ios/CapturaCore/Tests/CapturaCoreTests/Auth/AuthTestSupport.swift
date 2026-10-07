import Foundation
import Synchronization
import XCTest
@testable import CapturaCore

/// Fictional values only. Shaped like a real Google iOS OAuth client, but not one.
enum AuthFixtures {
    static let clientID = "123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com"
    static let reversedClientID = "com.googleusercontent.apps.123456789012-abcdefghijklmnopqrstuvwxyz012345"
    static let redirectURI = reversedClientID + ":/oauth2redirect"
    static let email = "ana@equipo.test"
    static let domain = "equipo.test"
    static let refreshToken = "fixture-refresh-token"
    static let accessToken = "fixture-access-token"

    static func configuration(hostedDomain: String? = nil) -> GoogleOAuthConfiguration {
        try! GoogleOAuthConfiguration(clientID: clientID, reversedClientID: reversedClientID, hostedDomain: hostedDomain)
    }

    static func claims(
        email: String? = AuthFixtures.email,
        emailVerified: Any = true,
        hostedDomain: String? = nil,
        audience: Any = AuthFixtures.clientID,
        issuer: String = "https://accounts.google.com"
    ) -> [String: Any] {
        var claims: [String: Any] = ["iss": issuer, "aud": audience, "sub": "100000000000000000001", "email_verified": emailVerified]
        if let email { claims["email"] = email }
        if let hostedDomain { claims["hd"] = hostedDomain }
        return claims
    }

    /// An unsigned JWT with the given payload. The signature segment is a dummy.
    static func idToken(_ claims: [String: Any] = claims()) -> String {
        let header = OAuthBase64URL.encode(try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"]))
        let payload = OAuthBase64URL.encode(try! JSONSerialization.data(withJSONObject: claims))
        return "\(header).\(payload).fixture-signature"
    }

    static let allScopes = "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/drive.file"

    static func tokenResponse(
        accessToken: String = AuthFixtures.accessToken,
        expiresIn: Int? = 3599,
        refreshToken: String? = AuthFixtures.refreshToken,
        idToken: String? = AuthFixtures.idToken(),
        scope: String? = allScopes,
        tokenType: String = "Bearer"
    ) -> HTTPResponse {
        var json: [String: Any] = ["access_token": accessToken, "token_type": tokenType]
        if let expiresIn { json["expires_in"] = expiresIn }
        if let refreshToken { json["refresh_token"] = refreshToken }
        if let idToken { json["id_token"] = idToken }
        if let scope { json["scope"] = scope }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: try! JSONSerialization.data(withJSONObject: json))
    }

    static func errorResponse(status: Int = 400, error: String, description: String = "Fixture error.") -> HTTPResponse {
        let body = try! JSONSerialization.data(withJSONObject: ["error": error, "error_description": description])
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    static func callbackURL(for request: GoogleAuthorizationRequest, code: String = "4/fixture-code") -> URL {
        URL(string: "\(request.configuration.redirectURI)?state=\(request.state)&code=\(OAuthFormEncoding.escape(code))&scope=openid")!
    }
}

/// Records every request and answers with queued responses or a custom handler.
final class AuthStubTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let recorded = Mutex<[HTTPRequest]>([])
    private let queue: Mutex<[Result<HTTPResponse, Error>]>
    private let handler: Handler?

    init(_ responses: [HTTPResponse] = []) {
        queue = Mutex(responses.map { .success($0) })
        handler = nil
    }

    init(results: [Result<HTTPResponse, Error>]) {
        queue = Mutex(results)
        handler = nil
    }

    init(handler: @escaping Handler) {
        queue = Mutex([])
        self.handler = handler
    }

    var requests: [HTTPRequest] { recorded.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        if let handler { return try await handler(request) }
        let next = queue.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let next else {
            XCTFail("Unexpected request to \(request.url.absoluteString)")
            throw URLError(.unsupportedURL)
        }
        return try next.get()
    }
}

/// A manually advanced clock.
final class AuthTestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_791_300_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var function: @Sendable () -> Date { { self.now } }
}

/// Holds requests until the test opens it.
actor AuthTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

extension HTTPRequest {
    /// Decoded `application/x-www-form-urlencoded` body fields.
    var formFields: [String: String] {
        guard case .data(let data) = body,
              let text = String(data: data, encoding: .utf8),
              let pairs = OAuthFormEncoding.decode(text) else { return [:] }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    var bodyText: String {
        guard case .data(let data) = body else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Asserts that `body` throws exactly `expected`.
func XCTAssertThrowsAuthError<T>(
    _ expected: GoogleAuthError,
    _ body: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
        XCTAssertEqual(error as? GoogleAuthError, expected, file: file, line: line)
    }
}

/// Async variant of `XCTAssertThrowsAuthError`.
func assertThrowsAuthError<T>(
    _ expected: GoogleAuthError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("Expected \(expected), but nothing was thrown", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? GoogleAuthError, expected, file: file, line: line)
    }
}
