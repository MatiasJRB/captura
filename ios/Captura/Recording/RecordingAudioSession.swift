import AVFoundation
import CapturaCore
import UIKit

/// The slice of `AVAudioSession` / `AVAudioApplication` the recorder needs,
/// so the controller can be tested without a microphone.
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
        let info = notification.userInfo ?? [:]
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
            switch type {
            case .began:
                return .interruptionBegan
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                return .interruptionEnded(shouldResume: options.contains(.shouldResume))
            @unknown default:
                return nil
            }
        case AVAudioSession.routeChangeNotification:
            guard let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return nil }
            let cause: RouteChangeCause
            switch reason {
            case .oldDeviceUnavailable: cause = .inputDeviceLost
            case .noSuitableRouteForCategory: cause = .noSuitableRoute
            default: cause = .other
            }
            return .routeChanged(cause, inputAvailable: inputAvailable)
        case AVAudioSession.mediaServicesWereResetNotification:
            return .mediaServicesReset
        case UIApplication.didBecomeActiveNotification:
            return .becameActive
        default:
            return nil
        }
    }
}
