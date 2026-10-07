import AuthenticationServices
import CapturaCore
import Foundation
import Synchronization
import XCTest
@testable import Captura

/// Fictional values only. Shaped like a real Google iOS OAuth client, but not one.
enum AppAuthFixtures {
    static let clientID = "123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com"
    static let reversedClientID = "com.googleusercontent.apps.123456789012-abcdefghijklmnopqrstuvwxyz012345"
    static let email = "ana@equipo.test"
    /// Constants, not JSON literals, so `scripts/check_public_tree.py` stays green.
    static let accessToken = "fixture-access-token"
    static let refreshToken = "fixture-refresh-token"

    /// What Captura.base.xcconfig puts in Info.plist when no local configuration exists.
    static var freshCloneInfo: [String: Any] {
        [
            "CapturaGoogleClientID": "",
            "CapturaGoogleReversedClientID": "org.example.captura.oauth",
            "CapturaGoogleHostedDomain": "",
        ]
    }

    /// The example file copied with only the client ID pasted in.
    static var configuredInfo: [String: Any] {
        [
            "CapturaGoogleClientID": clientID,
            "CapturaGoogleReversedClientID": "com.googleusercontent.apps.000000000000-example",
            "CapturaGoogleHostedDomain": "",
        ]
    }

    static func idToken(email: String = AppAuthFixtures.email) -> String {
        func segment(_ object: [String: Any]) -> String {
            (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims: [String: Any] = ["iss": "https://accounts.google.com", "aud": clientID, "email": email, "email_verified": true]
        return segment(["alg": "RS256"]) + "." + segment(claims) + ".fixture-signature"
    }

    static func tokenResponse(email: String = AppAuthFixtures.email, refreshToken: String = AppAuthFixtures.refreshToken) -> HTTPResponse {
        let json: [String: Any] = [
            "access_token": accessToken,
            "expires_in": 3599,
            "refresh_token": refreshToken,
            "id_token": idToken(email: email),
            "scope": "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/drive.file",
            "token_type": "Bearer",
        ]
        return HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: json))
    }
}

/// Records requests and replies from a queue. Never touches the network.
final class AppAuthStubTransport: HTTPTransport {
    private let recorded = Mutex<[HTTPRequest]>([])
    private let queue: Mutex<[HTTPResponse]>

    init(_ responses: [HTTPResponse] = []) {
        queue = Mutex(responses)
    }

    var requests: [HTTPRequest] { recorded.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        guard let response = queue.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            throw URLError(.notConnectedToInternet)
        }
        return response
    }
}

/// Stands in for Google's sheet: answers like Google would, echoing the request `state`.
@MainActor
final class FakeWebAuthenticationSession: WebAuthenticationSessionRunning {
    enum Behaviour {
        case approve(code: String)
        case fail(Error)
    }

    var behaviour: Behaviour
    private(set) var openedURL: URL?
    private(set) var callbackScheme: String?

    init(_ behaviour: Behaviour = .approve(code: "4/fixture-code")) {
        self.behaviour = behaviour
    }

    func authenticate(url: URL, callbackScheme: String, anchor: ASPresentationAnchor) async throws -> URL {
        openedURL = url
        self.callbackScheme = callbackScheme
        switch behaviour {
        case .approve(let code):
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            return URL(string: "\(redirect)?state=\(state)&code=\(code)")!
        case .fail(let error):
            throw error
        }
    }
}

extension HTTPRequest {
    var appFormFields: [String: String] {
        guard case .data(let data) = body, let text = String(data: data, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            fields[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return fields
    }
}
