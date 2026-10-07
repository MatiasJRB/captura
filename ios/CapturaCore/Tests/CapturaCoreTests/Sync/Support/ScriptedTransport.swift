import Foundation
import XCTest
@testable import CapturaCore

/// Fictional token used by every test. It must never appear in a URL.
let testToken = "test-only-token"

/// Replays a fixed script of replies, in order, and records every request.
/// Each request must carry the bearer header and keep the token out of the URL.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    struct Step {
        let method: String
        let urlPrefix: String
        let reply: @Sendable (HTTPRequest) throws -> HTTPResponse
    }

    private let lock = NSLock()
    private var steps: [Step] = []
    private var recorded: [HTTPRequest] = []
    private var unexpected: [String] = []

    var requests: [HTTPRequest] { lock.withLock { recorded } }
    var remainingSteps: Int { lock.withLock { steps.count } }
    var unexpectedRequests: [String] { lock.withLock { unexpected } }

    func on(
        _ method: String, _ urlPrefix: String, status: Int,
        headers: [String: String] = [:], json: String = ""
    ) {
        let response = HTTPResponse(status: status, headers: headers, body: Data(json.utf8))
        lock.withLock { steps.append(Step(method: method, urlPrefix: urlPrefix, reply: { _ in response })) }
    }

    func on(_ method: String, _ urlPrefix: String, reply: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        lock.withLock { steps.append(Step(method: method, urlPrefix: urlPrefix, reply: reply)) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let step: Step? = lock.withLock {
            recorded.append(request)
            guard !steps.isEmpty else {
                unexpected.append("\(request.method) \(request.url.absoluteString)")
                return nil
            }
            return steps.removeFirst()
        }
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(testToken)")
        XCTAssertFalse(request.url.absoluteString.contains(testToken), "tokens must never be sent in URLs")
        guard let step else {
            XCTFail("unexpected request \(request.method) \(request.url.absoluteString)")
            return HTTPResponse(status: 599)
        }
        XCTAssertEqual(request.method, step.method)
        XCTAssertTrue(
            request.url.absoluteString.hasPrefix(step.urlPrefix),
            "\(request.url.absoluteString) does not start with \(step.urlPrefix)"
        )
        return try step.reply(request)
    }
}

enum Drive {
    static let files = "https://www.googleapis.com/drive/v3/files"
    static let generate = "https://www.googleapis.com/drive/v3/files/generateIds"
    static let upload = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable"
    static let session = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=fixture-session"

    static func file(_ id: String) -> String { "\(files)/\(id)?" }

    static func generatedIDs(_ id: String) -> String { #"{"ids":["\#(id)"]}"# }

    static func folderJSON(
        id: String = "folder", device: String = "test-device", shared: Bool = false,
        ownedByMe: Bool = true, trashed: Bool = false, mimeType: String = "application/vnd.google-apps.folder",
        inbox: String = "1"
    ) -> String {
        """
        {"id":"\(id)","name":"Captura · audios","mimeType":"\(mimeType)","shared":\(shared),\
        "ownedByMe":\(ownedByMe),"trashed":\(trashed),\
        "properties":{"personalCaptureInbox":"\(inbox)","device":"\(device)"}}
        """
    }

    static func audioJSON(
        id: String, name: String, checksums: FileChecksums, folder: String = "folder",
        size: Int64? = nil, md5: String? = nil, sha256: String? = nil, captureKind: String? = nil,
        shared: Bool = false, ownedByMe: Bool = true, trashed: Bool = false, mimeType: String = "audio/mp4"
    ) -> String {
        let kind = captureKind ?? CaptureKind.from(fileName: name).rawValue
        return """
        {"id":"\(id)","name":"\(name)","mimeType":"\(mimeType)","size":"\(size ?? checksums.bytes)",\
        "md5Checksum":"\(md5 ?? checksums.md5)","parents":["\(folder)"],"shared":\(shared),\
        "ownedByMe":\(ownedByMe),"trashed":\(trashed),\
        "properties":{"personalCaptureAudio":"1","sha256":"\(sha256 ?? checksums.sha256)","captureKind":"\(kind)"}}
        """
    }
}

func makeClient(_ transport: any HTTPTransport, chunkSize: Int64 = DriveClient.defaultChunkSize) -> DriveClient {
    DriveClient(transport: transport, chunkSize: chunkSize) { _ in testToken }
}

/// Remembers the last ID handed to a persistence callback.
final class IDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }

    var current: String? { lock.withLock { value } }
    func record(_ id: String) { lock.withLock { value = id } }
}

/// Counts token requests and whether a refresh was forced.
final class TokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []
    var forcedRefreshes: [Bool] { lock.withLock { calls } }

    func provider(_ tokens: [String]) -> DriveClient.TokenProvider {
        { [self] force in
            lock.withLock {
                calls.append(force)
                return tokens[min(calls.count - 1, tokens.count - 1)]
            }
        }
    }
}
