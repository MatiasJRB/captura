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

/// Why recording paused or stopped although the person did not ask for it.
enum RecorderPauseReason: Equatable, Sendable {
    /// A call, Siri or another app took the audio. It may continue by itself.
    case interrupted
    /// The interruption is over (or iOS refused to restart the microphone in the
    /// background): the recording cannot continue until the person opens the app.
    case waitingForTheApp
    /// The input in use disappeared and there is no other input.
    case inputLost
    /// Capture could not restart on the current route (route change, audio reset).
    case microphoneLost
    /// Stopped before the disk filled up; what was recorded is kept.
    case lowStorage
    case writeFailed
}

/// Recording changes the person did not ask for. The app tells the person about them
/// while Captura is not on screen, where the status card cannot be seen.
enum RecorderPauseEvent: Equatable, Sendable {
    case paused(RecorderPauseReason)
    /// The recording continued by itself after a pause.
    case continued
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
    /// Less free space than `RecordingSpace.minimumToStart`.
    case lowStorage
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
        case .lowStorage:
            return "Queda poco espacio en el iPhone. Liberá espacio para grabar (hacen falta al menos 200 MB)."
        case .couldNotStart:
            return "No se pudo iniciar la grabación. Probá de nuevo."
        }
    }
}

enum RecorderMessages {
    static let writeFailed = "No se pudo guardar el audio. Revisá el espacio libre y volvé a tocar Grabar."
    static let resumeFailed = "La grabación quedó interrumpida. Tocá Grabar para seguir."
    static let restartFailed = "Se perdió el micrófono. Tocá Grabar para seguir."
    /// The interrupted card. iOS may not let the recording continue by itself (an
    /// interruption can end without "should resume", or end while the app is
    /// suspended), so it must not promise that it will.
    static let interruptedTitle = "En pausa · no se está grabando"
    static let interruptedDetail = "Una llamada, Siri u otra app interrumpió el audio. A veces sigue sola al terminar, pero no siempre: si no ves «Grabando», tocá Reanudar."
    static let lowStorage = "La grabación se detuvo porque queda poco espacio en el iPhone. Lo grabado quedó guardado; liberá espacio y volvé a tocar Grabar."
}
