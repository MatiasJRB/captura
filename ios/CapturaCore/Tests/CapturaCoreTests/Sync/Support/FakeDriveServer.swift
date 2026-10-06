import CryptoKit
import Foundation
import XCTest
@testable import CapturaCore

/// In-memory stand-in for the parts of Drive v3 Captura uses: generateIds, files.get,
/// files.create (folders) and resumable uploads. It behaves like Google where it
/// matters for the client (308 + Range, 404 for unknown sessions, md5Checksum receipts).
final class FakeDriveServer: HTTPTransport, @unchecked Sendable {
    struct StoredFile {
        var metadata: [String: Any]
        var content: Data
    }

    private struct Session {
        var metadata: [String: Any]
        var total: Int64
        var received = Data()
    }

    enum Fault {
        /// The next chunk PUT keeps the first `persisting` bytes, then the connection drops.
        case dropNextChunk(persisting: Int)
        /// The next chunk PUT answers 404 (session expired) without storing anything.
        case expireSessionOnNextChunk
    }

    private let lock = NSLock()
    /// Like Drive, a file created without `parents` lands in My Drive (when set).
    private let myDriveRootID: String?
    private var files: [String: StoredFile] = [:]
    private var sessions: [String: Session] = [:]
    private var nextID = 1
    private var nextSession = 1
    private var faults: [Fault] = []
    private var failAllStatus: Int?
    private var rejectedNames: [String: HTTPResponse] = [:]
    private var log: [String] = []

    init(myDriveRootID: String? = nil) {
        self.myDriveRootID = myDriveRootID
    }

    /// Every stored file and folder, sorted.
    var allIDs: [String] { lock.withLock { files.keys.sorted() } }

    /// "METHOD path" of every request, without query or session IDs.
    var requestLog: [String] { lock.withLock { log } }
    var sessionCount: Int { lock.withLock { nextSession - 1 } }

    /// One-shot faults, consumed in order by chunk PUTs.
    func inject(_ fault: Fault) { lock.withLock { faults.append(fault) } }

    /// Every request answers `status` until set back to nil.
    func failEverything(status: Int?) { lock.withLock { failAllStatus = status } }

    /// Starting an upload of `name` always answers `status` (with an optional JSON body).
    func rejectUploads(named name: String, status: Int, json: String = "") {
        lock.withLock { rejectedNames[name] = HTTPResponse(status: status, body: Data(json.utf8)) }
    }

    func content(of id: String) -> Data? { lock.withLock { files[id]?.content } }

    func metadataJSON(of id: String) -> [String: Any]? { lock.withLock { files[id]?.metadata } }

    func ids(withParent folder: String) -> [String] {
        lock.withLock {
            files.filter { ($0.value.metadata["parents"] as? [String])?.contains(folder) == true }.keys.sorted()
        }
    }

    func folderIDs() -> [String] {
        lock.withLock {
            files.filter { $0.value.metadata["mimeType"] as? String == DriveMetadata.folderMimeType }.keys.sorted()
        }
    }

    func update(_ id: String, _ change: (inout [String: Any]) -> Void) {
        lock.withLock {
            guard var file = files[id] else { return }
            change(&file.metadata)
            files[id] = file
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(testToken)")
        XCTAssertFalse(request.url.absoluteString.contains(testToken))
        XCTAssertTrue(DriveEndpoint.isAllowed(request.url))
        let body = try Self.read(request.body)
        return try lock.withLock { try handle(request, body: body) }
    }

    private func handle(_ request: HTTPRequest, body: Data) throws -> HTTPResponse {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        let path = components.path
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        log.append("\(request.method) \(path)")
        if let status = failAllStatus { return HTTPResponse(status: status) }

        switch (request.method, path) {
        case ("GET", "/drive/v3/files/generateIds"):
            let id = String(format: "fakeDriveId%04d", nextID)
            nextID += 1
            return json(["ids": [id]])
        case ("GET", _) where path.hasPrefix("/drive/v3/files/"):
            let id = String(path.dropFirst("/drive/v3/files/".count))
            XCTAssertEqual(query["fields"], DriveMetadata.fields)
            guard let file = files[id] else { return HTTPResponse(status: 404) }
            return json(file.metadata)
        case ("POST", "/drive/v3/files"):
            var metadata = try object(body)
            guard let id = metadata["id"] as? String else { return HTTPResponse(status: 400) }
            if files[id] != nil { return HTTPResponse(status: 409) }
            if metadata["parents"] == nil, let myDriveRootID { metadata["parents"] = [myDriveRootID] }
            metadata["ownedByMe"] = true
            metadata["shared"] = false
            metadata["trashed"] = false
            files[id] = StoredFile(metadata: metadata, content: Data())
            return json(["id": id])
        case ("POST", "/upload/drive/v3/files"):
            XCTAssertEqual(query["uploadType"], "resumable")
            XCTAssertEqual(request.headers["X-Upload-Content-Type"], "audio/mp4")
            let metadata = try object(body)
            if let name = metadata["name"] as? String, let rejection = rejectedNames[name] {
                return rejection
            }
            guard let id = metadata["id"] as? String, files[id] == nil,
                  let total = request.headers["X-Upload-Content-Length"].flatMap(Int64.init)
            else { return HTTPResponse(status: 409) }
            let sessionID = "fake-session-\(nextSession)"
            nextSession += 1
            sessions[sessionID] = Session(metadata: metadata, total: total)
            return HTTPResponse(status: 200, headers: [
                "Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id&upload_id=\(sessionID)",
            ])
        case ("PUT", "/upload/drive/v3/files"):
            return try put(request, sessionID: query["upload_id"] ?? "", body: body)
        default:
            return HTTPResponse(status: 400)
        }
    }

    private func put(_ request: HTTPRequest, sessionID: String, body: Data) throws -> HTTPResponse {
        guard var session = sessions[sessionID] else { return HTTPResponse(status: 404) }
        let contentRange = request.headers["Content-Range"] ?? ""
        if contentRange.hasPrefix("bytes */") {
            if Int64(session.received.count) == session.total, let id = session.metadata["id"] as? String, files[id] != nil {
                return json(["id": id])
            }
            return incomplete(session)
        }
        if case .expireSessionOnNextChunk? = faults.first {
            faults.removeFirst()
            sessions[sessionID] = nil
            return HTTPResponse(status: 404)
        }
        // "bytes a-b/total"
        let spec = contentRange.dropFirst("bytes ".count)
        let parts = spec.split(separator: "/")
        let bounds = parts[0].split(separator: "-").compactMap { Int64($0) }
        guard bounds.count == 2, bounds[0] == Int64(session.received.count),
              Int64(body.count) == bounds[1] - bounds[0] + 1, Int64(parts[1]) == session.total
        else { return HTTPResponse(status: 400) }
        if case .dropNextChunk(let persisting)? = faults.first {
            faults.removeFirst()
            session.received.append(body.prefix(persisting))
            sessions[sessionID] = session
            throw URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: request.url])
        }
        session.received.append(body)
        sessions[sessionID] = session
        guard Int64(session.received.count) == session.total else { return incomplete(session) }
        var metadata = session.metadata
        let id = metadata["id"] as! String
        metadata["size"] = String(session.total)
        metadata["md5Checksum"] = Checksums.compute(data: session.received).md5
        metadata["ownedByMe"] = true
        metadata["shared"] = false
        metadata["trashed"] = false
        files[id] = StoredFile(metadata: metadata, content: session.received)
        return json(["id": id])
    }

    private func incomplete(_ session: Session) -> HTTPResponse {
        guard !session.received.isEmpty else { return HTTPResponse(status: 308) }
        return HTTPResponse(status: 308, headers: ["Range": "bytes=0-\(session.received.count - 1)"])
    }

    private func json(_ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func read(_ body: HTTPRequest.Body) throws -> Data {
        switch body {
        case .none: return Data()
        case .data(let data): return data
        case .file(let url, let range):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
        }
    }
}

/// Thread-safe folder ID storage for engine tests.
final class FolderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var saves = 0

    init(_ value: String? = nil) { self.value = value }

    var current: String? { lock.withLock { value } }
    var saveCount: Int { lock.withLock { saves } }

    var storage: FolderIDStorage {
        FolderIDStorage(
            load: { [self] in lock.withLock { value } },
            save: { [self] id in lock.withLock { value = id; saves += 1 } }
        )
    }
}

/// Mutable network conditions and clock for engine tests.
final class Environment: @unchecked Sendable {
    private let lock = NSLock()
    private var network: NetworkConditions
    private var date: Date

    init(online: Bool = true, wifi: Bool = true, now: Date = Fixture.baseDate) {
        network = NetworkConditions(online: online, wifi: wifi)
        date = now
    }

    var now: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }

    var conditions: NetworkConditions {
        get { lock.withLock { network } }
        set { lock.withLock { network = newValue } }
    }
}
