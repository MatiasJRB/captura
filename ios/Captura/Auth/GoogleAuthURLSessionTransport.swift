import CapturaCore
import Foundation

/// The network transport for OAuth calls: ephemeral (no cookies, no disk cache) and never
/// follows redirects, so a form body carrying a code or refresh token cannot be replayed
/// to a host outside `GoogleOAuthEndpoints.allowedHosts`.
struct GoogleAuthURLSessionTransport: HTTPTransport {
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    init(session: URLSession = GoogleAuthURLSessionTransport.sharedSession) {
        self.session = session
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = try GoogleAuthURLSessionTransport.urlRequest(for: request)
        let (data, response) = try await session.data(for: urlRequest, delegate: GoogleAuthRedirectBlocker())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            headers[name.lowercased()] = text
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    static func urlRequest(for request: HTTPRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        switch request.body {
        case .none:
            break
        case .data(let body):
            urlRequest.httpBody = body
        case .file:
            // OAuth requests are small forms; file bodies belong to the Drive transport.
            throw URLError(.unsupportedURL)
        }
        return urlRequest
    }
}

/// Refuses every HTTP redirect; the request then completes with the 3xx response itself.
final class GoogleAuthRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
