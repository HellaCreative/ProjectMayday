import Foundation
import Network

/// Lightweight online/offline flag for mid-ride recovery (avoid 60s hangs offline).
@Observable
@MainActor
final class NetworkPathMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dirt.network-path")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
