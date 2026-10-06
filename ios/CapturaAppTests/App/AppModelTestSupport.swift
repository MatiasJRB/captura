import CapturaCore
import Foundation
import Synchronization
import UIKit
import XCTest
@testable import Captura

extension NetworkConditions {
    static let onWiFi = NetworkConditions(online: true, wifi: true)
    static let onCellular = NetworkConditions(online: true, wifi: false)
    static let noNetwork = NetworkConditions(online: false, wifi: false)
}

/// Records what the model asked of sync and answers with scripted results.
final class FakeSyncService: SyncService, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [SyncTrigger] = []
    private var _ensureFolderCount = 0
    private var _summary = SyncSummary()
    private var _folder: Result<DriveFolderResolution, Error> = .success(DriveFolderResolution(id: "fixtureFolder0001", outcome: .created))
    /// Runs this closure (e.g. to persist the folder ID like the real engine) before answering.
    var onEnsureFolder: (@Sendable (String) async throws -> Void)?
    /// When set, a run marks every pending item verified, as a successful upload would.
    var completesUploadsIn: UploadQueue?

    var runs: [SyncTrigger] { lock.withLock { _runs } }
    var ensureFolderCount: Int { lock.withLock { _ensureFolderCount } }

    var summary: SyncSummary {
        get { lock.withLock { _summary } }
        set { lock.withLock { _summary = newValue } }
    }

    var folder: Result<DriveFolderResolution, Error> {
        get { lock.withLock { _folder } }
        set { lock.withLock { _folder = newValue } }
    }

    func run(_ trigger: SyncTrigger, onEvent: @escaping @Sendable (SyncEvent) -> Void) async -> SyncSummary {
        let summary = lock.withLock {
            _runs.append(trigger)
            return _summary
        }
        if let queue = completesUploadsIn {
            for item in await queue.eligible(now: Date(), ignoringBackoff: true) {
                try? await queue.markVerified(item.id, driveFileID: "fakeDriveFile\(item.id.count)", at: Date())
            }
        }
        return summary
    }

    func ensureFolder() async throws -> DriveFolderResolution {
        let result = lock.withLock { () -> Result<DriveFolderResolution, Error> in
            _ensureFolderCount += 1
            return _folder
        }
        let resolution = try result.get()
        try await onEnsureFolder?(resolution.id)
        return resolution
    }
}

/// Network conditions set by the test.
final class FakeNetwork: NetworkConditionsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NetworkConditions
    private var handler: (@MainActor @Sendable (NetworkConditions) -> Void)?

    init(_ value: NetworkConditions) {
        self.value = value
    }

    var latest: NetworkConditions { lock.withLock { value } }

    func current() async -> NetworkConditions { latest }

    func setChangeHandler(_ handler: @escaping @MainActor @Sendable (NetworkConditions) -> Void) {
        lock.withLock { self.handler = handler }
    }

    @MainActor
    func change(to conditions: NetworkConditions) {
        let handler = lock.withLock { () -> (@MainActor @Sendable (NetworkConditions) -> Void)? in
            value = conditions
            return self.handler
        }
        handler?(conditions)
    }
}

@MainActor
final class FakeBackgroundExecution: BackgroundExecution {
    private(set) var begun: [String] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private(set) var scheduledProcessing = 0
    private var expiration: (@MainActor () -> Void)?
    private var nextIdentifier = 1

    func beginTask(named name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier? {
        begun.append(name)
        self.expiration = expiration
        defer { nextIdentifier += 1 }
        return UIBackgroundTaskIdentifier(rawValue: nextIdentifier)
    }

    func endTask(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }

    func scheduleProcessingSync() {
        scheduledProcessing += 1
    }

    func expire() {
        expiration?()
    }
}

/// A sync service that blocks inside `run` until the test releases it.
final class BlockingSyncService: SyncService, @unchecked Sendable {
    private let lock = NSLock()
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    private(set) var wasCancelled = false

    func waitUntilRunning() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if didStart { return true }
                started = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Only the first run blocks; later runs return at once.
    func run(_ trigger: SyncTrigger, onEvent: @escaping @Sendable (SyncEvent) -> Void) async -> SyncSummary {
        let (alreadyBlocked, waiter) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
            let blocked = didStart
            didStart = true
            defer { started = nil }
            return (blocked, started)
        }
        if alreadyBlocked { return SyncSummary() }
        waiter?.resume()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        lock.withLock { wasCancelled = true }
        var summary = SyncSummary()
        summary.stopReason = .cancelled
        return summary
    }

    func ensureFolder() async throws -> DriveFolderResolution {
        DriveFolderResolution(id: "fixtureFolder0001", outcome: .reused)
    }
}

/// A complete model on temporary directories: fake microphone and chunk files, a real
/// `UploadQueue` and `SyncSettingsStore`, a real `GoogleSignInController` on an
/// in-memory token store, and fake sync, network and background execution.
@MainActor
final class AppModelHarness {
    let root: URL
    let recordings: URL
    let session: FakeRecordingSession
    let files: FakeChunkFileFactory
    let network: FakeNetwork
    let background: FakeBackgroundExecution
    let clock: TestClock
    let tokenStore: InMemoryTokenStore
    let authTransport: AppAuthStubTransport
    let settings: SyncSettingsStore
    let queue: UploadQueue
    let window: UIWindow
    let model: AppModel
    let recorder: RecorderController
    let auth: GoogleSignInController
    private let engineBox: EngineBox

    /// The fake microphone of the current recording.
    var engine: FakeAudioCaptureEngine? { engineBox.engines.last }

    init(
        linked: Bool = true,
        network conditions: NetworkConditions = .onWiFi,
        automatic: Bool = false,
        sync: SyncService? = nil,
        makeSync: ((UploadQueue, SyncSettingsStore, GoogleSignInController) -> SyncService)? = nil,
        authResponses: [HTTPResponse] = [],
        prepare: ((SyncSettingsStore) throws -> Void)? = nil
    ) throws {
        let root = try RecorderFixtures.temporaryDirectory("AppModel")
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let syncDirectory = root.appendingPathComponent("Sync", isDirectory: true)
        let clock = TestClock()
        let box = EngineBox()
        let session = FakeRecordingSession()
        let files = FakeChunkFileFactory()
        let network = FakeNetwork(conditions)
        let background = FakeBackgroundExecution()
        let tokenStore = InMemoryTokenStore(linked ? GoogleCredential(refreshToken: "fixture-refresh", accountEmail: AppAuthFixtures.email) : nil)
        let authTransport = AppAuthStubTransport(authResponses)
        let settings = SyncSettingsStore(directory: syncDirectory)
        if automatic { try settings.update { $0.automaticSync = true } }
        try prepare?(settings)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let auth = GoogleSignInController(
            infoDictionary: AppAuthFixtures.configuredInfo,
            store: tokenStore,
            transport: authTransport,
            webSession: FakeWebAuthenticationSession(),
            anchorProvider: { window }
        )
        let recorder = RecorderController(
            directory: recordings,
            chunkDuration: 900,
            session: session,
            makeEngine: {
                let engine = FakeAudioCaptureEngine()
                box.engines.append(engine)
                return engine
            },
            fileFactory: files,
            notificationCenter: NotificationCenter(),
            isAppInForeground: { true },
            now: { clock.now() }
        )
        let queue = try UploadQueue(storeDirectory: syncDirectory, capturesRoot: recordings)
        let model = AppModel(
            recorder: recorder,
            auth: auth,
            settingsStore: settings,
            queue: queue,
            sync: makeSync?(queue, settings, auth) ?? sync ?? FakeSyncService(),
            network: network,
            background: background,
            isAppInForeground: { true },
            now: { clock.now() }
        )
        self.root = root
        self.recordings = recordings
        self.session = session
        self.files = files
        self.network = network
        self.background = background
        self.clock = clock
        self.tokenStore = tokenStore
        self.authTransport = authTransport
        self.settings = settings
        self.queue = queue
        self.window = window
        self.model = model
        self.recorder = recorder
        self.auth = auth
        self.engineBox = box
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Records `seconds` of synthetic tone (fake engine, fake files) and stops.
    func recordAndStop(seconds: Double = 3) async throws {
        await model.startRecording()
        XCTAssertTrue(recorder.state.isRecording, "state: \(recorder.state)")
        engine?.emit(seconds: seconds)
        await recorder.drainPendingWrites()
        await model.stopRecording()
        await recorder.drainPendingWrites()
        await model.waitUntilIdle()
    }

    /// Writes a closed chunk directly, as the recorder would leave it.
    @discardableResult
    func writeClosedChunk(bytes: Int = 4_096) throws -> URL {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let url = recordings.appendingPathComponent(CaptureNaming.chunkName(startedAt: clock.now()))
        try Data(repeating: 0x42, count: bytes).write(to: url)
        return url
    }
}

@MainActor
private final class EngineBox {
    var engines: [FakeAudioCaptureEngine] = []
}

/// The folder half of Drive v3, in memory: generateIds, files.get and folder creation.
/// Enough to check that linking creates the private inbox the worker looks for.
final class MiniDriveFolderServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: [String: Any]] = [:]
    private var nextID = 1
    private var log: [String] = []
    let expectedToken: String

    init(expectedToken: String = AppAuthFixtures.accessToken) {
        self.expectedToken = expectedToken
    }

    var requestLog: [String] { lock.withLock { log } }

    func folder(_ id: String) -> [String: Any]? { lock.withLock { files[id] } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(expectedToken)")
        XCTAssertTrue(DriveEndpoint.isAllowed(request.url))
        let path = request.url.path
        return lock.withLock {
            log.append("\(request.method) \(path)")
            switch (request.method, path) {
            case ("GET", "/drive/v3/files/generateIds"):
                let id = String(format: "miniFolder%04d", nextID)
                nextID += 1
                return json(["ids": [id]])
            case ("GET", _) where path.hasPrefix("/drive/v3/files/"):
                let id = String(path.dropFirst("/drive/v3/files/".count))
                guard let file = files[id] else { return HTTPResponse(status: 404) }
                return json(file)
            case ("POST", "/drive/v3/files"):
                guard case .data(let body) = request.body,
                      var metadata = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      let id = metadata["id"] as? String
                else { return HTTPResponse(status: 400) }
                if files[id] != nil { return HTTPResponse(status: 409) }
                metadata["ownedByMe"] = true
                metadata["shared"] = false
                metadata["trashed"] = false
                files[id] = metadata
                return json(["id": id])
            default:
                return HTTPResponse(status: 400)
            }
        }
    }

    private func json(_ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

/// Fails the test if any request is made.
struct UnreachableTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTFail("Unexpected Drive request: \(request.method) \(request.url.path)")
        throw URLError(.notConnectedToInternet)
    }
}
