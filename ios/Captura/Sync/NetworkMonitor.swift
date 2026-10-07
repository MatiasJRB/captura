import CapturaCore
import Foundation
import Network
import Synchronization

/// What the app model needs to know about the network: the current conditions and a
/// callback when they change (e.g. Wi-Fi came back, so pending audio can go up).
protocol NetworkConditionsProviding: AnyObject, Sendable {
    /// Waits briefly for the first observation after launch.
    func current() async -> NetworkConditions
    /// The last observed value, or offline before the first observation.
    var latest: NetworkConditions { get }
    /// Called on the main actor after every change.
    func setChangeHandler(_ handler: @escaping @MainActor @Sendable (NetworkConditions) -> Void)
}

/// `NWPathMonitor` reduced to `NetworkConditions`, like the Android job's check of
/// `NET_CAPABILITY_INTERNET` + `TRANSPORT_WIFI`.
///
/// "Wi-Fi" for automatic sync means Wi-Fi or wired Ethernet that iOS does not mark as
/// expensive (a phone's Personal Hotspot is Wi-Fi but expensive) nor constrained
/// (Low Data Mode). `online` is `path.status == .satisfied`; iOS has no equivalent of
/// Android's "validated", so a captive portal shows up as a failed request instead.
final class NetworkMonitor: NetworkConditionsProviding {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.example.captura.network", qos: .utility)
    private let state = Mutex<NetworkConditions?>(nil)
    private let handler = Mutex<(@MainActor @Sendable (NetworkConditions) -> Void)?>(nil)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(Self.conditions(for: path))
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var latest: NetworkConditions {
        state.withLock { $0 } ?? NetworkConditions(online: false, wifi: false)
    }

    func current() async -> NetworkConditions {
        // The first path arrives within milliseconds of `start`; do not wait forever.
        for _ in 0..<20 {
            if let value = state.withLock({ $0 }) { return value }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return latest
    }

    func setChangeHandler(_ handler: @escaping @MainActor @Sendable (NetworkConditions) -> Void) {
        self.handler.withLock { $0 = handler }
        // The first path may have arrived before the handler was set: deliver it too.
        if let known = state.withLock({ $0 }) {
            Task { @MainActor in handler(known) }
        }
    }

    private func update(_ conditions: NetworkConditions) {
        let previous = state.withLock { value -> NetworkConditions? in
            defer { value = conditions }
            return value
        }
        guard previous != conditions, let handler = handler.withLock({ $0 }) else { return }
        Task { @MainActor in handler(conditions) }
    }

    static func conditions(for path: NWPath) -> NetworkConditions {
        conditions(
            satisfied: path.status == .satisfied,
            wifi: path.usesInterfaceType(.wifi),
            wired: path.usesInterfaceType(.wiredEthernet),
            expensive: path.isExpensive,
            constrained: path.isConstrained
        )
    }

    static func conditions(satisfied: Bool, wifi: Bool, wired: Bool, expensive: Bool, constrained: Bool) -> NetworkConditions {
        NetworkConditions(online: satisfied, wifi: satisfied && (wifi || wired) && !expensive && !constrained)
    }
}
