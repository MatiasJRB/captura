import BackgroundTasks
import Foundation
import os
import UIKit

/// Extra time and wake-ups the app asks iOS for, abstracted for tests.
@MainActor
protocol BackgroundExecution: AnyObject {
    /// `UIApplication.beginBackgroundTask`: a few more seconds to finish the item being
    /// uploaded after the app left the screen. `expiration` runs on the main actor; the
    /// caller must stop its work and end the task there. Nil when iOS refuses.
    func beginTask(named name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier?
    func endTask(_ identifier: UIBackgroundTaskIdentifier)
    /// Asks iOS to wake the app later (on a network) to continue pending uploads.
    func scheduleProcessingSync()
}

final class SystemBackgroundExecution: BackgroundExecution {
    func beginTask(named name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expiration() }
        }
        return identifier == .invalid ? nil : identifier
    }

    func endTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }

    func scheduleProcessingSync() {
        BackgroundSyncTask.schedule()
    }
}

/// A `BGProcessingTask` that continues pending uploads when iOS decides to wake the app
/// (usually idle, often charging). It needs only the free "Background Modes >
/// Background processing" mode (`processing` in `UIBackgroundModes`) and the task ID in
/// `BGTaskSchedulerPermittedIdentifiers`; no paid capability. iOS chooses when (and
/// whether) it runs, and it never runs in the Simulator; the app also syncs whenever it
/// is open or recording, so this is only a best-effort extra.
enum BackgroundSyncTask {
    private static let log = Logger(subsystem: "org.example.captura", category: "background-sync")

    /// `<bundle id>.drive-sync`; Info.plist lists `$(PRODUCT_BUNDLE_IDENTIFIER).drive-sync`.
    static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "org.example.captura") + ".drive-sync"
    }

    /// Info.plist must permit the identifier, or registering would crash the app.
    static var isPermitted: Bool {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return permitted.contains(identifier)
    }

    /// Call before the app finishes launching. `work` returns whether it completed.
    static func register(_ work: @escaping @MainActor @Sendable () async -> Bool) {
        guard isPermitted else {
            log.error("Background sync identifier missing from Info.plist; not registered")
            return
        }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            let box = TaskBox(task)
            let operation = Task { @MainActor in
                let completed = await work()
                box.task.setTaskCompleted(success: completed)
            }
            task.expirationHandler = {
                // Stops the upload at its next checkpoint; the item stays pending.
                operation.cancel()
            }
        }
        if !registered { log.error("Background sync task was not registered") }
    }

    static func schedule() {
        guard isPermitted else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the Simulator (`unavailable`) and when Background App Refresh is off.
            log.info("Background sync not scheduled: \(LogPrivacy.publicSummary(of: error), privacy: .public)")
        }
    }

    /// `BGTask` is not `Sendable`; it is only touched on the main queue here.
    private final class TaskBox: @unchecked Sendable {
        let task: BGTask
        init(_ task: BGTask) { self.task = task }
    }
}
