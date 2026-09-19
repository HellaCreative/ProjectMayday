import CoreLocation
import Foundation
import UIKit

/// Ring-buffer for field debugging across the whole app. Routing remains the
/// most detailed category, but network, map, lifecycle, fuel-control and memory
/// events share the same timeline so failures can be correlated.
@MainActor
final class RoutingDebugLog {
    static let shared = RoutingDebugLog()

    /// Device logs must prove which pack/corridor binary ran. Bump with each
    /// #34 corridor fix; Play cards quote this stamp.
    static let diagnosticStamp = "layers-st-stephen-20260919a"

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
        #if DIRT_DEVELOPMENT
        let fabric = AppConfig.v4CandidateReleaseId
        #else
        let fabric = "production"
        #endif
        let header = [
            "DIRT app diagnostic log",
            "started \(iso(startedAt))",
            "exported \(iso(Date()))",
            "app \(version) (\(build))",
            "stamp \(Self.diagnosticStamp)",
            "fabric \(fabric)",
            "device \(device.model) · iOS \(device.systemVersion) · memory \(memoryMB)MB",
            "locale \(Locale.current.identifier) · timezone \(TimeZone.current.identifier)",
            "fuel notifications=\(FuelRangePrefs.notificationsEnabled ? 1 : 0) range=\(Int(FuelRangePrefs.kilometers))km reserve=\(Int(FuelRangePrefs.reservePercent))% last=\(Int(FuelRangePrefs.lastEnabledKilometers))km",
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
        print("[DirtDebug]", message)
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
                + "snapMs=\(d?.snapMs.map(String.init) ?? "-") "
                + "searchMs=\(d?.searchMs.map(String.init) ?? response.debug?.searchMs.map(String.init) ?? "-") "
                + "postMs=\(d?.postprocessMs.map(String.init) ?? "-") "
                + "deadlineRemainingMs=\(d?.deadlineRemainingMs.map(String.init) ?? "-") "
                + "pops=\(d?.pops.map(String.init) ?? response.debug?.pops.map(String.init) ?? "-") "
                + "requestedProfile=\(d?.requestedProfile ?? "-") "
                + "effectiveProfile=\(d?.effectiveProfile ?? "-") "
                + "allowUnknown=\(d?.allowUnknown == true ? 1 : 0) "
                + "tapRadius=\(d?.tapRadiusMeters.map { String(Int($0)) } ?? "-")m "
                + "mapZoom=\(d?.mapZoom.map { String(format: "%.1f", $0) } ?? "-") "
                + "snapStart=\(fmtSnap(d?.snap?.start)) "
                + "snapEnd=\(fmtSnap(d?.snap?.end)) "
                + "fallbacks=[\((d?.profileFallbacks ?? []).joined(separator: ","))] "
                + "corridor=\(d?.corridorMeters.map { "\(Int($0))" } ?? "-") "
                + "widened=\(d?.corridorWidened == true ? 1 : 0) "
                + "maxCrossTrack=\(d?.maxCrossTrackMeters.map { "\(Int($0))" } ?? "-")m "
                + "backtrackPct=\(d?.backtrackPct.map { String(format: "%.1f", $0) } ?? response.backtrackPct.map { String(format: "%.1f", $0) } ?? "-") "
                + "failureReason=\(d?.failureReason ?? response.debug?.failureReason ?? "-") "
                + "cleanMetroMultiplier=\(d?.cleanMetroMultiplier.map { String(format: "%.0f", $0) } ?? "-") "
                + "endpointResolutionMs=\(d?.endpointResolutionMs.map(String.init) ?? "-") "
                + "endpointProbes=\(d?.endpointProbeCount.map(String.init) ?? "-") "
                + "endpointSources=\(d?.endpointResolutionSources ?? "-") "
                + "attempts=[\(attemptText)]"
        )
    }

    func snapSelection(
        allowUnknown: Bool,
        tapRadiusMeters: Double?,
        mapZoom: Double?,
        start: RouteSnapEndpoint?,
        end: RouteSnapEndpoint?
    ) {
        event(
            "SNAP allowUnknown=\(allowUnknown ? 1 : 0) "
                + "tapRadius=\(tapRadiusMeters.map { String(Int($0)) } ?? "-")m "
                + "mapZoom=\(mapZoom.map { String(format: "%.1f", $0) } ?? "-") "
                + "start=\(fmtSnap(start)) end=\(fmtSnap(end))"
        )
    }

    func liveFuelDiagnostics(_ response: FuelChainResponse, requestID: String? = nil) {
        let d = response.diagnostics
        let request = requestID.map { " request=\($0)" } ?? ""
        let slowRoutes = (d?.slowestProfileRoutes ?? []).map { attempt in
            "\(attempt.candidateId ?? "-"):\(attempt.elapsedMs.map(String.init) ?? "-")ms/"
                + "\(attempt.status ?? "-")/search=\(attempt.searchMs.map(String.init) ?? "-")/"
                + "snap=\(attempt.snapMs.map(String.init) ?? "-")/"
                + "post=\(attempt.postprocessMs.map(String.init) ?? "-")/"
                + "pops=\(attempt.pops.map(String.init) ?? "-")/"
                + "deadline=\(attempt.deadlineRemainingAtStartMs.map(String.init) ?? "-")→"
                + "\(attempt.deadlineRemainingAtEndMs.map(String.init) ?? "-")/"
                + "fallbacks=[\((attempt.fallbacks ?? []).joined(separator: ","))]"
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
                + "budget=\(candidate.approachBudgetMs.map(String.init) ?? "-")ms/"
                + "\(candidate.approachElapsedMs.map(String.init) ?? "-")ms/"
                + "\(candidate.approachStatus ?? "-")/"
                + "\(candidate.approachSearchOutcome ?? "-")/"
                + "\(candidate.continuationElapsedMs.map(String.init) ?? "-")ms/"
                + "\(candidate.continuationStatus ?? "-")/"
                + "\(candidate.continuationStrategy ?? "-")/"
                + "remaining=\(candidate.candidateDeadlineRemainingMs.map(String.init) ?? "-")ms/"
                + "source=\(candidate.candidateSource ?? "-")/"
                + "along=\(candidate.foundationAlongMeters.map { String(Int($0)) } ?? "-")m/"
                + "off=\(candidate.foundationOffRouteMeters.map { String(Int($0)) } ?? "-")m/"
                + "routeCell=\(candidate.foundationPriorityCellDistance.map(String.init) ?? "-")/"
                + "chain=\(candidate.chainMeters.map { String(Int($0)) } ?? "-")m/"
                + "chainDirt=\(candidate.chainDirtPct.map { String(format: "%.1f", $0) } ?? "-")%/"
                + "continuationBack=\(candidate.continuationBacktrackMeters.map { String(Int($0)) } ?? "-")m/"
                + "\(candidate.rejectedReason ?? "kept")"
        }.joined(separator: ",")
        event(
            "FUEL diag\(request) status=\(response.status) "
                + "strategy=\(d?.strategy ?? "-") "
                + "fuelPolicy=\(d?.selectionPolicy ?? "-") "
                + "graphOnly=\(d?.graphOnlySelection == true ? 1 : 0) "
                + "alternatives=\(d?.stationAlternativesReturned.map(String.init) ?? "-")/"
                + "\(d?.stationAlternativesLimit.map(String.init) ?? "-") "
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
                + "routeFirstSharedRuntime=\(d?.routeFirstSharedRuntime == true ? 1 : 0) "
                + "profileRoutesSharedRuntime=\(d?.profileRoutesSharedRuntime == true ? 1 : 0) "
                + "routeFirstAttempted=\(d?.routeFirstAttempted == true ? 1 : 0) "
                + "routeFirstSkipped=\(d?.routeFirstSkippedReason ?? "-") "
                + "directLowerBound=\(d?.directLowerBoundMeters.map(String.init) ?? "-")m "
                + "firstLegMax=\(d?.firstLegMaxMeters.map(String.init) ?? "-")m "
                + "planningDataLoadMs=\(d?.planningDataLoadMs.map(String.init) ?? "-") "
                + "routeFirstBuildMs=\(d?.routeFirstBuildMs.map(String.init) ?? "-") "
                + "routeFirstSnapMs=\(d?.routeFirstSnapMs.map(String.init) ?? "-") "
                + "routeFirstSearchMs=\(d?.routeFirstSearchMs.map(String.init) ?? "-") "
                + "routeFirstPostMs=\(d?.routeFirstPostprocessMs.map(String.init) ?? "-") "
                + "routeFirstPops=\(d?.routeFirstPops.map(String.init) ?? "-") "
                + "routeFirstOutcome=\(d?.routeFirstSearchOutcome ?? "-") "
                + "routeFirstFallbacks=[\((d?.routeFirstFallbacks ?? []).joined(separator: ","))] "
                + "routeFirstAfterLoadMs=\(d?.routeFirstDeadlineRemainingAfterLoadMs.map(String.init) ?? "-") "
                + "routeFirstWindowAfterLoadMs=\(d?.routeFirstWindowRemainingAfterLoadMs.map(String.init) ?? "-") "
                + "routeFirstSearchGrantedMs=\(d?.routeFirstSearchBudgetGrantedMs.map(String.init) ?? "-") "
                + "routeFirstLoadReliefMs=\(d?.routeFirstLoadBudgetReliefMs.map(String.init) ?? "-") "
                + "routeFirstBudgetAfterLoad=\(d?.routeFirstBudgetStartsAfterRuntimeLoad == true ? 1 : 0) "
                + "endpointResolutionMs=\(d?.endpointResolutionMs.map(String.init) ?? "-") "
                + "endpointProbes=\(d?.endpointProbeCount.map(String.init) ?? "-") "
                + "endpointSources=\(d?.endpointResolutionSources ?? "-") "
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
                + "foundationReused=\(d?.foundationRouteReused == true ? 1 : 0) "
                + "foundationRoute=\(d?.foundationRouteMeters.map(String.init) ?? "-")m/"
                + "\(d?.foundationRouteDirtPercent.map(String.init) ?? "-")% "
                + "foundationMatches=\(d?.foundationMatchedStations.map(String.init) ?? "-") "
                + "foundationPriority=\(d?.foundationPriorityStations.map(String.init) ?? "-") "
                + "foundationStation=\(d?.foundationSelectedStationId ?? "-") "
                + "foundationChain=\(d?.foundationChainMeters.map(String.init) ?? "-")m/"
                + "\(d?.foundationChainDirtPercent.map(String.init) ?? "-")% "
                + "profileRouteSavings=\(d?.profileRouteSavings.map(String.init) ?? "-") "
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
                + "allowUnknown=\(d?.allowUnknown == true ? 1 : 0) "
                + "tapRadius=\(d?.tapRadiusMeters.map { String(Int($0)) } ?? "-")m "
                + "mapZoom=\(d?.mapZoom.map { String(format: "%.1f", $0) } ?? "-") "
                + "snapStart=\(fmtSnap(d?.snap?.start)) "
                + "snapEnd=\(fmtSnap(d?.snap?.end)) "
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

    private func fmtSnap(_ endpoint: RouteSnapEndpoint?) -> String {
        guard let endpoint else { return "-" }
        let raw = endpoint.raw.map { "\(fmt($0.latitude)),\(fmt($0.longitude))" } ?? "-"
        let snapped = endpoint.snapped.map { "\(fmt($0.latitude)),\(fmt($0.longitude))" } ?? "-"
        let reasons = (endpoint.rejectionReasons ?? []).joined(separator: ",")
        return "raw=\(raw) snapped=\(snapped) d=\(endpoint.distanceM.map(String.init) ?? "-")m "
            + "cands=\(endpoint.candidateCount.map(String.init) ?? "-") "
            + "way=\(endpoint.osmWayId ?? "-") access=\(endpoint.accessClass ?? "-") "
            + "comp=\(endpoint.component.map(String.init) ?? "-") "
            + "reject=[\(reasons)]"
    }
}
