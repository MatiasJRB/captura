import CapturaCore
import Foundation
import Observation
import UIKit

/// The single app model: one recorder, the Google link, the upload queue and sync.
/// Port of the behaviour of Android's `MainActivity`, `SyncScheduler` and
/// `SyncJobService` (iOS has no JobScheduler, so the model decides when to run).
///
/// Boundaries kept from Android and `AGENTS.md`:
/// - Recording starts only from an explicit action of the person (button or intent
///   that opens the app); nothing here turns the microphone on by itself.
/// - Linking Google does not upload. Automatic sync is opt-in, confirmed, Wi-Fi only.
///   "Sincronizar ahora" allows any network for 30 minutes after the request.
/// - Originals are never deleted; uploads are verified against Drive's receipt.
/// - Audio content is never interpreted; only file names, sizes and hashes are used.
@MainActor
@Observable
final class AppModel {
    // MARK: - Observed state

    let recorder: RecorderController
    let auth: GoogleSignInController
    private(set) var settings: SyncSettings
    private(set) var counts = QueueCounts()
    private(set) var recordings: [RecordingRow] = []
    private(set) var network: NetworkConditions
    private(set) var isSyncing = false
    /// The file being uploaded and the fraction Google confirmed.
    private(set) var progress: (fileName: String, fraction: Double)?
    private(set) var syncMessage: String
    private(set) var syncMessageAt: Date?
    /// Why the last "Grabar" did not start (Spanish), until the next successful start.
    private(set) var recorderMessage: String?
    /// Drive refused the stored grant: show "Volver a vincular" even if an account is stored.
    private(set) var driveNeedsRelink = false
    private(set) var isPreparingFolder = false
    /// Set when the queue file cannot be read; sync is disabled, recording still works.
    let queueUnavailableMessage: String?

    // MARK: - Dependencies

    @ObservationIgnored private let queue: UploadQueue?
    @ObservationIgnored private let settingsStore: SyncSettingsStore
    @ObservationIgnored private let sync: SyncService?
    @ObservationIgnored private let networkMonitor: NetworkConditionsProviding
    @ObservationIgnored private let background: BackgroundExecution
    @ObservationIgnored private let notices: PauseNotifying
    @ObservationIgnored private let isAppInForeground: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date

    // MARK: - Work in flight

    @ObservationIgnored private var intakeTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var runningTrigger: SyncTrigger?
    @ObservationIgnored private var followUpRequested = false
    @ObservationIgnored private var folderTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier?
    @ObservationIgnored private var isInBackground = false
    /// When "Grabar con Captura" asked to start while the app was not in the foreground.
    @ObservationIgnored private var pendingIntentStartAt: Date?
    @ObservationIgnored private var lastStopReason: SyncSummary.StopReason?

    // MARK: - Pause notices

    /// Set from the person's choice each time recording starts; off until then.
    @ObservationIgnored private var noticesAllowed = false
    /// Why the recording is paused, until it continues or the person starts or stops.
    @ObservationIgnored private var pendingPause: RecorderPauseReason?
    /// The reason of the notice in Notification Center: one alert per reason and pause.
    @ObservationIgnored private var postedPause: RecorderPauseReason?
    /// Reading (and, the first time, asking for) notice permission after a start.
    @ObservationIgnored private(set) var noticePermissionTask: Task<Void, Never>?

    init(
        recorder: RecorderController,
        auth: GoogleSignInController,
        settingsStore: SyncSettingsStore,
        queue: UploadQueue?,
        queueUnavailableMessage: String? = nil,
        sync: SyncService?,
        network: NetworkConditionsProviding,
        background: BackgroundExecution,
        notices: PauseNotifying,
        isAppInForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState != .background },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recorder = recorder
        self.auth = auth
        self.settingsStore = settingsStore
        self.queue = queue
        self.queueUnavailableMessage = queueUnavailableMessage
        self.sync = sync
        self.networkMonitor = network
        self.background = background
        self.notices = notices
        self.isAppInForeground = isAppInForeground
        self.now = now
        self.network = network.latest
        let settings = settingsStore.current
        self.settings = settings
        syncMessage = settings.lastMessage ?? Self.defaultMessage(automatic: settings.automaticSync)
        syncMessageAt = settings.lastMessageAt
        if !settingsStore.isPersistent {
            syncMessage = "No se pudo guardar la configuración de sincronización. Grabar funciona; la subida a Drive queda apagada."
        }

        recorder.onChunkClosed = { [weak self] url in self?.chunkClosed(url) }
        recorder.onPauseEvent = { [weak self] event in self?.recorderPauseChanged(event) }
        network.setChangeHandler { [weak self] conditions in self?.networkChanged(conditions) }
    }

    // MARK: - Derived state

    var isLinked: Bool {
        if case .signedIn = auth.status { return true }
        return false
    }

    var linkedEmail: String? {
        if case .signedIn(let email) = auth.status { return email }
        return nil
    }

    /// Sync can run at all in this build and on this device.
    var canSync: Bool { sync != nil && queue != nil && settingsStore.isPersistent }

    var manualWindowOpen: Bool {
        guard let requested = settings.manualRequestedAt else { return false }
        let current = now()
        return current >= requested && current.timeIntervalSince(requested) <= SyncPolicy.manualWindow
    }

    // MARK: - App lifecycle

    /// On launch and every return to the foreground: read the queue, finish setup and
    /// resume pending work (Android re-schedules its jobs the same way).
    func sceneBecameActive() async {
        isInBackground = false
        // The screen shows the recorder state now (also clears a notice left by a
        // previous run of the app).
        withdrawPauseNotice()
        updateBackgroundAssertion()
        recorder.refreshPermission()
        network = await networkMonitor.current()
        await auth.refreshStatus()
        await reconcileDriveAccount()
        await refreshLibrary()
        if let requestedAt = pendingIntentStartAt {
            pendingIntentStartAt = nil
            // Only the activation the intent itself caused; a later, unrelated open of the
            // app must never turn the microphone on.
            let age = now().timeIntervalSince(requestedAt)
            if age >= 0, age <= Self.intentStartWindow { await startRecording() }
        }
        prepareFolderIfNeeded()
        requestSync()
    }

    func sceneEnteredBackground() {
        isInBackground = true
        if recorder.state == .interrupted {
            // Paused while on screen (often the call that just took the screen): the
            // card is not visible any more, so the notice says it.
            postPauseNotice(pendingPause ?? .interrupted)
        }
        updateBackgroundAssertion()
        scheduleBackgroundSyncIfNeeded()
    }

    /// Work for a `BGProcessingTask`: one sync pass (and its follow-ups). Returns
    /// whether it finished without being cancelled.
    ///
    /// Cancelling the calling Task (the task's expiration handler) cancels the running
    /// pass too, so the work returns promptly and the task can be completed in time.
    func runBackgroundSync() async -> Bool {
        await withTaskCancellationHandler {
            // A fresh background launch has not seen the network yet.
            network = await networkMonitor.current()
            await reconcileDriveAccount()
            await refreshLibrary()
            // Expired before the pass started: start nothing (the handler found no pass).
            guard !Task.isCancelled else { return false }
            requestSync()
            await waitUntilIdle()
            scheduleBackgroundSyncIfNeeded()
            return !Task.isCancelled
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopSyncForExpiredTime() }
        }
    }

    /// Asks iOS for a later wake-up while audio waits for an allowed upload.
    private func scheduleBackgroundSyncIfNeeded() {
        if canSync, isLinked, counts.waiting > 0, settings.automaticSync || manualWindowOpen {
            background.scheduleProcessingSync()
        }
    }

    /// A chunk closed while the app is already in the background (rotation, or
    /// "Detener Captura"): leaving the screen happened before it existed.
    private func scheduleBackgroundSyncIfInBackground() {
        guard isInBackground || !isAppInForeground() else { return }
        scheduleBackgroundSyncIfNeeded()
    }

    // MARK: - Recording

    func startRecording() async {
        do {
            try await recorder.start()
            recorderMessage = nil
            pendingPause = nil
            withdrawPauseNotice()
            refreshNoticePermission()
        } catch {
            recorderMessage = (error as? LocalizedError)?.errorDescription
                ?? "No se pudo iniciar la grabación. Probá de nuevo."
        }
    }

    /// Stops recording and queues the last chunk. Returns whether something was stopped.
    @discardableResult
    func stopRecording() async -> Bool {
        let wasActive = recorder.state.phase == .recording || recorder.state.phase == .interrupted
        let closed = await recorder.stop()
        pendingPause = nil
        withdrawPauseNotice()
        if let closed { await enqueue(closed) }
        await refreshLibrary()
        requestSync()
        updateBackgroundAssertion()
        scheduleBackgroundSyncIfInBackground()
        return wasActive
    }

    func toggleRecording() async {
        switch recorder.state {
        case .recording, .interrupted:
            await stopRecording()
        case .idle, .failed:
            await startRecording()
        }
    }

    /// From the "Grabar con Captura" intent, which opens the app first. iOS does not
    /// allow starting the microphone from the background, so a start that arrives
    /// before the app is in the foreground waits for it.
    func startRecordingFromIntent() async {
        guard isAppInForeground() else {
            pendingIntentStartAt = now()
            return
        }
        pendingIntentStartAt = nil
        await startRecording()
    }

    /// How long a start requested by the intent waits for the app to come forward.
    static let intentStartWindow: TimeInterval = 30

    func openMicrophoneSettings() {
        guard let url = RecorderController.settingsURL else { return }
        UIApplication.shared.open(url)
    }

    #if DEBUG
    @ObservationIgnored private var automationStarted = false

    /// `-CapturaAutoRecordSeconds N` (Debug builds only): record N seconds once, as if
    /// the person had tapped Grabar and then Detener. See `LaunchOptions`.
    func runLaunchAutomation(_ options: LaunchOptions) async {
        guard let seconds = options.autoRecordSeconds, !automationStarted else { return }
        automationStarted = true
        await startRecording()
        guard recorder.state.isRecording else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await stopRecording()
    }
    #endif

    // MARK: - Pause notices

    /// After the microphone permission (the recording already started), never at launch:
    /// asks for notice permission the first time, then only reads the person's choice,
    /// which may have changed in Ajustes. A denial changes nothing else.
    private func refreshNoticePermission() {
        let notices = self.notices
        noticePermissionTask = Task { [weak self] in
            var permission = await notices.permission()
            if permission == .undetermined {
                permission = await notices.requestPermission()
            }
            self?.noticesAllowed = permission == .allowed
        }
    }

    /// Recording paused, stopped or continued without the person asking. On screen the
    /// status card says it; otherwise a local notification does. It is posted right
    /// away: once the microphone is gone, iOS may suspend the app at any moment.
    private func recorderPauseChanged(_ event: RecorderPauseEvent) {
        switch event {
        case .paused(let reason):
            pendingPause = reason
            if isInBackground || !isAppInForeground() {
                postPauseNotice(reason)
            }
        case .continued:
            pendingPause = nil
            withdrawPauseNotice()
        }
    }

    private func postPauseNotice(_ reason: RecorderPauseReason) {
        guard noticesAllowed, postedPause != reason else { return }
        postedPause = reason
        notices.post(PauseNotice(reason))
    }

    private func withdrawPauseNotice() {
        postedPause = nil
        notices.withdraw()
    }

    // MARK: - Drive link

    func linkDrive() async {
        guard canSync else {
            setMessage(Self.unavailableMessage(auth: auth.status, queueMessage: queueUnavailableMessage))
            return
        }
        do {
            // Only a hint: the person may still pick another account in Google's sheet.
            try await auth.signIn(loginHint: linkedEmail)
        } catch {
            setMessage(auth.lastErrorMessage ?? GoogleAuthError.userMessage(for: error))
            return
        }
        driveNeedsRelink = false
        let switchedAccount = await reconcileDriveAccount()
        if !switchedAccount {
            // A new grant starts new upload sessions; sessions are capabilities of the grant
            // that created them, and one Drive refuses would stop every run. Drive IDs stay,
            // so an upload that already finished is still found instead of duplicated.
            try? await queue?.forgetRemoteUploads(keepingFileIDs: true)
        }
        setMessage("Drive vinculado. Preparando la carpeta privada «\(CaptureNaming.folderName)»…")
        await prepareFolder()
        if switchedAccount, let email = linkedEmail, settings.folderID != nil {
            setMessage("Se vinculó otra cuenta (\(email)). El Wi-Fi automático quedó apagado: activalo de nuevo si querés. La carpeta «\(CaptureNaming.folderName)» es nueva: copiá su ID para la Mac.")
        }
    }

    func unlinkDrive() async {
        await cancelSync()
        do {
            try await auth.signOut()
        } catch {
            setMessage(auth.lastErrorMessage ?? GoogleAuthError.userMessage(for: error))
            return
        }
        updateSettings {
            $0.automaticSync = false
            $0.manualRequestedAt = nil
        }
        // Resumable sessions are capabilities of the grant just unlinked. Drive IDs and
        // the folder stay: they are reused if the same account links again, and
        // forgotten if another one does (`reconcileDriveAccount`).
        try? await queue?.forgetRemoteUploads(keepingFileIDs: true)
        driveNeedsRelink = false
        setMessage(auth.lastErrorMessage ?? "Drive desvinculado. Los audios siguen en el iPhone; lo ya subido queda en tu Drive.")
    }

    /// Whether the folder ID and the queue's Drive state belong to the linked account
    /// (true while nothing is recorded yet).
    var driveStateMatchesLinkedAccount: Bool {
        guard let owner = settings.driveAccountEmail, let email = linkedEmail else { return true }
        return GoogleCredential.sameAccount(owner, email)
    }

    /// The folder ID, the queue's Drive IDs and upload sessions, and the automatic
    /// upload consent all belong to one Google account. When another account is linked
    /// (Google's sheet lets the person pick any account), they are forgotten: the
    /// inbox is created again in the new account and automatic upload must be confirmed
    /// again for it. Returns whether the account changed.
    @discardableResult
    private func reconcileDriveAccount() async -> Bool {
        guard let email = linkedEmail else { return false }
        guard let owner = settings.driveAccountEmail else {
            updateSettings { $0.driveAccountEmail = email }
            return false
        }
        guard !GoogleCredential.sameAccount(owner, email) else { return false }
        await cancelSync()
        if let queue {
            do {
                try await queue.forgetRemoteUploads()
            } catch {
                // Keep the mismatch recorded: nothing syncs until this succeeds.
                setMessage("No se pudo actualizar la cola de subida para la cuenta nueva. Los audios siguen en el iPhone.")
                return true
            }
        }
        updateSettings {
            $0.folderID = nil
            $0.automaticSync = false
            $0.manualRequestedAt = nil
            $0.driveAccountEmail = email
        }
        return true
    }

    /// Creates or validates the inbox right after linking, so the Mac's `capture probe`
    /// finds the folder (and its ID can be copied) before the first recording.
    func prepareFolder() async {
        if let folderTask {
            await folderTask.value
            return
        }
        // Never race a sync run: both could create a folder for a missing ID.
        let runningSync = syncTask
        let task = Task {
            await runningSync?.value
            await self.performPrepareFolder()
        }
        folderTask = task
        await task.value
        folderTask = nil
        requestSync()
    }

    private func performPrepareFolder() async {
        guard let sync, isLinked, driveStateMatchesLinkedAccount else { return }
        isPreparingFolder = true
        defer { isPreparingFolder = false }
        do {
            let resolution = try await sync.ensureFolder()
            reloadSettings()
            if case .replaced = resolution.outcome {
                setMessage("Se creó una carpeta nueva en Drive. Actualizá el folder_id en la Mac.")
            } else {
                setMessage("Drive vinculado. La carpeta «\(CaptureNaming.folderName)» está lista; copiá su ID para la Mac.")
            }
        } catch DriveError.needsReauthorization {
            await relinkRequired()
        } catch DriveError.invalidPrivateFolder {
            setMessage("La carpeta de Drive no es privada o no se puede usar. Revisala en Drive; no se subió nada.")
        } catch is CancellationError {
            return
        } catch {
            setMessage("Drive vinculado, pero no se pudo preparar la carpeta. Se reintenta al sincronizar.")
        }
    }

    private func prepareFolderIfNeeded() {
        guard canSync, isLinked, settings.folderID == nil, !driveNeedsRelink, folderTask == nil,
              driveStateMatchesLinkedAccount else { return }
        Task { await prepareFolder() }
    }

    // MARK: - Sync settings and requests

    /// Called after the person confirmed the explanation of what is uploaded.
    func setAutomaticSync(_ enabled: Bool) {
        if enabled, !isLinked {
            setMessage("Primero vinculá Google Drive.")
            return
        }
        updateSettings { $0.automaticSync = enabled }
        if enabled {
            setMessage("Wi-Fi automático activado. Los audios finalizados se suben solos por Wi-Fi.")
            requestSync()
        } else {
            if case .automatic? = runningTrigger { syncTask?.cancel() }
            retryTask?.cancel()
            setMessage("Wi-Fi automático apagado. Los audios siguen en el iPhone.")
        }
    }

    /// "Sincronizar ahora": like Android's manual job. If recording, the current chunk
    /// is closed and recording continues in a new one (`ACTION_FLUSH`). Any network may
    /// be used for 30 minutes after the request.
    func syncNow() async {
        guard canSync else {
            setMessage(Self.unavailableMessage(auth: auth.status, queueMessage: queueUnavailableMessage))
            return
        }
        guard isLinked else {
            setMessage("Primero vinculá Google Drive.")
            return
        }
        let requestedAt = now()
        updateSettings { $0.manualRequestedAt = requestedAt }
        if recorder.state.isRecording, let closed = await recorder.cutChunk() {
            await enqueue(closed)
        }
        setMessage("Pedido manual en cola · permite datos móviles durante 30 minutos.")
        await refreshLibrary()
        requestSync()
    }

    /// A person looked at the quarantined audios and wants them tried again.
    func retryQuarantined() async {
        guard let queue else { return }
        for item in await queue.items() where item.state == .quarantined {
            _ = try? await queue.retryQuarantined(item.id)
        }
        await refreshLibrary()
        setMessage("Los audios en revisión vuelven a la cola.")
        requestSync()
    }

    /// Starts a sync pass when the current trigger allows one; while a pass is running,
    /// another one follows it (a chunk closed mid-run is uploaded right after).
    func requestSync() {
        guard canSync, isLinked else { return }
        if syncTask != nil || folderTask != nil {
            followUpRequested = true
            return
        }
        guard plannedTrigger() != nil else { return }
        retryTask?.cancel()
        retryTask = nil
        isSyncing = true
        syncTask = Task { await self.syncLoop() }
        updateBackgroundAssertion()
    }

    /// The trigger a run would use now, or nil when nothing may run.
    /// Like Android: a manual request is honoured for 30 minutes on any network;
    /// otherwise only the opted-in automatic sync, and only on Wi-Fi.
    func plannedTrigger() -> SyncTrigger? {
        // After Drive refused the grant, nothing runs until the person links again.
        guard canSync, isLinked, !driveNeedsRelink, driveStateMatchesLinkedAccount else { return nil }
        if manualWindowOpen, let requested = settings.manualRequestedAt {
            return .manual(requestedAt: requested)
        }
        if settings.automaticSync, network.online, network.wifi {
            return .automatic
        }
        return nil
    }

    /// Waits for pending intake and every queued pass (tests, background task).
    func waitUntilIdle() async {
        while true {
            await intakeTask?.value
            if let folderTask {
                await folderTask.value
                continue
            }
            guard let syncTask else { return }
            await syncTask.value
        }
    }

    private func cancelSync() async {
        retryTask?.cancel()
        retryTask = nil
        syncTask?.cancel()
        await syncTask?.value
    }

    private func syncLoop() async {
        var passes = 0
        // A request that arrives while a pass runs (or while it checks for work) gets
        // one more pass, so nothing waits for the next trigger.
        while passes < 5, !Task.isCancelled {
            followUpRequested = false
            if let sync, let trigger = plannedTrigger(), await hasWork(for: trigger) {
                runningTrigger = trigger
                let summary = await sync.run(trigger) { event in
                    Task { @MainActor [weak self] in self?.handle(event) }
                }
                runningTrigger = nil
                await apply(summary, trigger: trigger)
            }
            passes += 1
            if !followUpRequested { break }
        }
        progress = nil
        isSyncing = false
        syncTask = nil
        await refreshLibrary()
        updateBackgroundAssertion()
        if syncTask == nil { scheduleRetryIfNeeded() }
    }

    /// A manual request always runs (its summary tells the person what happened); an
    /// automatic one only when some audio is due.
    private func hasWork(for trigger: SyncTrigger) async -> Bool {
        if case .automatic = trigger { return await hasEligibleWork() }
        return true
    }

    private func hasEligibleWork() async -> Bool {
        guard let queue else { return false }
        _ = try? await queue.discover(now: now())
        return !(await queue.eligible(now: now())).isEmpty
    }

    private func apply(_ summary: SyncSummary, trigger: SyncTrigger) async {
        lastStopReason = summary.stopReason
        switch summary.stopReason {
        case .needsReauthorization?:
            await relinkRequired()
            return
        case .policy(.manualWindowExpired)?:
            updateSettings { $0.manualRequestedAt = nil }
        case .alreadyRunning?:
            // Another run owns the queue and will pick up the work.
            return
        default:
            break
        }
        if summary.folder != nil { reloadSettings() }
        if case .manual = trigger, summary.stopReason == nil, summary.remaining == 0 {
            // Everything is up; the cellular allowance is no longer needed.
            updateSettings { $0.manualRequestedAt = nil }
        }
        setMessage(summary.statusMessage)
        await refreshLibrary()
    }

    private func relinkRequired() async {
        driveNeedsRelink = true
        await auth.refreshStatus()
        var message = "Google requiere autorización. Volvé a vincular Google Drive. Los audios siguen en el iPhone."
        if !isLinked {
            // The grant is gone (revoked or expired). Automatic upload was confirmed for
            // that account; ask again after linking, which may be another account.
            if settings.automaticSync { message += " Después, activá de nuevo el Wi-Fi automático." }
            updateSettings {
                $0.automaticSync = false
                $0.manualRequestedAt = nil
            }
        }
        setMessage(message)
    }

    private func handle(_ event: SyncEvent) {
        guard isSyncing else { return }
        switch event {
        case .itemStarted(_, let fileName):
            progress = (fileName, 0)
        case .progress(_, let confirmed, let total):
            if let current = progress, total > 0 {
                progress = (current.fileName, min(1, Double(confirmed) / Double(total)))
            }
        case .itemFinished:
            progress = nil
        case .folderReady:
            reloadSettings()
        }
    }

    /// Retries while the app is running: automatic items after their backoff, a manual
    /// request every minute while its window is open. Network changes also retry.
    private func scheduleRetryIfNeeded() {
        retryTask?.cancel()
        retryTask = nil
        guard counts.waiting > 0, let trigger = plannedTrigger() else { return }
        let delay: TimeInterval
        switch lastStopReason {
        case .retryLater?:
            if case .manual = trigger { delay = 60 } else { delay = nextBackoffDelay() ?? 60 }
        case nil:
            guard case .automatic = trigger, let backoff = nextBackoffDelay() else { return }
            delay = backoff
        default:
            return
        }
        let nanoseconds = UInt64(min(max(delay, 30), 15 * 60) * 1_000_000_000)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.requestSync()
        }
    }

    @ObservationIgnored private var nextAttemptDates: [Date] = []

    private func nextBackoffDelay() -> TimeInterval? {
        let current = now()
        return nextAttemptDates.filter { $0 > current }.min().map { $0.timeIntervalSince(current) }
    }

    private func networkChanged(_ conditions: NetworkConditions) {
        network = conditions
        if conditions.online { requestSync() }
    }

    // MARK: - Background time

    /// When the app leaves the screen while uploading and not recording, ask for a few
    /// more seconds to finish the current item. Recording keeps the app running anyway
    /// (background audio), so no assertion is needed then.
    private func updateBackgroundAssertion() {
        // A launch by an intent or background task never saw the scene go to background.
        let inBackground = isInBackground || !isAppInForeground()
        let needed = inBackground && syncTask != nil && !recorder.state.isRecording
        if needed, backgroundTask == nil {
            backgroundTask = background.beginTask(named: "Captura · subir audio") { [weak self] in
                self?.backgroundTimeExpired()
            }
        } else if !needed, let identifier = backgroundTask {
            backgroundTask = nil
            background.endTask(identifier)
        }
    }

    private func backgroundTimeExpired() {
        stopSyncForExpiredTime()
        if let identifier = backgroundTask {
            backgroundTask = nil
            background.endTask(identifier)
        }
    }

    /// The engine stops at its next checkpoint; the item returns to pending and keeps
    /// its resumable session for the next run.
    private func stopSyncForExpiredTime() {
        syncTask?.cancel()
        retryTask?.cancel()
    }

    // MARK: - Queue intake and library

    private func chunkClosed(_ url: URL) {
        let previous = intakeTask
        intakeTask = Task {
            await previous?.value
            await self.enqueue(url)
            await self.refreshLibrary()
            self.requestSync()
            self.scheduleBackgroundSyncIfInBackground()
        }
    }

    /// Queues a closed chunk with its checksums. Idempotent. A file the worker would
    /// refuse (1024 bytes or less) simply stays on the phone.
    private func enqueue(_ url: URL) async {
        guard let queue else { return }
        do {
            try await queue.enqueue(fileAt: url, now: now())
        } catch UploadQueueError.tooSmall {
            return
        } catch UploadQueueError.writeFailed {
            setMessage("No se pudo actualizar la cola de subida. El audio sigue en el iPhone.")
        } catch {
            return
        }
    }

    /// Re-reads the queue and the recordings folder. The folder scan and the rows are
    /// built off the main actor (the folder only grows); results are applied in order,
    /// so an older refresh never overwrites a newer one.
    func refreshLibrary() async {
        libraryRequests &+= 1
        let request = libraryRequests
        let items: [UploadItem]
        if let queue {
            _ = try? await queue.discover(now: now())
            items = await queue.items()
        } else {
            items = []
        }
        let store = RecordingStore(directory: recorder.directory)
        let rows = await Task.detached(priority: .userInitiated) {
            RecordingRow.build(closedChunks: store.closedChunks(), items: items, quarantinedFiles: store.quarantinedFiles())
        }.value
        guard request > libraryApplied else { return }
        libraryApplied = request
        counts = QueueCounts(items)
        nextAttemptDates = items.filter { $0.state == .pending }.compactMap(\.nextAttemptAt)
        recordings = rows
    }

    @ObservationIgnored private var libraryRequests: UInt64 = 0
    @ObservationIgnored private var libraryApplied: UInt64 = 0

    // MARK: - Settings and messages

    private func updateSettings(_ change: (inout SyncSettings) -> Void) {
        do {
            settings = try settingsStore.update(change)
        } catch {
            // Keep working in memory; the next successful write persists it.
            var next = settings
            change(&next)
            settings = next
        }
    }

    private func reloadSettings() {
        let stored = settingsStore.current
        settings.folderID = stored.folderID
        settings.deviceID = stored.deviceID
    }

    private func setMessage(_ text: String) {
        let date = now()
        syncMessage = text
        syncMessageAt = date
        updateSettings {
            $0.lastMessage = text
            $0.lastMessageAt = date
        }
    }

    static func defaultMessage(automatic: Bool) -> String {
        automatic
            ? "Wi-Fi automático activado. Originales conservados en el iPhone."
            : "Originales conservados; sincronización automática apagada."
    }

    static func unavailableMessage(auth: GoogleSignInController.Status, queueMessage: String?) -> String {
        if case .notConfigured(let message) = auth { return message }
        return queueMessage ?? "La sincronización no está disponible en este iPhone. Grabar funciona igual."
    }
}
