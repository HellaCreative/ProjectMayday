import Foundation
import Network

/// Lightweight online/offline flag for mid-ride recovery (avoid 60s hangs offline).
@Observable
@MainActor
final class NetworkPathMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dirt.network-path")
    private var hasObservedPath = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = !hasObservedPath || isOnline != online
                isOnline = online
                if changed {
                    let interface: String
                    if path.usesInterfaceType(.wifi) { interface = "wifi" }
                    else if path.usesInterfaceType(.cellular) { interface = "cellular" }
                    else if path.usesInterfaceType(.wiredEthernet) { interface = "ethernet" }
                    else { interface = "other" }
                    RoutingDebugLog.shared.event(
                        "network online=\(online ? 1 : 0) interface=\(interface) expensive=\(path.isExpensive ? 1 : 0) constrained=\(path.isConstrained ? 1 : 0)"
                    )
                    hasObservedPath = true
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
