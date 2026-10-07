import Foundation

/// Every way linking or using the Google account can fail. Each case carries a Spanish,
/// actionable `userMessage`; none of them includes tokens or codes.
public enum GoogleAuthError: Error, Equatable, Sendable {
    /// The person closed the Google sheet.
    case cancelled
    /// The person pressed "Cancel" on Google's consent screen (`error=access_denied`).
    case accessDenied
    /// Google redirected back with another OAuth error code.
    case authorizationFailed(code: String)
    /// The callback does not belong to this app's redirect URI.
    case invalidCallback
    /// The callback `state` differs from the one this app sent.
    case stateMismatch
    case missingAuthorizationCode
    /// The sign-in sheet could not be shown.
    case presentationFailed
    case endpointNotAllowed(String)
    /// The token endpoint answered `invalid_grant` (expired, revoked or reused grant).
    case invalidGrant
    /// Any other token-endpoint failure.
    case tokenRequestFailed(status: Int, error: String?)
    case malformedTokenResponse
    case missingRefreshToken
    /// The person unticked the Google Drive permission on the consent screen.
    case driveScopeNotGranted
    case invalidIDToken
    case missingEmail
    case unverifiedEmail
    case hostedDomainMismatch(expected: String, actual: String?)
    /// Revocation failed for a reason other than "already revoked".
    case revocationFailed(status: Int)
    /// No account is linked on this device.
    case signedOut
    /// The stored grant stopped working; the account was unlinked locally.
    case reauthenticationRequired

    public var userMessage: String {
        switch self {
        case .cancelled:
            return "Cancelaste la vinculación con Google. No se subió ningún audio."
        case .accessDenied:
            return "No diste permiso en Google. No se subió ningún audio."
        case .authorizationFailed(let code) where code == "admin_policy_enforced":
            return "El administrador de tu Google Workspace no permite esta app. Pedile que la habilite o usá otra cuenta."
        case .authorizationFailed:
            return "Google no autorizó la conexión. Revisá el cliente OAuth iOS en Google Cloud y volvé a intentar."
        case .invalidCallback, .stateMismatch, .missingAuthorizationCode:
            return "La respuesta de Google no era válida, así que no se vinculó nada. Volvé a intentar."
        case .presentationFailed:
            return "No se pudo abrir la pantalla de Google. Volvé a intentar con la app abierta."
        case .endpointNotAllowed:
            return "Se bloqueó una dirección que no es de Google. No se envió ningún dato."
        case .invalidGrant, .reauthenticationRequired:
            return "Google pidió volver a vincular la cuenta. Tocá «Vincular Drive»."
        case .tokenRequestFailed(_, let error) where error == "invalid_client" || error == "unauthorized_client":
            return "Google no reconoce el ID de cliente (\(GoogleOAuthConfiguration.BuildSetting.clientID)). Pedí el ID del cliente iOS actual, corré \(GoogleOAuthConfiguration.BuildSetting.setupCommand) --force en la Mac (\(GoogleOAuthConfiguration.BuildSetting.setupStep)) y volvé a instalar la app."
        case .tokenRequestFailed:
            return "Google respondió con un error. Volvé a intentar en unos minutos."
        case .malformedTokenResponse:
            return "Google devolvió una respuesta inesperada. Volvé a intentar."
        case .missingRefreshToken:
            return "Google no entregó un permiso duradero. Desvinculá y volvé a vincular la cuenta."
        case .driveScopeNotGranted:
            return "Falta el permiso de Google Drive. Volvé a vincular y marcá la casilla de Drive."
        case .invalidIDToken:
            return "No se pudo confirmar la cuenta de Google. Volvé a intentar."
        case .missingEmail, .unverifiedEmail:
            return "La cuenta de Google no tiene un correo verificado. Usá otra cuenta."
        case .hostedDomainMismatch(let expected, _):
            return "Esa cuenta no es de \(expected). Elegí una cuenta de \(expected)."
        case .revocationFailed:
            return "Se desvinculó en este iPhone, pero Google no confirmó el cierre. Podés quitar el acceso desde tu cuenta de Google."
        case .signedOut:
            return "Drive todavía no vinculado."
        }
    }

    /// Spanish message for any error raised while linking or syncing.
    public static func userMessage(for error: Error) -> String {
        switch error {
        case let auth as GoogleAuthError:
            return auth.userMessage
        case let configuration as GoogleOAuthConfigurationError:
            return configuration.userMessage
        case is URLError:
            return "No hay conexión con Google. Revisá la red y volvé a intentar."
        default:
            return "No se pudo completar la vinculación con Google. Volvé a intentar."
        }
    }
}
