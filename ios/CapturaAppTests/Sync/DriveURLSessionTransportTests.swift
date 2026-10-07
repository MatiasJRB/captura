import CapturaCore
import Foundation
import Synchronization
import XCTest
@testable import Captura

/// Answers every request in-process: nothing reaches the network.
final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        /// When set, the stub reports a redirect to this URL first.
        var redirect: URL?
    }

    struct Seen: Sendable {
        var request: URLRequest
        /// The uploaded bytes, when the loading system exposes them to the protocol.
        var body: Data?
    }

    private static let state = Mutex<(reply: Reply, seen: [Seen])>((Reply(status: 200), []))

    static func reset(reply: Reply) {
        state.withLock { $0 = (reply, []) }
    }

    static var seen: [Seen] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        let reply = Self.state.withLock { state -> Reply in
            state.seen.append(Seen(request: request, body: body))
            return state.reply
        }
        let url = request.url!
        if let target = reply.redirect {
            var headers = reply.headers
            headers["Location"] = target.absoluteString
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class DriveURLSessionTransportTests: XCTestCase {
    private var directory: URL!
    private var transport: DriveURLSessionTransport!
    private let session = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=fixture-session")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captura-transport-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = DriveURLSessionTransport.makeConfiguration(allowsCellular: true)
        configuration.protocolClasses = [StubURLProtocol.self]
        transport = DriveURLSessionTransport(session: URLSession(configuration: configuration))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixtureFile(bytes: Int) throws -> (URL, Data) {
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let url = directory.appendingPathComponent("personal-capture-20261006-120000-00000000-0000-4000-8000-000000000001.m4a")
        try data.write(to: url)
        return (url, data)
    }

    func testResponseHeaderNamesAreLowerCased() async throws {
        StubURLProtocol.reset(reply: .init(status: 308, headers: ["Range": "bytes=0-262143", "X-Fixture": "1"]))
        let response = try await transport.send(HTTPRequest(method: "PUT", url: session, headers: ["Content-Range": "bytes */1048576"], body: .data(Data())))
        XCTAssertEqual(response.status, 308)
        XCTAssertEqual(response.headers["range"], "bytes=0-262143")
        XCTAssertEqual(response.headers["x-fixture"], "1")
        XCTAssertNil(response.headers["Range"])
    }

    func testEmptyDataBodySendsContentLengthZero() async throws {
        StubURLProtocol.reset(reply: .init(status: 308))
        _ = try await transport.send(HTTPRequest(method: "PUT", url: session, headers: ["Content-Range": "bytes */1048576"], body: .data(Data())))
        let request = try XCTUnwrap(StubURLProtocol.seen.first?.request)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes */1048576")
    }

    func testRequestHeadersAreForwardedAsGiven() async throws {
        StubURLProtocol.reset(reply: .init(status: 200, body: Data(#"{"ids":["fixtureId"]}"#.utf8)))
        let url = DriveEndpoint.generateIDs
        let response = try await transport.send(HTTPRequest(method: "GET", url: url, headers: ["Authorization": "Bearer fixture-token"]))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), #"{"ids":["fixtureId"]}"#)
        let request = try XCTUnwrap(StubURLProtocol.seen.first?.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
    }

    func testFileBodySendsOnlyTheRequestedRegion() async throws {
        let (file, data) = try fixtureFile(bytes: 600_000)
        let range: Range<Int64> = 262_144..<524_288
        StubURLProtocol.reset(reply: .init(status: 308, headers: ["Range": "bytes=0-524287"]))
        let response = try await transport.send(HTTPRequest(
            method: "PUT", url: session,
            headers: ["Content-Range": "bytes 262144-524287/600000", "Content-Type": "audio/mp4"],
            body: .file(file, range: range)
        ))
        XCTAssertEqual(response.status, 308)
        let seen = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Content-Length"), "262144")
        let body = try XCTUnwrap(seen.body, "the upload body reaches the protocol as a stream")
        XCTAssertEqual(body, data.subdata(in: 262_144..<524_288))
    }

    func testRegionReaderReturnsExactBytes() throws {
        let (file, data) = try fixtureFile(bytes: 10_000)
        XCTAssertEqual(try DriveURLSessionTransport.readRegion(of: file, range: 1_000..<4_000), data.subdata(in: 1_000..<4_000))
        XCTAssertEqual(try DriveURLSessionTransport.readRegion(of: file, range: 9_999..<10_000), data.subdata(in: 9_999..<10_000))
    }

    func testRegionBeyondTheFileIsAFailureNotAShortUpload() throws {
        let (file, _) = try fixtureFile(bytes: 2_000)
        XCTAssertThrowsError(try DriveURLSessionTransport.readRegion(of: file, range: 1_000..<3_000)) { error in
            XCTAssertEqual(error as? DriveURLSessionTransport.TransportFailure, .shortFile)
        }
        XCTAssertThrowsError(try DriveURLSessionTransport.readRegion(of: file, range: 5..<5))
    }

    func testRedirectsAreNotFollowed() async throws {
        let elsewhere = URL(string: "https://attacker.invalid/collect")!
        StubURLProtocol.reset(reply: .init(status: 302, redirect: elsewhere))
        let response = try await transport.send(HTTPRequest(method: "GET", url: DriveEndpoint.generateIDs, headers: ["Authorization": "Bearer fixture-token"]))
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(StubURLProtocol.seen.map { $0.request.url?.host }, ["www.googleapis.com"])
    }

    func testRedirectBlockerRefusesEveryRedirect() async throws {
        let blocker = DriveRedirectBlocker()
        let task = URLSession.shared.dataTask(with: DriveEndpoint.generateIDs)
        let response = HTTPURLResponse(url: DriveEndpoint.generateIDs, statusCode: 308, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://www.googleapis.com/other"])!
        let next = await blocker.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://www.googleapis.com/other")!))
        XCTAssertNil(next)
        task.cancel()
    }

    func testAutomaticConfigurationRefusesCellularExpensiveAndConstrainedNetworks() {
        let automatic = DriveURLSessionTransport.makeConfiguration(allowsCellular: false)
        XCTAssertFalse(automatic.allowsCellularAccess)
        XCTAssertFalse(automatic.allowsExpensiveNetworkAccess)
        XCTAssertFalse(automatic.allowsConstrainedNetworkAccess)
        let manual = DriveURLSessionTransport.makeConfiguration(allowsCellular: true)
        XCTAssertTrue(manual.allowsCellularAccess)
        XCTAssertTrue(manual.allowsExpensiveNetworkAccess)
        XCTAssertNil(manual.httpCookieStorage)
        XCTAssertNil(manual.urlCache)
        XCTAssertFalse(manual.waitsForConnectivity)
    }
}
