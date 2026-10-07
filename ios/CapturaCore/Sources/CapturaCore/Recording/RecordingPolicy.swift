import Foundation

// Platform-neutral recorder rules shared by the iOS capture engine and its tests.
// Mirrors android/src/org/example/captura/CaptureService.java: fixed-length chunks,
// a ".partial" file while writing, and no upload of anything that was not closed.

/// Frame-accurate chunk rotation. Rotation only happens *between* buffers, so the
/// buffer that crosses the limit opens the next chunk and no audio is dropped.
public struct ChunkRotation: Equatable, Sendable {
    /// Android `CaptureService.CHUNK_MS` (15 minutes).
    public static let defaultChunkDuration: TimeInterval = 15 * 60

    public let sampleRate: Double
    public let framesPerChunk: Int64
    /// Frames already admitted into the current chunk.
    public private(set) var framesInChunk: Int64 = 0

    public init(chunkDuration: TimeInterval = ChunkRotation.defaultChunkDuration, sampleRate: Double) {
        precondition(chunkDuration > 0, "chunkDuration must be positive")
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.sampleRate = sampleRate
        self.framesPerChunk = max(1, Int64((chunkDuration * sampleRate).rounded()))
    }

    /// Admits a buffer of `frames`. Returns `true` when the buffer would overflow a
    /// non-empty chunk: the caller must close the current chunk and write the buffer
    /// into a new one. The counters already include the admitted buffer.
    public mutating func admit(frames: Int64) -> Bool {
        precondition(frames >= 0, "frames must not be negative")
        let rotate = framesInChunk > 0 && framesInChunk + frames > framesPerChunk
        framesInChunk = rotate ? frames : framesInChunk + frames
        return rotate
    }

    /// Starts counting a fresh chunk (after a manual cut, a stop or an interruption).
    public mutating func reset() {
        framesInChunk = 0
    }

    public var durationInChunk: TimeInterval {
        Double(framesInChunk) / sampleRate
    }
}

/// Coarse recorder phase used to decide how to react to audio-session events.
public enum RecorderPhase: Equatable, Sendable {
    case idle
    case recording
    /// The user wants to record but the microphone is temporarily unavailable.
    case interrupted
    case failed
}

/// Why the audio route changed, reduced to what matters for capture.
public enum RouteChangeCause: Equatable, Sendable {
    /// The input in use disappeared (e.g. a headset with microphone was unplugged).
    case inputDeviceLost
    /// No route can satisfy the recording category (no input at all).
    case noSuitableRoute
    /// A new device appeared, an override or a configuration change. The engine
    /// reports a real format change separately, so these are not acted upon.
    case other
}

/// Audio-session level events, decoupled from AVFoundation so they can be tested anywhere.
public enum AudioSessionEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(RouteChangeCause, inputAvailable: Bool)
    case mediaServicesReset
    case engineConfigurationChanged
    /// The app came back to the foreground.
    case becameActive
}

/// What the recorder must do in response to an `AudioSessionEvent`.
public enum RecorderReaction: Equatable, Sendable {
    case ignore
    /// Close the current chunk cleanly and enter the interrupted phase.
    case suspend
    /// Reactivate the session and continue recording in a new chunk.
    case resumeInNewChunk
    /// Close the current chunk and restart capture on the current route in a new chunk.
    case restartInNewChunk
}

public enum RecorderPolicy {
    /// - Parameter resumePending: a resume was allowed by the system but could not be
    ///   performed (for example because the app was in the background).
    public static func reaction(to event: AudioSessionEvent, phase: RecorderPhase, resumePending: Bool) -> RecorderReaction {
        switch (event, phase) {
        case (.interruptionBegan, .recording):
            return .suspend
        case (.interruptionEnded(shouldResume: true), .interrupted):
            return .resumeInNewChunk
        case (.routeChanged(.inputDeviceLost, inputAvailable: true), .recording),
             (.routeChanged(.noSuitableRoute, inputAvailable: true), .recording):
            return .restartInNewChunk
        case (.routeChanged(.inputDeviceLost, inputAvailable: false), .recording),
             (.routeChanged(.noSuitableRoute, inputAvailable: false), .recording):
            return .suspend
        case (.mediaServicesReset, .recording), (.engineConfigurationChanged, .recording):
            return .restartInNewChunk
        case (.becameActive, .interrupted) where resumePending:
            return .resumeInNewChunk
        default:
            return .ignore
        }
    }
}

/// Role of a file found in the recordings directory.
public enum RecordingFileRole: Equatable, Sendable {
    /// A closed, finalized chunk that may be queued for upload.
    case closedChunk
    /// A chunk still being written, or left behind by a killed process. Never uploaded.
    case partial
    /// Anything else. Ignored and never uploaded.
    case other
}

public enum RecordingFiles {
    public static let quarantineFolderName = "Quarantine"

    public static func partialName(forChunkNamed name: String) -> String {
        name + CaptureNaming.partialSuffix
    }

    /// The final chunk name for a partial file, or `nil` when the partial does not
    /// belong to a recorder chunk (so it can never be promoted to an uploadable name).
    public static func finalName(forPartialNamed name: String) -> String? {
        guard name.hasSuffix(CaptureNaming.partialSuffix) else { return nil }
        let base = String(name.dropLast(CaptureNaming.partialSuffix.count))
        return CaptureNaming.isChunkName(base) ? base : nil
    }

    public static func role(ofFileNamed name: String) -> RecordingFileRole {
        if CaptureNaming.isChunkName(name) { return .closedChunk }
        if name.hasSuffix(CaptureNaming.partialSuffix) { return .partial }
        return .other
    }
}
