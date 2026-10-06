import CapturaCore
import SwiftUI
import UIKit

@main
struct CapturaApp: App {
    @UIApplicationDelegateAdaptor(CapturaAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            if AppEnvironment.isHostingTests {
                // Unit-test host: no recorder, network, Keychain model or background work.
                Theme.bg.ignoresSafeArea()
            } else {
                MainView(model: AppModel.shared)
            }
        }
    }
}

final class CapturaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Background task handlers must be registered before launch finishes.
        if !AppEnvironment.isHostingTests {
            BackgroundSyncTask.register { await AppModel.shared.runBackgroundSync() }
        }
        return true
    }
}
