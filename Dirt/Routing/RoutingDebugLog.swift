import CoreLocation
import Foundation
import UIKit

/// Ring-buffer for field debugging across the whole app. Routing remains the
/// most detailed category, but network, map, lifecycle, fuel-control and memory
/// events share the same timeline so failures can be correlated.
@MainActor
final class RoutingDebugLog {
    static let shared = RoutingDebugLog()

    private let maxEntries = 1_200
    private var entries: [String] = []
    private let startedAt = Date()

    var isEnabled: Bool = true

    var text: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let device = UIDevice.current
        let memoryMB = ProcessInfo.processInfo.physicalMemory / 1_048_576
        let header = [
            "DIRT app diagnostic log",
            "started \(iso(startedAt))",
            "exported \(iso(Date()))",
            "app \(version) (\(build))",
            "device \(device.model) · iOS \(device.systemVersion) · memory \(memoryMB)MB",
            "locale \(Locale.current.identifier) · timezone \(TimeZone.current.identifier)",
            "fuel automatic=\(FuelRangePrefs.automaticPlanningEnabled ? 1 : 0) range=\(Int(FuelRangePrefs.kilometers))km reserve=\(Int(FuelRangePrefs.reservePercent))% last=\(Int(FuelRangePrefs.lastEnabledKilometers))km",
            "scope app,lifecycle,network,map,routing,fuel,navigation,groups",
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
        print("[DirtDebug]", message)
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

    func liveRouteDiagnostics(_ response: RouteResponse, requestID: String? = nil) {
        let d = response.debug?.diagnostics
        let request = requestID.map { " request=\($0)" } ?? ""
        let attempts = d?.searchAttempts ?? response.debug?.searchMeta?.corridorCandidates ?? []
        let attemptText = attempts.map { attempt in
            let width = attempt.corridorMeters.map { "\(Int($0))" } ?? "unbounded"
            let ms = attempt.searchMs.map(String.init) ?? "-"
            let pops = attempt.pops.map(String.init) ?? "-"
            return "\(width)m:\(attempt.outcome ?? "?")/pops=\(pops)/ms=\(ms)"
        }.joined(separator: ",")
        event(
            "ROUTE diag\(request) buildMs=\(d?.buildMs.map(String.init) ?? "-") "
                + "searchMs=\(d?.searchMs.map(String.init) ?? response.debug?.searchMs.map(String.init) ?? "-") "
                + "pops=\(d?.pops.map(String.init) ?? response.debug?.pops.map(String.init) ?? "-") "
                + "requestedProfile=\(d?.requestedProfile ?? "-") "
                + "effectiveProfile=\(d?.effectiveProfile ?? "-") "
                + "fallbacks=[\((d?.profileFallbacks ?? []).joined(separator: ","))] "
                + "corridor=\(d?.corridorMeters.map { "\(Int($0))" } ?? "-") "
                + "widened=\(d?.corridorWidened == true ? 1 : 0) "
                + "maxCrossTrack=\(d?.maxCrossTrackMeters.map { "\(Int($0))" } ?? "-")m "
                + "backtrackPct=\(d?.backtrackPct.map { String(format: "%.1f", $0) } ?? response.backtrackPct.map { String(format: "%.1f", $0) } ?? "-") "
                + "failureReason=\(d?.failureReason ?? response.debug?.failureReason ?? "-") "
                + "cleanMetroMultiplier=\(d?.cleanMetroMultiplier.map { String(format: "%.0f", $0) } ?? "-") "
                + "attempts=[\(attemptText)]"
        )
    }

    func liveFuelDiagnostics(_ response: FuelChainResponse, requestID: String? = nil) {
        let d = response.diagnostics
        let request = requestID.map { " request=\($0)" } ?? ""
        let slowRoutes = (d?.slowestProfileRoutes ?? []).map { attempt in
            "\(attempt.candidateId ?? "-"):\(attempt.elapsedMs.map(String.init) ?? "-")ms/\(attempt.status ?? "-")"
        }.joined(separator: ",")
        let targetPasses = (d?.targetPasses ?? []).prefix(4).map { pass in
            "\(pass.origin ?? "-"):\(pass.pool.map(String.init) ?? "-")/"
                + "\(pass.considered.map(String.init) ?? "-")/"
                + "\(pass.cacheMatches.map(String.init) ?? "-")/"
                + "\(pass.freshMatches.map(String.init) ?? "-")/"
                + "\(pass.returned.map(String.init) ?? "-")/"
                + "\(pass.limited == true ? 1 : 0)/"
                + "\(pass.elapsedMs.map(String.init) ?? "-")ms"
        }.joined(separator: ",")
        let candidateTrace = (response.stationCandidates ?? []).prefix(6).map { candidate in
            "#\(candidate.rank.map(String.init) ?? "-"):\(candidate.id):"
                + "\(candidate.approachElapsedMs.map(String.init) ?? "-")ms/"
                + "\(candidate.approachStatus ?? "-")/"
                + "\(candidate.approachSearchOutcome ?? "-")/"
                + "\(candidate.continuationElapsedMs.map(String.init) ?? "-")ms/"
                + "\(candidate.continuationStatus ?? "-")/"
                + "\(candidate.rejectedReason ?? "kept")"
        }.joined(separator: ",")
        event(
            "FUEL diag\(request) status=\(response.status) "
                + "strategy=\(d?.strategy ?? "-") "
                + "states=\(d?.states.map(String.init) ?? "-") "
                + "reachable=\(d?.stationsReachableWithinRange.map(String.init) ?? "-") "
                + "candidates=\(d?.candidatesEvaluated.map(String.init) ?? response.stationCandidates.map { String($0.count) } ?? "-") "
                + "candidateK=\(d?.candidateK.map(String.init) ?? "-") "
                + "considered=\(d?.stationsConsidered.map(String.init) ?? "-") "
                + "matchedFuel=\(d?.matchedFuel.map(String.init) ?? "-") "
                + "pops=\(d?.dijkstraPops.map(String.init) ?? "-") "
                + "profileRoutes=\(d?.profileRouteAttempts.map(String.init) ?? "-") "
                + "slowRoutes=[\(slowRoutes)] "
                + "maxHopMs=\(d?.maxHopMs.map(String.init) ?? "-") "
                + "elapsedMs=\(d?.elapsedMs.map(String.init) ?? "-") "
                + "totalMs=\(d?.totalElapsedMs.map(String.init) ?? "-") "
                + "windowBudgetMs=\(d?.windowBudgetMs.map(String.init) ?? "-") "
                + "windowOverrunMs=\(d?.windowBudgetOverrunMs.map(String.init) ?? "-") "
                + "searchOverrunMs=\(d?.searchDeadlineOverrunMs.map(String.init) ?? "-") "
                + "budgetExceeded=\(d?.timeBudgetExceeded == true ? 1 : 0) "
                + "profileFailure=\(d?.profileRouteFailureReason ?? "-") "
                + "profileOutcome=\(d?.profileRouteSearchOutcome ?? "-") "
                + "profileSearchMs=\(d?.profileRouteSearchMs.map(String.init) ?? "-") "
                + "profilePops=\(d?.profileRoutePops.map(String.init) ?? "-") "
                + "routeFirstMs=\(d?.routeFirstMs.map(String.init) ?? "-") "
                + "routeFirstBudgetMs=\(d?.routeFirstBudgetMs.map(String.init) ?? "-") "
                + "graphFetchMs=\(d?.graphFetchMs.map(String.init) ?? "-") "
                + "graphDecodeMs=\(d?.graphDecodeMs.map(String.init) ?? "-") "
                + "graphGridMs=\(d?.graphGridMs.map(String.init) ?? "-") "
                + "fuelFetchMs=\(d?.fuelFetchMs.map(String.init) ?? "-") "
                + "fuelCache=\(d?.fuelCacheHit == true ? "hit" : "miss") "
                + "targetPrepareMs=\(d?.targetPrepareMs.map(String.init) ?? "-") "
                + "targetCache=\(d?.targetCacheHit == true ? "hit" : "miss") "
                + "targetPool=\(d?.stationsInRange.map(String.init) ?? "-") "
                + "targetConsidered=\(d?.stationsConsidered.map(String.init) ?? "-") "
                + "targetLimited=\(d?.stationsMatchLimited == true ? 1 : 0) "
                + "targetCacheMatches=\(d?.stationCacheMatches.map(String.init) ?? "-") "
                + "targetFreshMatches=\(d?.stationFreshMatches.map(String.init) ?? "-") "
                + "targetPasses=[\(targetPasses)] "
                + "candidateTrace=[\(candidateTrace)] "
                + "deadlinePhase=\(d?.deadlinePhase ?? "-") "
                + "cancelled=\(d?.cancelled == true ? 1 : 0) "
                + "escapeSearchMs=\(d?.destinationEscapeSearchMs.map(String.init) ?? "-") "
                + "escapePops=\(d?.destinationEscapePops.map(String.init) ?? "-") "
                + "watch=\(d?.watchStartMeters.map { String(Int($0)) } ?? "-")m "
                + "preferred=\(d?.preferredStartMeters.map { String(Int($0)) } ?? "-")m "
                + "hard=\(d?.hardRangeMeters.map { String(Int($0)) } ?? "-")m "
                + "escape=\(d?.destinationEscapeMeters.map { String(Int($0)) } ?? "-")m "
                + "selected=\(d?.selectedReason ?? "-") "
                + "gapReason=\(d?.gapReason ?? "-") "
                + "failureReason=\(d?.failureReason ?? response.error ?? "-") "
                + "msg=\(response.message ?? "-")"
        )
    }

    func copyToPasteboard() {
        UIPasteboard.general.string = text
        event("copied to pasteboard (\(entries.count) lines)")
    }

    func writeShareFile() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dirt-app-debug-\(stamp).txt")
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "DirtRoutingDebug", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn’t encode log"])
        }
        try data.write(to: url)
        event("wrote share file \(url.lastPathComponent)")
        return url
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.5f", value)
    }
}
