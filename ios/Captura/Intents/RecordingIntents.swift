import AppIntents
import Foundation

/// "Grabar con Captura" for Shortcuts, Siri and the Action Button.
///
/// It opens the app before recording: iOS does not let an app start the microphone
/// from the background, and the visible screen keeps the recording obvious to the
/// person (`AGENTS.md`: explicit consent, visible recording). `AudioRecordingIntent`
/// would allow starting without opening the app, but only together with a Live
/// Activity, which this first version does not have. App Intents need no Siri
/// capability, so this works with a free Apple ID (Personal Team).
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Grabar con Captura"
    static let description = IntentDescription("Abre Captura y empieza a grabar. La grabación se ve en pantalla; avisá a las personas antes de grabar.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppModel.shared.startRecordingFromIntent()
        return .result()
    }
}

/// "Detener Captura": stops and saves without opening the app. Stopping never needs
/// consent, and the closed chunk is queued like after tapping Detener.
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Detener Captura"
    static let description = IntentDescription("Detiene la grabación de Captura y guarda el audio en el iPhone.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stopped = await AppModel.shared.stopRecording()
        return .result(dialog: stopped ? "Grabación detenida. El audio quedó en el iPhone." : "Captura no estaba grabando.")
    }
}

struct CapturaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Grabar con \(.applicationName)",
                "Empezar a grabar con \(.applicationName)",
            ],
            shortTitle: "Grabar",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Detener \(.applicationName)",
                "Detener la grabación de \(.applicationName)",
            ],
            shortTitle: "Detener",
            systemImageName: "stop.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .grayGreen
}
