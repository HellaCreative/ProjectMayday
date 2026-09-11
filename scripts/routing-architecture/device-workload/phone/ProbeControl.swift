import Foundation

// Shared stop state is latched. One worker must finish before another can start.
final class ProbeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped: (String, Double)?
    func stop(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        if stopped == nil { stopped = (reason, ProcessInfo.processInfo.systemUptime) }
    }
    var outcome: (reason: String, at: Double)? {
        lock.lock(); defer { lock.unlock() }
        return stopped.map { (reason: $0.0, at: $0.1) }
    }
    // Publication and cancellation have a single ordering. Slow serialization
    // happens before this short critical section, not inside the stop callback.
    func publishIfRunning(_ action: () throws -> Void) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stopped == nil else { return false }
        try action()
        return true
    }
}
