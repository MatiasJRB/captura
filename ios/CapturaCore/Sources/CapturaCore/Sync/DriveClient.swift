import Foundation

/// One local file to upload under a stable, pre-generated Drive file ID.
public struct DriveUpload: Equatable, Sendable {
    public var fileID: String
    public var name: String
    public var fileURL: URL
    public var checksums: FileChecksums

    public init(fileID: String, name: String, fileURL: URL, checksums: FileChecksums) {
        self.fileID = fileID
        self.name = name
        self.fileURL = fileURL
        self.checksums = checksums
    }
}

/// What Google reports about a resumable session.
public enum ResumableUploadStatus: Equatable, Sendable {
    /// 404/410: the session is gone; start a new one from byte 0.
    case expired
    /// 308: Google holds bytes `0..<nextByte`.
    case incomplete(nextByte: Int64)
    /// 200/201: the file is complete.
    case complete
}

/// The private inbox folder in use after `ensureFolder`.
public struct DriveFolderResolution: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The stored folder is valid and was kept.
        case reused
        /// The folder was created (first run, or a stored ID never created remotely).
        case created
        /// The stored folder was trashed, not a capture inbox or from another device:
        /// a new folder replaced it. The worker's pinned `folder_id` must be updated.
        case replaced(previousID: String)
    }

    public var id: String
    public var outcome: Outcome

    public init(id: String, outcome: Outcome) {
        self.id = id
        self.outcome = outcome
    }
}

/// Drive v3 client for the private capture inbox. Port of `DriveApi.java`.
///
/// Every request goes through `HTTPTransport` after the endpoint allowlist. The token
/// is only ever placed in the `Authorization` header and is never logged; session URIs
/// are capabilities and never appear in errors.
public final class DriveClient: Sendable {
    /// Returns a bearer token. `forceRefresh` is true after a 401, so a stale cached
    /// token can be replaced once. Throw `DriveError.needsReauthorization` when the
    /// grant is revoked; other errors are reported as `.tokenUnavailable`.
    public typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    /// Google requires upload chunks in multiples of 256 KiB (except the last one).
    public static let chunkGranularity: Int64 = 256 * 1024
    /// 1 MiB, like the Android uploader.
    public static let defaultChunkSize: Int64 = 1024 * 1024
    /// `DriveApi.read` refuses Google replies above 256 KiB.
    public static let maxResponseBytes = 262_144

    public let chunkSize: Int64
    private let transport: any HTTPTransport
    private let tokenProvider: TokenProvider

    /// `chunkSize` is rounded down to a multiple of 256 KiB (minimum 256 KiB).
    public init(transport: any HTTPTransport, chunkSize: Int64 = DriveClient.defaultChunkSize, token: @escaping TokenProvider) {
        self.transport = transport
        self.tokenProvider = token
        let granularity = Self.chunkGranularity
        self.chunkSize = max(granularity, (chunkSize / granularity) * granularity)
    }

    // MARK: - Files

    public func generateID() async throws -> String {
        let response = try await send("GET", DriveEndpoint.generateIDs)
        try Self.requireSuccess(response)
        struct Reply: Decodable { let ids: [String] }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response.body),
              let id = reply.ids.first, WorkerContract.isDriveIdentifier(id)
        else { throw DriveError.invalidResponse }
        return id
    }

    /// Metadata with `DriveMetadata.fields`, or nil when Drive answers 404.
    public func metadata(id: String) async throws -> DriveFileMetadata? {
        guard WorkerContract.isDriveIdentifier(id) else { throw DriveError.invalidIdentifier }
        let response = try await send("GET", DriveEndpoint.metadata(id: id))
        if response.status == 404 { return nil }
        try Self.requireSuccess(response)
        return try DriveFileMetadata.decode(response.body)
    }

    // MARK: - Folder

    /// Reuses the stored inbox folder when it is still a valid, private capture inbox
    /// of this device; otherwise creates one.
    ///
    /// - A stored ID that Drive does not know (404) is created with that same ID, as on
    ///   Android: the ID was generated and persisted before a creation that never landed.
    /// - A stored folder that is shared or not owned by this account is refused with
    ///   `.invalidPrivateFolder` (needs human review; nothing is created).
    /// - A stored folder that is trashed, not a folder, not a capture inbox or from
    ///   another device is replaced by a new folder.
    ///
    /// A new ID is handed to `persistNewID` before the folder is created, so a crash
    /// between both steps cannot leave an orphan inbox that the phone forgot about.
    public func ensureFolder(
        existingID: String?, deviceID: String,
        persistNewID: @Sendable (String) async throws -> Void
    ) async throws -> DriveFolderResolution {
        guard Self.isValidDeviceID(deviceID) else { throw DriveError.invalidDeviceID }
        var previousID: String?
        if let existingID {
            guard WorkerContract.isDriveIdentifier(existingID) else { throw DriveError.invalidIdentifier }
            if let meta = try await metadata(id: existingID) {
                switch Self.evaluateFolder(meta, id: existingID, deviceID: deviceID) {
                case .usable: return DriveFolderResolution(id: existingID, outcome: .reused)
                case .notPrivate: throw DriveError.invalidPrivateFolder
                case .unusable: previousID = existingID
                }
            } else if try await createFolder(id: existingID, deviceID: deviceID),
                      let meta = try await metadata(id: existingID) {
                switch Self.evaluateFolder(meta, id: existingID, deviceID: deviceID) {
                case .usable: return DriveFolderResolution(id: existingID, outcome: .created)
                case .notPrivate: throw DriveError.invalidPrivateFolder
                case .unusable: previousID = existingID
                }
            } else {
                previousID = existingID
            }
        }
        let newID = try await generateID()
        try await persistNewID(newID)
        guard try await createFolder(id: newID, deviceID: deviceID),
              let meta = try await metadata(id: newID),
              Self.evaluateFolder(meta, id: newID, deviceID: deviceID) == .usable
        else { throw DriveError.invalidPrivateFolder }
        return DriveFolderResolution(id: newID, outcome: previousID.map { .replaced(previousID: $0) } ?? .created)
    }

    /// POST the folder metadata. Returns false when Drive refuses that ID with a plain
    /// client error (the caller then picks a fresh ID); 409 means it already exists.
    private func createFolder(id: String, deviceID: String) async throws -> Bool {
        let response = try await send(
            "POST", DriveEndpoint.createFile,
            headers: ["Content-Type": "application/json; charset=UTF-8"],
            body: .data(DriveMetadata.folderJSON(id: id, deviceID: deviceID))
        )
        if Self.isSuccess(response.status) || response.status == 409 { return true }
        let error = DriveError.from(response)
        if case .failed(let status) = error, (400..<500).contains(status) { return false }
        throw error
    }

    enum FolderVerdict: Equatable { case usable, notPrivate, unusable }

    static func evaluateFolder(_ meta: DriveFileMetadata, id: String, deviceID: String) -> FolderVerdict {
        if meta.trashed == true || meta.mimeType != DriveMetadata.folderMimeType { return .unusable }
        if meta.shared != false || meta.ownedByMe != true { return .notPrivate }
        guard meta.trashed == false, meta.id == id,
              meta.properties[DriveMetadata.inboxPropertyKey] == "1",
              meta.properties[DriveMetadata.devicePropertyKey] == deviceID,
              (try? WorkerContract.verifyFolder(meta, expected: id)) != nil
        else { return .unusable }
        return .usable
    }

    /// A UUID-like opaque string: `[A-Za-z0-9._-]{1,128}`.
    public static func isValidDeviceID(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (1...128).contains(scalars.count) else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-", ".": return true
            default: return false
            }
        }
    }

    // MARK: - Resumable upload

    /// Starts a resumable session and returns its (allowlisted) session URI.
    public func beginUpload(_ upload: DriveUpload, folderID: String) async throws -> URL {
        guard WorkerContract.isDriveIdentifier(upload.fileID), WorkerContract.isDriveIdentifier(folderID) else {
            throw DriveError.invalidIdentifier
        }
        guard UploadEligibility.isUploadableName(upload.name) else { throw DriveError.invalidFileName }
        let response = try await send(
            "POST", DriveEndpoint.resumableUpload,
            headers: [
                "Content-Type": "application/json; charset=UTF-8",
                "X-Upload-Content-Type": DriveMetadata.audioMimeType,
                "X-Upload-Content-Length": String(upload.checksums.bytes),
            ],
            body: .data(DriveMetadata.fileJSON(
                id: upload.fileID, name: upload.name, folderID: folderID, sha256: upload.checksums.sha256
            ))
        )
        try Self.requireSuccess(response)
        guard let location = response.header("location"), let session = URL(string: location) else {
            throw DriveError.missingUploadSession
        }
        try DriveEndpoint.validate(session)
        return session
    }

    /// Asks Google how many bytes it holds (`Content-Range: bytes */<size>`).
    public func uploadStatus(session: URL, totalBytes: Int64) async throws -> ResumableUploadStatus {
        let response = try await send("PUT", session, headers: ["Content-Range": "bytes */\(totalBytes)"], body: .data(Data()))
        switch response.status {
        case 404, 410: return .expired
        case 200, 201: return .complete
        case 308: return .incomplete(nextByte: try Self.nextByte(from: response.header("range"), totalBytes: totalBytes))
        default:
            if Self.isSuccess(response.status) { throw DriveError.invalidResponse }
            throw DriveError.from(response)
        }
    }

    /// PUTs `range` of the file. 308 reports Google's persisted range; 200/201 completes.
    public func uploadChunk(session: URL, fileURL: URL, range: Range<Int64>, totalBytes: Int64) async throws -> ResumableUploadStatus {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= totalBytes else {
            throw DriveError.invalidUploadRange
        }
        let response = try await send(
            "PUT", session,
            headers: [
                "Content-Type": DriveMetadata.audioMimeType,
                "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalBytes)",
            ],
            body: .file(fileURL, range: range)
        )
        switch response.status {
        case 200, 201: return .complete
        case 308: return .incomplete(nextByte: try Self.nextByte(from: response.header("range"), totalBytes: totalBytes))
        case 404, 410: throw DriveError.sessionExpired
        default: throw DriveError.from(response)
        }
    }

    /// Uploads the whole file, resuming `session` when Google still holds it.
    ///
    /// `sessionChanged` is called with every new session URI (and nil when one is
    /// dropped) so the caller can persist it sealed. `checkpoint` runs before every
    /// chunk with the bytes Google already holds; throw from it to stop (cancellation,
    /// network policy). An expired session is restarted once per call.
    public func upload(
        _ upload: DriveUpload, folderID: String, session existing: URL?,
        sessionChanged: @Sendable (URL?) async throws -> Void,
        checkpoint: @Sendable (_ confirmedBytes: Int64) async throws -> Void
    ) async throws {
        let total = upload.checksums.bytes
        guard total > 0 else { throw DriveError.invalidUploadRange }
        var session = existing
        if let stored = session, !DriveEndpoint.isAllowed(stored) {
            // Never send the token to a tampered stored URI; start over instead.
            session = nil
            try await sessionChanged(nil)
        }
        var restarted = false
        while true {
            var position: Int64 = 0
            if let current = session {
                switch try await uploadStatus(session: current, totalBytes: total) {
                case .complete: return
                case .incomplete(let next): position = next
                case .expired:
                    session = nil
                    try await sessionChanged(nil)
                }
            }
            let active: URL
            if let current = session {
                active = current
            } else {
                active = try await beginUpload(upload, folderID: folderID)
                session = active
                try await sessionChanged(active)
                position = 0
            }
            do {
                if try await sendChunks(of: upload, session: active, from: position, checkpoint: checkpoint) { return }
                // Every byte was accepted but no completion arrived: confirm explicitly.
                if try await uploadStatus(session: active, totalBytes: total) == .complete { return }
                throw DriveError.uploadNoProgress
            } catch DriveError.sessionExpired where !restarted {
                restarted = true
                session = nil
                try await sessionChanged(nil)
            }
        }
    }

    /// Returns true when Google reported the upload complete.
    private func sendChunks(
        of upload: DriveUpload, session: URL, from start: Int64,
        checkpoint: @Sendable (Int64) async throws -> Void
    ) async throws -> Bool {
        let total = upload.checksums.bytes
        var position = start
        while position < total {
            try await checkpoint(position)
            let end = min(total, position + chunkSize)
            switch try await uploadChunk(session: session, fileURL: upload.fileURL, range: position..<end, totalBytes: total) {
            case .complete:
                return true
            case .incomplete(let next):
                guard next > position else { throw DriveError.uploadNoProgress }
                position = next
            case .expired:
                throw DriveError.sessionExpired
            }
        }
        return false
    }

    // MARK: - Verification

    /// Port of `DriveApi.verified` plus the worker's own acceptance rules.
    ///
    /// Returns false when the file does not exist yet (or only its metadata does);
    /// throws when a remote copy exists but is not private or does not match.
    public func verifyUpload(_ upload: DriveUpload, folderID: String) async throws -> Bool {
        guard let meta = try await metadata(id: upload.fileID) else { return false }
        if meta.trashed == true || meta.shared == true || meta.ownedByMe != true {
            throw DriveError.remoteFileNotPrivate
        }
        let parent = meta.parents.contains(folderID)
        let expectedKind = CaptureKind.from(fileName: upload.name)
        if expectedKind != .ambientAudio,
           meta.properties[DriveMetadata.captureKindPropertyKey] != expectedKind.rawValue {
            throw DriveError.remoteNoteKindMismatch
        }
        let remoteSHA = meta.properties[DriveMetadata.sha256PropertyKey]
        let matches = SyncPolicy.verified(
            localBytes: upload.checksums.bytes, localMD5: upload.checksums.md5, localSHA: upload.checksums.sha256,
            remoteBytes: meta.size ?? -1, remoteMD5: meta.md5Checksum, remoteSHA: remoteSHA,
            correctParent: parent
        )
        guard matches else {
            // Metadata without content yet: still pending, not a mismatch.
            if (meta.size ?? 0) == 0, (meta.md5Checksum ?? "").isEmpty, parent, remoteSHA == upload.checksums.sha256 {
                return false
            }
            throw DriveError.remoteReceiptMismatch
        }
        do {
            try WorkerContract.verifyAudio(meta, folderID: folderID)
        } catch let rejection as WorkerContract.Rejection {
            throw DriveError.workerWouldReject(rejection)
        }
        return true
    }

    // MARK: - Transport

    private func send(
        _ method: String, _ url: URL, headers: [String: String] = [:], body: HTTPRequest.Body = .none
    ) async throws -> HTTPResponse {
        try DriveEndpoint.validate(url)
        var response = try await perform(method, url, headers: headers, body: body, forceRefresh: false)
        if response.status == 401 {
            response = try await perform(method, url, headers: headers, body: body, forceRefresh: true)
            if response.status == 401 { throw DriveError.needsReauthorization }
        }
        guard response.body.count <= Self.maxResponseBytes else { throw DriveError.oversizedResponse }
        return response
    }

    private func perform(
        _ method: String, _ url: URL, headers: [String: String], body: HTTPRequest.Body, forceRefresh: Bool
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var allHeaders = headers
        allHeaders["Authorization"] = "Bearer " + (try await accessToken(forceRefresh: forceRefresh))
        do {
            return try await transport.send(HTTPRequest(method: method, url: url, headers: allHeaders, body: body))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DriveError {
            throw error
        } catch {
            // Transport errors (e.g. URLError) can carry the session URI: never pass them on.
            if Task.isCancelled { throw CancellationError() }
            throw DriveError.connectionFailed
        }
    }

    private func accessToken(forceRefresh: Bool) async throws -> String {
        let token: String
        do {
            token = try await tokenProvider(forceRefresh)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DriveError {
            throw error
        } catch {
            throw DriveError.tokenUnavailable
        }
        // Visible ASCII only: no header injection, no empty bearer.
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw DriveError.needsReauthorization
        }
        return token
    }

    private static func isSuccess(_ status: Int) -> Bool { (200..<300).contains(status) }

    private static func requireSuccess(_ response: HTTPResponse) throws {
        guard isSuccess(response.status) else { throw DriveError.from(response) }
    }

    /// `Range: bytes=0-N` means Google holds N+1 bytes. Absent means none.
    static func nextByte(from range: String?, totalBytes: Int64) throws -> Int64 {
        guard let range else { return 0 }
        let prefix = "bytes=0-"
        guard range.hasPrefix(prefix) else { throw DriveError.invalidUploadRange }
        let digits = range.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let last = Int64(digits), last < Int64.max
        else { throw DriveError.invalidUploadRange }
        let next = last + 1
        guard next <= totalBytes else { throw DriveError.invalidUploadRange }
        return next
    }
}
