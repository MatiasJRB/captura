import Foundation

/// Drive metadata written by the phone, field for field as `DriveApi.java` writes it.
/// The worker finds the inbox and audios only through these properties.
public enum DriveMetadata {
    public static let folderMimeType = "application/vnd.google-apps.folder"
    public static let audioMimeType = "audio/mp4"
    public static let inboxPropertyKey = "personalCaptureInbox"
    public static let audioPropertyKey = "personalCaptureAudio"
    public static let devicePropertyKey = "device"
    public static let sha256PropertyKey = "sha256"
    public static let captureKindPropertyKey = "captureKind"
    /// Same `fields` selector as `DriveApi.metadata` and `worker.FIELDS`.
    public static let fields = "id,name,mimeType,size,md5Checksum,parents,properties,shared,ownedByMe,trashed"

    /// `{id, name, mimeType, properties: {personalCaptureInbox: "1", device}}`.
    public static func folder(id: String, deviceID: String) -> [String: Any] {
        [
            "id": id,
            "name": CaptureNaming.folderName,
            "mimeType": folderMimeType,
            "properties": [inboxPropertyKey: "1", devicePropertyKey: deviceID],
        ]
    }

    /// `{id, name, mimeType, parents: [folder], properties: {personalCaptureAudio: "1", sha256, captureKind}}`.
    /// The capture kind is derived from the name, never chosen by the caller.
    public static func file(id: String, name: String, folderID: String, sha256: String) -> [String: Any] {
        [
            "id": id,
            "name": name,
            "mimeType": audioMimeType,
            "parents": [folderID],
            "properties": [
                audioPropertyKey: "1",
                sha256PropertyKey: sha256,
                captureKindPropertyKey: CaptureKind.from(fileName: name).rawValue,
            ],
        ]
    }

    public static func folderJSON(id: String, deviceID: String) -> Data {
        encode(folder(id: id, deviceID: deviceID))
    }

    public static func fileJSON(id: String, name: String, folderID: String, sha256: String) -> Data {
        encode(file(id: id, name: name, folderID: folderID, sha256: sha256))
    }

    static func encode(_ object: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            // Only string values are ever passed in, which JSONSerialization always accepts.
            preconditionFailure("drive metadata must be JSON-serializable")
        }
    }
}

/// Metadata returned by `files.get` with `DriveMetadata.fields`. Decoding is lenient:
/// a missing or malformed field becomes nil/empty and then fails the explicit checks.
public struct DriveFileMetadata: Decodable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var mimeType: String?
    /// Drive encodes int64 values as JSON strings; numbers are accepted too.
    public var size: Int64?
    public var md5Checksum: String?
    public var parents: [String]
    public var properties: [String: String]
    public var shared: Bool?
    public var ownedByMe: Bool?
    public var trashed: Bool?

    public init(
        id: String? = nil, name: String? = nil, mimeType: String? = nil, size: Int64? = nil,
        md5Checksum: String? = nil, parents: [String] = [], properties: [String: String] = [:],
        shared: Bool? = nil, ownedByMe: Bool? = nil, trashed: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.md5Checksum = md5Checksum
        self.parents = parents
        self.properties = properties
        self.shared = shared
        self.ownedByMe = ownedByMe
        self.trashed = trashed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mimeType, size, md5Checksum, parents, properties, shared, ownedByMe, trashed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        mimeType = try? container.decodeIfPresent(String.self, forKey: .mimeType)
        if let text = try? container.decodeIfPresent(String.self, forKey: .size) {
            size = Int64(text)
        } else {
            size = try? container.decodeIfPresent(Int64.self, forKey: .size)
        }
        md5Checksum = try? container.decodeIfPresent(String.self, forKey: .md5Checksum)
        parents = (try? container.decodeIfPresent([String].self, forKey: .parents)) ?? []
        properties = (try? container.decodeIfPresent([String: String].self, forKey: .properties)) ?? [:]
        shared = try? container.decodeIfPresent(Bool.self, forKey: .shared)
        ownedByMe = try? container.decodeIfPresent(Bool.self, forKey: .ownedByMe)
        trashed = try? container.decodeIfPresent(Bool.self, forKey: .trashed)
    }

    public static func decode(_ data: Data) throws -> DriveFileMetadata {
        do {
            return try JSONDecoder().decode(DriveFileMetadata.self, from: data)
        } catch {
            throw DriveError.invalidResponse
        }
    }
}
