import AVFoundation
import CapturaCore
import UIKit

/// The slice of `AVAudioSession` / `AVAudioApplication` the recorder needs,
/// so the controller can be tested without a microphone.
@MainActor
protocol RecordingAudioSession: AnyObject {
    var permission: MicrophonePermission { get }
    func requestPermission() async -> MicrophonePermission
    var isInputAvailable: Bool { get }
    func activateForRecording() throws
    func deactivate()
}

final class SystemRecordingAudioSession: RecordingAudioSession {
    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    var permission: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    func requestPermission() async -> MicrophonePermission {
        await AVAudioApplication.requestRecordPermission() ? .granted : .denied
    }

    var isInputAvailable: Bool { session.isInputAvailable }

    /// Category `.record`: input only, silences nothing else in the app and keeps
    /// recording with the screen locked thanks to `UIBackgroundModes = audio`.
    ///
    /// Mode `.default` rather than `.measurement`: like Android's
    /// `MediaRecorder.AudioSource.MIC`, it keeps the platform's standard input gain,
    /// so quiet or distant speech stays loud enough for whisper.cpp. `.measurement`
    /// disables that dynamics processing and is meant for acoustic measurement.
    /// No Bluetooth options: the built-in (or wired) microphone is what the user sees.
    func activateForRecording() throws {
        try session.setCategory(.record, mode: .default, options: [])
        // Ringtones and alerts should not cut a recording; a call that is answered
        // still interrupts it, and the recorder handles that interruption.
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Translates system notifications into `AudioSessionEvent`s.
enum AudioSessionNotificationParser {
    static let observedNames: [Notification.Name] = [
        AVAudioSession.interruptionNotification,
        AVAudioSession.routeChangeNotification,
        AVAudioSession.mediaServicesWereResetNotification,
        UIApplication.didBecomeActiveNotification,
    ]

    static func event(from notification: Notification, inputAvailable: Bool) -> AudioSessionEvent? {
        pending(from: notification)?.resolve(inputAvailable: inputAvailable)
    }

    /// Parses everything except input availability, which the controller reads on
    /// the main actor when it handles the event.
    static func pending(from notification: Notification) -> PendingSessionEvent? {
        let info = notification.userInfo ?? [:]
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
            switch type {
            case .began:
                return .ready(.interruptionBegan)
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                return .ready(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
            @unknown default:
                return nil
            }
        case AVAudioSession.routeChangeNotification:
            guard let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return nil }
            switch reason {
            case .oldDeviceUnavailable: return .routeChanged(.inputDeviceLost)
            case .noSuitableRouteForCategory: return .routeChanged(.noSuitableRoute)
            default: return .routeChanged(.other)
            }
        case AVAudioSession.mediaServicesWereResetNotification:
            return .ready(.mediaServicesReset)
        case UIApplication.didBecomeActiveNotification:
            return .ready(.becameActive)
        default:
            return nil
        }
    }
}

enum PendingSessionEvent: Equatable, Sendable {
    case ready(AudioSessionEvent)
    case routeChanged(RouteChangeCause)

    func resolve(inputAvailable: Bool) -> AudioSessionEvent {
        switch self {
        case .ready(let event): return event
        case .routeChanged(let cause): return .routeChanged(cause, inputAvailable: inputAvailable)
        }
    }
}
