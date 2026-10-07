import Foundation
import os
import UserNotifications

/// Whether the person lets Captura show notices.
enum NoticePermission: Equatable, Sendable {
    case undetermined
    case allowed
    case denied
}

/// The local notification shown when recording pauses or stops while Captura is not on
/// screen. Spanish text only; it never contains anything recorded or a file name.
struct PauseNotice: Equatable, Sendable {
    let title: String
    let body: String

    static let pausedTitle = "Captura se pausó"
    static let stoppedTitle = "Captura dejó de grabar"
    static let openTheApp = "Abrí la app para seguir grabando."

    init(_ reason: RecorderPauseReason) {
        switch reason {
        case .interrupted:
            title = Self.pausedTitle
            body = "Una llamada, Siri u otra app tomó el micrófono. " + Self.openTheApp
        case .waitingForTheApp:
            title = Self.pausedTitle
            body = Self.openTheApp
        case .inputLost:
            title = Self.pausedTitle
            body = "Se desconectó el micrófono. " + Self.openTheApp
        case .microphoneLost:
            title = Self.stoppedTitle
            body = "Se perdió el micrófono. " + Self.openTheApp
        case .lowStorage:
            title = Self.stoppedTitle
            body = "Queda poco espacio en el iPhone. Lo grabado quedó guardado; liberá espacio y abrí la app para seguir grabando."
        case .writeFailed:
            title = Self.stoppedTitle
            body = "No se pudo guardar el audio. " + Self.openTheApp
        }
    }
}

/// Shows the pause notice. Local notifications only: no push, no entitlement and no
/// paid capability, so they work with a free Apple ID (Personal Team).
@MainActor
protocol PauseNotifying: AnyObject {
    /// The current choice, without asking.
    func permission() async -> NoticePermission
    /// Shows the system prompt. Only called while `permission()` is `.undetermined`.
    func requestPermission() async -> NoticePermission
    /// Shows `notice` now, replacing an earlier pause notice.
    func post(_ notice: PauseNotice)
    /// Removes the pause notice from Notification Center (no-op when there is none).
    func withdraw()
}

/// `UNUserNotificationCenter` with one fixed identifier, so Notification Center holds at
/// most one Captura pause notice. Posted only while the app is not on screen, so no
/// foreground presentation delegate is needed; tapping it opens the app.
final class SystemPauseNotifier: PauseNotifying {
    static let identifier = "org.example.captura.recording-paused"

    private let log = Logger(subsystem: "org.example.captura", category: "pause-notice")
    private var center: UNUserNotificationCenter { .current() }

    func permission() async -> NoticePermission {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: return .undetermined
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func requestPermission() async -> NoticePermission {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound]) ? .allowed : .denied
        } catch {
            log.info("Notice permission request failed: \(LogPrivacy.publicSummary(of: error), privacy: .public)")
            return .denied
        }
    }

    func post(_ notice: PauseNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = Self.identifier
        // The default `.active` level: time-sensitive notices need a paid capability.
        // No trigger: delivered right away, before iOS can suspend the app.
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        let log = self.log
        center.add(request) { error in
            // Notices turned off in Ajustes: iOS refuses quietly and recording is unaffected.
            if let error {
                log.info("Pause notice not shown: \(LogPrivacy.publicSummary(of: error), privacy: .public)")
            }
        }
    }

    func withdraw() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }
}
