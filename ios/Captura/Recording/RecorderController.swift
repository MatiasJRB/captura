import AVFoundation
import CapturaCore
import Observation
import UIKit

/// Records user-started, visible audio into closed 15-minute M4A chunks.
/// Port of the recording half of Android's `CaptureService` + `PcmAacWriter`.
///
/// - Recording only starts from `start()`, called by the user from the foreground.
///   Nothing here starts the microphone on its own: after an interruption it only
///   resumes a recording the user started and did not stop.
/// - Each chunk is written as `<name>.m4a.partial`, closed, verified and atomically
///   renamed to `<name>.m4a`; only then is `onChunkClosed` called. A chunk that
///   cannot be closed is moved to `Quarantine/` and never reported.
/// - Use a single instance per app: creating one quarantines leftover `.partial`
///   files, which would include the open chunk of another live instance.
@MainActor
@Observable
final class RecorderController {
    private(set) var state: RecorderState = .idle
    private(set) var permission: MicrophonePermission
    private(set) var lastClosedChunk: ClosedChunk?
    private(set) var lastQuarantined: URL?
    /// `.partial` files found at launch (the app was killed while writing), already
    /// moved to quarantine. The UI can mention them; they are never uploaded.
    private(set) var recoveredOnLaunch: [URL] = []

    /// Called on the main actor after a chunk was closed and renamed to its final name.
    @ObservationIgnored var onChunkClosed: ((URL) -> Void)?

    let directory: URL
    let chunkDuration: TimeInterval

    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private let format: RecordingFormat
    @ObservationIgnored private let session: RecordingAudioSession
    @ObservationIgnored private let makeEngine: @MainActor () -> AudioCaptureEngine
    @ObservationIgnored private let isAppInForeground: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let writer: ChunkWriter
    @ObservationIgnored private let observers: NotificationObservers
    @ObservationIgnored private var engine: AudioCaptureEngine?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var resumePending = false
    @ObservationIgnored private var isStarting = false

    /// Every dependency has a production default; tests inject fakes.
    /// - Parameters:
    ///   - directory: where chunks are written (default Application Support/Captura/Recordings).
    ///   - chunkDuration: rotation length (default 15 minutes, Android `CHUNK_MS`).
    ///   - session: `nil` uses the system `AVAudioSession`.
    init(
        directory: URL = RecordingStore.defaultDirectory,
        chunkDuration: TimeInterval = ChunkRotation.defaultChunkDuration,
        format: RecordingFormat = .standard,
        session: RecordingAudioSession? = nil,
        makeEngine: @escaping @MainActor () -> AudioCaptureEngine = { AVAudioCaptureEngine() },
        fileFactory: AudioChunkFileFactory = AACChunkFileFactory(),
        notificationCenter: NotificationCenter = .default,
        isAppInForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState != .background },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let store = RecordingStore(directory: directory)
        let session = session ?? SystemRecordingAudioSession()
        let relay = WriterEventRelay()
        self.directory = directory
        self.chunkDuration = chunkDuration
        self.store = store
        self.format = format
        self.session = session
        self.makeEngine = makeEngine
        self.isAppInForeground = isAppInForeground
        self.now = now
        self.permission = session.permission
        self.observers = NotificationObservers(center: notificationCenter)
        self.writer = ChunkWriter(
            store: store,
            format: format,
            chunkDuration: chunkDuration,
            fileFactory: fileFactory,
            now: now,
            events: { relay.send($0) }
        )
        relay.controller = self

        do {
            try store.prepare()
            recoveredOnLaunch = store.quarantineLeftoverPartials()
        } catch {
            state = .failed(message: RecorderError.storageUnavailable.errorDescription ?? "")
        }
        observeSystemNotifications(on: notificationCenter)
    }

    /// Opens the app's page in Settings, where the user can allow the microphone.
    static var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }

    // MARK: - Commands

    /// Starts recording. Requests microphone permission the first time.
    /// Must be called from the foreground: iOS does not let an app start recording
    /// in the background (it may continue in the background once started).
    func start() async throws {
        if state.isRecording || isStarting { return }
        isStarting = true
        defer { isStarting = false }

        guard isAppInForeground() else { throw RecorderError.mustStartInForeground }
        permission = session.permission
        if permission == .undetermined {
            permission = await session.requestPermission()
        }
        guard permission == .granted else { throw RecorderError.microphoneDenied }
        do {
            try store.prepare()
        } catch {
            state = .failed(message: RecorderError.storageUnavailable.errorDescription ?? "")
            throw RecorderError.storageUnavailable
        }
        do {
            try activateSession()
            try startCapture()
        } catch {
            stopEngineAndSession()
            let failure = (error as? RecorderError) ?? .couldNotStart(String(describing: error))
            state = .failed(message: failure.errorDescription ?? "")
            throw failure
        }
        resumePending = false
        let startedAt = now()
        sessionStartedAt = startedAt
        state = .recording(startedAt: startedAt, chunkStartedAt: startedAt)
    }

    /// Stops recording, closes the current chunk and releases the microphone.
    /// Returns the closed chunk, if the last chunk had audio.
    @discardableResult
    func stop() async -> URL? {
        resumePending = false
        sessionStartedAt = nil
        state = .idle
        stopEngineAndSession()
        return await writer.finish()?.closedURL
    }

    /// Closes the current chunk and keeps recording into a new one, without a gap.
    /// Used by "Sincronizar ahora" (Android `ACTION_FLUSH`). Returns the closed chunk.
    @discardableResult
    func cutChunk() async -> URL? {
        guard case .recording(let startedAt, _) = state else { return nil }
        state = .recording(startedAt: startedAt, chunkStartedAt: now())
        return await writer.cut()?.closedURL
    }

    func refreshPermission() {
        permission = session.permission
    }

    // MARK: - Queries

    /// Time since the user pressed Grabar (including interruptions), 0 when idle.
    func elapsed(at date: Date? = nil) -> TimeInterval {
        guard let sessionStartedAt, state.phase == .recording || state.phase == .interrupted else { return 0 }
        return max(0, (date ?? now()).timeIntervalSince(sessionStartedAt))
    }

    /// Time since the current chunk started, 0 when not recording.
    func chunkElapsed(at date: Date? = nil) -> TimeInterval {
        guard case .recording(_, let chunkStartedAt) = state else { return 0 }
        return max(0, (date ?? now()).timeIntervalSince(chunkStartedAt))
    }

    /// Closed chunks in the recordings folder, oldest first. Never includes
    /// `.partial` files or anything in quarantine.
    func closedChunks() -> [URL] {
        store.closedChunks()
    }

    func quarantinedFiles() -> [URL] {
        store.quarantinedFiles()
    }

    /// Waits until every buffer delivered so far was written and every resulting
    /// event (like `onChunkClosed`) was handled.
    func drainPendingWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.afterPendingWork {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    // MARK: - System events

    func handle(_ event: AudioSessionEvent) {
        if event == .becameActive {
            refreshPermission()
        }
        if event == .mediaServicesReset {
            // Every audio object is invalid now: rebuild the engine and the session.
            engine?.stop()
            engine = nil
            sessionActive = false
        }
        switch RecorderPolicy.reaction(to: event, phase: state.phase, resumePending: resumePending) {
        case .ignore:
            break
        case .suspend:
            suspend()
        case .resumeInNewChunk:
            resume()
        case .restartInNewChunk:
            restart()
        }
    }

    private func observeSystemNotifications(on center: NotificationCenter) {
        for name in AudioSessionNotificationParser.observedNames {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let pending = AudioSessionNotificationParser.pending(from: notification) else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handle(pending.resolve(inputAvailable: self.session.isInputAvailable))
                }
            }
            observers.add(token)
        }
    }

    fileprivate func handle(_ event: ChunkWriterEvent) {
        switch event {
        case .opened(_, let chunkStartedAt):
            if case .recording(let startedAt, _) = state {
                state = .recording(startedAt: startedAt, chunkStartedAt: chunkStartedAt)
            }
        case .closed(let chunk):
            lastClosedChunk = chunk
            onChunkClosed?(chunk.url)
        case .quarantined(let url, _):
            lastQuarantined = url
        case .failed(let message, let failedGeneration):
            guard failedGeneration == generation, state.isRecording else { return }
            resumePending = false
            stopEngineAndSession()
            state = .failed(message: message)
        }
    }

    // MARK: - Capture plumbing

    private func activateSession() throws {
        try session.activateForRecording()
        sessionActive = true
    }

    private func startCapture() throws {
        generation &+= 1
        let generation = self.generation
        let writer = self.writer
        writer.begin(generation: generation)
        let engine = self.engine ?? makeEngine()
        self.engine = engine
        engine.onConfigurationChange = { [weak self] in
            MainActor.assumeIsolated { self?.handle(.engineConfigurationChanged) }
        }
        do {
            try engine.start(delivering: format.processingFormat) { buffer in
                writer.append(buffer, generation: generation)
            }
        } catch {
            writer.finish { _ in }
            throw error
        }
    }

    private func stopEngineAndSession() {
        engine?.stop()
        if sessionActive {
            session.deactivate()
            sessionActive = false
        }
    }

    /// Interruption began or the input disappeared: close the chunk, keep the intent.
    private func suspend() {
        engine?.stop()
        // The system already deactivated the session for an interruption.
        sessionActive = false
        resumePending = false
        state = .interrupted
        writer.finish { _ in }
    }

    private func resume() {
        do {
            try activateSession()
            try startCapture()
            resumePending = false
            let resumedAt = now()
            state = .recording(startedAt: sessionStartedAt ?? resumedAt, chunkStartedAt: resumedAt)
        } catch {
            stopEngineAndSession()
            if isAppInForeground() {
                resumePending = false
                state = .failed(message: RecorderMessages.resumeFailed)
            } else {
                // iOS may refuse to restart input in the background. Stay interrupted
                // and resume when the user brings the app back to the foreground.
                resumePending = true
            }
        }
    }

    /// Route or engine configuration changed: close the chunk, continue on the new route.
    private func restart() {
        engine?.stop()
        writer.finish { _ in }
        do {
            if !sessionActive { try activateSession() }
            try startCapture()
            if case .recording(let startedAt, _) = state {
                state = .recording(startedAt: startedAt, chunkStartedAt: now())
            }
        } catch {
            stopEngineAndSession()
            if session.isInputAvailable {
                state = .failed(message: RecorderMessages.restartFailed)
            } else {
                resumePending = false
                state = .interrupted
            }
        }
    }
}

/// Forwards writer events to the controller on the main queue, in order.
private final class WriterEventRelay: @unchecked Sendable {
    /// Written once during init, then read only on the main queue.
    weak var controller: RecorderController?

    func send(_ event: ChunkWriterEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.controller?.handle(event)
            }
        }
    }
}

/// Removes block-based observers when the controller goes away.
private final class NotificationObservers {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }
}
