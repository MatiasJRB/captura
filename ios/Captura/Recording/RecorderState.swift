import Foundation
import CapturaCore

/// Visible recorder state. Recording is always user-started and shown on screen.
enum RecorderState: Equatable, Sendable {
    case idle
    /// `startedAt` is when the user pressed Grabar; `chunkStartedAt` is when the
    /// chunk currently being written began.
    case recording(startedAt: Date, chunkStartedAt: Date)
    /// The user wants to record, but the system took the microphone (a call, Siri,
    /// another app) or the input disappeared. Nothing is being saved.
    case interrupted
    case failed(message: String)

    var phase: RecorderPhase {
        switch self {
        case .idle: return .idle
        case .recording: return .recording
        case .interrupted: return .interrupted
        case .failed: return .failed
        }
    }

    var isRecording: Bool { phase == .recording }
}

/// Microphone permission as the UI needs it: `.denied` means "send the user to Ajustes".
enum MicrophonePermission: Equatable, Sendable {
    case undetermined
    case granted
    case denied
}

enum RecorderError: LocalizedError, Equatable {
    case microphoneDenied
    case mustStartInForeground
    case noInputAvailable
    case storageUnavailable
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Captura no tiene permiso para usar el micrófono. Activalo en Ajustes > Captura > Micrófono."
        case .mustStartInForeground:
            return "Abrí Captura para empezar a grabar."
        case .noInputAvailable:
            return "No hay un micrófono disponible."
        case .storageUnavailable:
            return "No se pudo preparar la carpeta de grabaciones."
        case .couldNotStart:
            return "No se pudo iniciar la grabación. Probá de nuevo."
        }
    }
}

enum RecorderMessages {
    static let writeFailed = "No se pudo guardar el audio. Revisá el espacio libre y volvé a tocar Grabar."
    static let resumeFailed = "La grabación quedó interrumpida. Tocá Grabar para seguir."
    static let restartFailed = "Se perdió el micrófono. Tocá Grabar para seguir."
}
