import Foundation

/// Fixed Google endpoints and the allowlist every request URL must pass, including
/// resumable session URIs returned by Google. Port of `DriveApi.safe`: the bearer
/// token is never sent to anything but `https://www.googleapis.com[:443]`.
public enum DriveEndpoint {
    public static let host = "www.googleapis.com"
    public static let api = URL(string: "https://www.googleapis.com/drive/v3/")!
    public static let generateIDs = URL(string: "https://www.googleapis.com/drive/v3/files/generateIds?count=1&space=drive&type=files")!
    public static let createFile = URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!
    public static let resumableUpload = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!

    /// https only, exact host, port 443 or none, no user info.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host == host,
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil
        else { return false }
        return true
    }

    public static func validate(_ url: URL) throws {
        guard isAllowed(url) else { throw DriveError.invalidEndpoint }
    }

    /// `files/<id>?fields=...`. The id must already be a validated Drive identifier.
    static func metadata(id: String) -> URL {
        URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?fields=\(DriveMetadata.fields)")!
    }
}
