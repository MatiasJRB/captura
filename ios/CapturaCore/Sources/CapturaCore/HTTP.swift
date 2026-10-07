import Foundation

/// A minimal HTTP exchange. Every network call in CapturaCore goes through
/// `HTTPTransport` so tests can replace the network with a deterministic stub.
public struct HTTPRequest: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case none
        case data(Data)
        /// Streamed from disk; `range` selects the bytes to send (for resumable uploads).
        case file(URL, range: Range<Int64>)
    }

    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Body

    public init(method: String, url: URL, headers: [String: String] = [:], body: Body = .none) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
