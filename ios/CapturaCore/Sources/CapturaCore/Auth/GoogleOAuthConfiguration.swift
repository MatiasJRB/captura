import Foundation

/// The Google "iOS" OAuth client this build talks to, read from Info.plist.
///
/// Values come from `ios/Config/Captura.local.xcconfig` through build settings. A fresh
/// clone ships placeholders, so loading never crashes: it returns a typed error whose
/// `userMessage` tells the person exactly which value to fill in.
///
/// Only the client ID is strictly required. The reversed client ID (the redirect URL
/// scheme) is derived from it when the build setting is empty or still a placeholder:
/// `ASWebAuthenticationSession` intercepts the callback scheme itself, so it does not
/// depend on the scheme being registered in `CFBundleURLTypes`.
public struct GoogleOAuthConfiguration: Equatable, Sendable {
    public enum InfoKey {
        public static let clientID = "CapturaGoogleClientID"
        public static let reversedClientID = "CapturaGoogleReversedClientID"
        public static let hostedDomain = "CapturaGoogleHostedDomain"
    }

    /// Build-setting names shown to the person in configuration messages.
    public enum BuildSetting {
        public static let file = "ios/Config/Captura.local.xcconfig"
        public static let clientID = "CAPTURA_GOOGLE_IOS_CLIENT_ID"
        public static let reversedClientID = "CAPTURA_GOOGLE_REVERSED_CLIENT_ID"
        public static let hostedDomain = "CAPTURA_GOOGLE_HOSTED_DOMAIN"
    }

    public static let clientIDSuffix = ".apps.googleusercontent.com"
    public static let reversedClientIDPrefix = "com.googleusercontent.apps."
    /// Path of the custom-scheme redirect. iOS redirect URIs use a single slash:
    /// `com.googleusercontent.apps.<id>:/oauth2redirect`.
    public static let redirectPath = "/oauth2redirect"
    /// Default from `Captura.base.xcconfig`, used when no local configuration exists.
    public static let baseDefaultReversedClientID = "org.example.captura.oauth"

    public let clientID: String
    public let reversedClientID: String
    /// Lower-cased Google Workspace domain, or `nil` to accept any Google account.
    public let hostedDomain: String?

    public init(clientID: String, reversedClientID: String? = nil, hostedDomain: String? = nil) throws(GoogleOAuthConfigurationError) {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw .missingClientID }
        guard !GoogleOAuthConfiguration.isPlaceholder(clientID) else { throw .placeholderClientID }
        guard let expectedReversed = GoogleOAuthConfiguration.reversedClientID(forClientID: clientID) else {
            throw .malformedClientID(clientID)
        }

        let reversed = (reversedClientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !reversed.isEmpty, !GoogleOAuthConfiguration.isPlaceholder(reversed),
           reversed.lowercased() != expectedReversed.lowercased() {
            throw .reversedClientIDMismatch(expected: expectedReversed)
        }

        self.clientID = clientID
        self.reversedClientID = expectedReversed
        self.hostedDomain = try GoogleOAuthConfiguration.normalizedHostedDomain(hostedDomain)
    }

    /// Reads the `CapturaGoogle*` keys from an Info.plist-style dictionary
    /// (for example `Bundle.main.infoDictionary`).
    public init(infoDictionary: [String: Any]) throws(GoogleOAuthConfigurationError) {
        try self.init(
            clientID: infoDictionary[InfoKey.clientID] as? String ?? "",
            reversedClientID: infoDictionary[InfoKey.reversedClientID] as? String,
            hostedDomain: infoDictionary[InfoKey.hostedDomain] as? String
        )
    }

    /// Non-throwing variant for UI code that wants to show "Falta configurar Google".
    public static func load(infoDictionary: [String: Any]?) -> Result<GoogleOAuthConfiguration, GoogleOAuthConfigurationError> {
        do {
            return .success(try GoogleOAuthConfiguration(infoDictionary: infoDictionary ?? [:]))
        } catch {
            return .failure(error)
        }
    }

    /// The custom URL scheme Google redirects to; also the `ASWebAuthenticationSession`
    /// callback scheme.
    public var callbackScheme: String { reversedClientID }

    /// Must match, character by character, the redirect URI sent in the token exchange.
    public var redirectURI: String { reversedClientID + ":" + GoogleOAuthConfiguration.redirectPath }

    /// `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`.
    /// Returns `nil` when the value is not shaped like a Google OAuth client ID.
    public static func reversedClientID(forClientID clientID: String) -> String? {
        let lowered = clientID.lowercased()
        guard lowered.hasSuffix(clientIDSuffix) else { return nil }
        let prefix = String(clientID.dropLast(clientIDSuffix.count))
        guard !prefix.isEmpty, prefix.unicodeScalars.allSatisfy(isClientIDCharacter) else { return nil }
        return reversedClientIDPrefix + prefix
    }

    /// Treats unexpanded build settings, the repository defaults and the example values
    /// as "not configured yet".
    static func isPlaceholder(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered.contains("$(") || lowered.contains("example") { return true }
        if lowered == baseDefaultReversedClientID { return true }
        // Example client IDs use an all-zero project number.
        let projectNumber = lowered
            .replacingOccurrences(of: reversedClientIDPrefix, with: "")
            .split(separator: "-", maxSplits: 1)
            .first ?? ""
        return !projectNumber.isEmpty && projectNumber.allSatisfy { $0 == "0" }
    }

    private static func isClientIDCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
        default: return false
        }
    }

    private static func normalizedHostedDomain(_ value: String?) throws(GoogleOAuthConfigurationError) -> String? {
        var domain = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.hasPrefix("@") { domain.removeFirst() }
        guard !domain.isEmpty else { return nil }
        guard !isPlaceholder(domain) else { throw .placeholderHostedDomain }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let wellFormed = labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { scalar in
                    switch scalar {
                    case "a"..."z", "0"..."9", "-": return true
                    default: return false
                    }
                }
        }
        guard wellFormed else { throw .malformedHostedDomain(domain) }
        return domain
    }
}

/// Why the Google configuration cannot be used yet. Each case carries a Spanish message
/// that names the exact build setting to change.
public enum GoogleOAuthConfigurationError: Error, Equatable, Sendable {
    case missingClientID
    case placeholderClientID
    case malformedClientID(String)
    case reversedClientIDMismatch(expected: String)
    case placeholderHostedDomain
    case malformedHostedDomain(String)

    public var userMessage: String {
        typealias Setting = GoogleOAuthConfiguration.BuildSetting
        switch self {
        case .missingClientID:
            return "Falta configurar Google: copiá ios/Config/Captura.local.example.xcconfig como Captura.local.xcconfig y completá \(Setting.clientID) con el ID de cliente iOS de tu proyecto de Google Cloud."
        case .placeholderClientID:
            return "Falta configurar Google: \(Setting.clientID) en \(Setting.file) todavía tiene el valor de ejemplo. Pegá el ID de cliente iOS de tu proyecto de Google Cloud."
        case .malformedClientID:
            return "El valor de \(Setting.clientID) no parece un ID de cliente de Google: tiene que terminar en .apps.googleusercontent.com. Copialo del cliente OAuth de tipo iOS."
        case .reversedClientIDMismatch(let expected):
            return "\(Setting.reversedClientID) no corresponde al ID de cliente. Dejalo vacío o poné exactamente: \(expected)"
        case .placeholderHostedDomain:
            return "\(Setting.hostedDomain) tiene un dominio de ejemplo. Dejalo vacío o poné el dominio de tu Google Workspace."
        case .malformedHostedDomain:
            return "\(Setting.hostedDomain) tiene que ser solo el dominio de Google Workspace (por ejemplo, tuempresa.com), sin @ ni https://."
        }
    }
}
