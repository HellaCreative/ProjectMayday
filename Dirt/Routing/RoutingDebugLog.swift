import CoreLocation
import Foundation
import UIKit

/// Ring-buffer of routing / pack decisions for field debugging.
/// Copy from Profile → TESTER while investigating wrong-province / freeze bugs.
@MainActor
final class RoutingDebugLog {
    static let shared = RoutingDebugLog()

    private let maxEntries = 200
    private var entries: [String] = []
    private let startedAt = Date()

    var isEnabled: Bool = true

    var text: String {
        let header = [
            "DIRT routing debug log",
            "started \(iso(startedAt))",
            "entries \(entries.count)",
            "---"
        ].joined(separator: "\n")
        return ([header] + entries).joined(separator: "\n")
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        event("log cleared")
    }

    func event(_ message: String) {
        guard isEnabled else { return }
        let line = "\(iso(Date()))  \(message)"
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        #if DEBUG
        print("[DirtRoute]", message)
        #endif
    }

    func routeAttempt(
        mode: String,
        from: (lat: Double, lon: Double),
        to: (lat: Double, lon: Double),
        profile: String,
        allowUnknown: Bool
    ) {
        let fromId = GraphPackStore.primaryRegionId(
            containing: .init(latitude: from.lat, longitude: from.lon)
        ) ?? "?"
        let toId = GraphPackStore.primaryRegionId(
            containing: .init(latitude: to.lat, longitude: to.lon)
        ) ?? "?"
        let needed = GraphPackStore.regionIds(containingAny: [
            .init(latitude: from.lat, longitude: from.lon),
            .init(latitude: to.lat, longitude: to.lon)
        ])
        event(
            "ROUTE mode=\(mode) profile=\(profile) allowUnknown=\(allowUnknown) "
                + "A=\(fmt(from.lat)),\(fmt(from.lon))[\(fromId)] "
                + "B=\(fmt(to.lat)),\(fmt(to.lon))[\(toId)] "
                + "needed=[\(needed.joined(separator: ","))]"
        )
    }

    func routeResult(_ message: String) {
        event("RESULT \(message)")
    }

    func routeFailure(_ error: Error, context: String) {
        let ns = error as NSError
        event(
            "FAIL \(context): \(error.localizedDescription) "
                + "domain=\(ns.domain) code=\(ns.code)"
        )
    }

    func copyToPasteboard() {
        UIPasteboard.general.string = text
        event("copied to pasteboard (\(entries.count) lines)")
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.5f", value)
    }
}
