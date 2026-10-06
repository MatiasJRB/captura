import Foundation

/// Base64URL without padding (RFC 4648 §5), as used by PKCE and JWT segments.
enum OAuthBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        guard !text.contains("="), !text.contains("+"), !text.contains("/") else { return nil }
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

/// Strict percent-encoding for query strings and `application/x-www-form-urlencoded` bodies.
/// Only RFC 3986 unreserved characters stay literal, so `+`, `&`, `=`, `:` and `/` inside a
/// value can never change how Google parses the request.
enum OAuthFormEncoding {
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func escape(_ value: String) -> String {
        // Every Swift String is valid Unicode, so percent-encoding cannot fail here.
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Keeps the given order so requests are deterministic and easy to assert in tests.
    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    /// Parses a form body or query string. Returns `nil` for malformed percent-escapes.
    static func decode(_ text: String) -> [(String, String)]? {
        guard !text.isEmpty else { return [] }
        var pairs: [(String, String)] = []
        for part in text.split(separator: "&", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawName = String(pieces[0]).replacingOccurrences(of: "+", with: " ")
            let rawValue = pieces.count > 1 ? String(pieces[1]).replacingOccurrences(of: "+", with: " ") : ""
            guard let name = rawName.removingPercentEncoding,
                  let value = rawValue.removingPercentEncoding else { return nil }
            pairs.append((name, value))
        }
        return pairs
    }
}

/// Cryptographically secure random values for PKCE verifiers and OAuth `state`.
///
/// `SystemRandomNumberGenerator` is backed by the operating system CSPRNG
/// (`arc4random_buf` on Apple platforms), so it is suitable for secrets.
public enum OAuthRandom {
    public static func bytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return bytes(count: count, using: &generator)
    }

    public static func bytes<Generator: RandomNumberGenerator>(count: Int, using generator: inout Generator) -> [UInt8] {
        (0..<max(0, count)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// An opaque URL-safe token (Base64URL, no padding). 32 bytes give 43 characters.
    public static func urlSafeToken(byteCount: Int = 32) -> String {
        OAuthBase64URL.encode(Data(bytes(count: byteCount)))
    }
}
