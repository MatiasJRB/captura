import CapturaCore
import Foundation

/// The network transport for Drive calls.
///
/// - Never follows redirects. Google answers a resumable-upload status query with
///   `308 Resume Incomplete`, which `URLSession` would otherwise treat as a redirect;
///   blocking every redirect also keeps the bearer token on the allowlisted host.
/// - Sends `.file(url, range:)` bodies by reading only that region of the file (1 MiB
///   per chunk with `DriveClient.defaultChunkSize`), never the whole recording.
/// - Always sends an explicit `Content-Length`, including `0` for an empty body (the
///   status query `PUT` with `Content-Range: bytes */<size>` requires it).
/// - Ephemeral: no cookies, no cache, nothing written to disk.
/// - `allowsCellular == false` (automatic sync) refuses cellular, expensive (e.g. a
///   phone hotspot) and Low Data Mode paths at the socket level, like Android's
///   Wi-Fi-bound job, even if Wi-Fi drops in the middle of a request.
struct DriveURLSessionTransport: HTTPTransport {
    private static let wifiOnlySession = makeSession(allowsCellular: false)
    private static let anyNetworkSession = makeSession(allowsCellular: true)

    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    init(allowsCellular: Bool) {
        self.init(session: allowsCellular ? Self.anyNetworkSession : Self.wifiOnlySession)
    }

    static func makeConfiguration(allowsCellular: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Idle timeouts, like the Android uploader (20 s connect / 30 s read), with
        // headroom for a 1 MiB chunk on a slow network.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 10 * 60
        // Fail fast when offline; the sync engine decides when to try again.
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = allowsCellular
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.allowsConstrainedNetworkAccess = allowsCellular
        return configuration
    }

    private static func makeSession(allowsCellular: Bool) -> URLSession {
        URLSession(configuration: makeConfiguration(allowsCellular: allowsCellular))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let blocker = DriveRedirectBlocker()
        let data: Data
        let response: URLResponse
        switch request.body {
        case .none:
            (data, response) = try await session.data(for: urlRequest, delegate: blocker)
        case .data(let body):
            urlRequest.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            (data, response) = try await session.upload(for: urlRequest, from: body, delegate: blocker)
        case .file(let url, let range):
            let body = try Self.readRegion(of: url, range: range)
            urlRequest.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            (data, response) = try await session.upload(for: urlRequest, from: body, delegate: blocker)
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResponse(status: http.statusCode, headers: Self.lowercasedHeaders(of: http), body: data)
    }

    /// Exactly the bytes of `range`. A file that is now shorter than the range (it
    /// changed after it was queued) is a transport failure; the next run re-hashes the
    /// file and quarantines it.
    static func readRegion(of url: URL, range: Range<Int64>) throws -> Data {
        guard range.lowerBound >= 0, !range.isEmpty else { throw TransportFailure.invalidRange }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let count = Int(range.upperBound - range.lowerBound)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw TransportFailure.shortFile
        }
        return data
    }

    static func lowercasedHeaders(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name.lowercased()] = (value as? String) ?? String(describing: value)
        }
        return headers
    }

    /// Never carries a URL, so a session URI cannot leak through an error message.
    enum TransportFailure: Error, Equatable {
        case invalidRange
        case shortFile
    }
}

/// Refuses every HTTP redirect; the request then completes with the 3xx response itself.
final class DriveRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
