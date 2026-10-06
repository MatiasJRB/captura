import CryptoKit
import Foundation

/// Byte count plus lowercase-hex SHA-256 and MD5 of one file.
///
/// SHA-256 is the integrity anchor stored in Drive `properties.sha256`; MD5 is only
/// compared with Drive's own `md5Checksum` receipt. The worker re-checks both after
/// download (`worker.validate_bytes`), so these values must match byte for byte.
public struct FileChecksums: Codable, Equatable, Hashable, Sendable {
    public var bytes: Int64
    public var sha256: String
    public var md5: String

    public init(bytes: Int64, sha256: String, md5: String) {
        self.bytes = bytes
        self.sha256 = sha256
        self.md5 = md5
    }
}

/// Streaming checksums in 64 KiB blocks, like `SyncQueue.prepare` and `worker.validate_bytes`.
public enum Checksums {
    public static let blockSize = 64 * 1024

    /// Reads the file once. Honors Task cancellation between blocks.
    public static func compute(fileAt url: URL) throws -> FileChecksums {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var bytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let block = try handle.read(upToCount: blockSize), !block.isEmpty else { break }
            sha.update(data: block)
            md5.update(data: block)
            bytes += Int64(block.count)
        }
        return FileChecksums(bytes: bytes, sha256: hex(sha.finalize()), md5: hex(md5.finalize()))
    }

    public static func compute(data: Data) -> FileChecksums {
        FileChecksums(
            bytes: Int64(data.count),
            sha256: hex(SHA256.hash(data: data)),
            md5: hex(Insecure.MD5.hash(data: data))
        )
    }

    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(64)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
