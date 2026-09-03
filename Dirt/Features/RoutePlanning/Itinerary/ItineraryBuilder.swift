import CoreLocation
import Foundation

private enum FuelAdvisoryIssue {
    case gap(String)
    case unknown(String)

    var logValue: String {
        switch self {
        case .gap: "gap"
        case .unknown: "unknown"
        }
    }

    var logDetail: String {
        let detail: String
        switch self {
        case .gap(let value), .unknown(let value):
            detail = value
        }
        return detail
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "/")
    }

    func riderMessage(hasConfirmedPump: Bool) -> String? {
        guard case .unknown = self else { return nil }
        return hasConfirmedPump
            ? "Fuel coverage after the last confirmed stop could not be verified. Route kept—carry extra fuel or adjust this section."
            : "Fuel coverage on this leg could not be verified. Route kept—carry extra fuel or adjust this section."
    }
}

struct FuelPlanningProgressWatchdog {
    let inactivityInterval: TimeInterval
    private(set) var deadline: Date

    init(inactivityInterval: TimeInterval = 28, now: Date = Date()) {
        self.inactivityInterval = inactivityInterval
        deadline = now.addingTimeInterval(inactivityInterval)
    }

    mutating func recordProgress(at now: Date = Date()) {
        deadline = now.addingTimeInterval(inactivityInterval)
    }

    func isExpired(at now: Date = Date()) -> Bool {
        now >= deadline
    }

    func remainingMilliseconds(at now: Date = Date()) -> Int {
        max(0, Int(deadline.timeIntervalSince(now) * 1_000))
    }
}

@MainActor
final class ItineraryBuilder {
    /// Hard live window, not a delay target. Small rides still return as soon
    /// as proved; dense Ontario/Quebec requests get enough room to prove both
    /// sides of one pump without reaching Vercel's platform timeout.
    private static let liveFuelWindowBudgetMs = 20_000
    private var currentGeneration: Int?

    func setCurrentGeneration(_ generation: Int) {
        currentGeneration = generation
    }

    func cancelCurrentBuild() {
        currentGeneration = nil
    }

    func build(
        _ itinerary: RiderItinerary,
        from legIndex: Int,
        through throughLegIndex: Int? = nil,
        reuse: BuiltItinerary?,
        fuel: FuelRangePrefs.Snapshot,
        source policy: RoutingSourcePolicy,
        replanFromStationID: String? = nil,
        onFuelStatus: @MainActor (String) -> Void = { _ in },
        onProgress: @MainActor (BuiltItinerary) -> Void
    ) async -> BuiltItinerary {
        currentGeneration = itinerary.generation
        let requestedStartIndex = min(max(0, legIndex), itinerary.legs.count)
        let requestedEndIndex = throughLegIndex.map {
            min(itinerary.legs.count, max(requestedStartIndex, $0 + 1))
        } ?? itinerary.legs.count
        let fuelReplan = fuel.automaticPlanningEnabled && fuel.usableMeters > 0
        let resume = fuelReplan ? fuelResume(
            stationID: replanFromStationID,
            riderLegIndex: requestedStartIndex,
            itinerary: itinerary,
            reuse: reuse
        ) : nil
        let prefix = reusablePrefix(
            from: reuse,
            itinerary: itinerary,
            before: requestedStartIndex
        )
        // A rider can append or move another pin while the previous suffix is
        // still building. Start at the first unfinished rider leg so a partial
        // progress snapshot can never strand an earlier leg as pending.
        let localEdit = throughLegIndex != nil
        let startIndex = resume == nil
            ? (localEdit ? requestedStartIndex : prefix.riderLegCount)
            : requestedStartIndex
        let kept: [BuiltLeg] = {
            if let resume { return resume.kept }
            return prefix.legs
        }()
        let preservedSuffix = localEdit
            ? reusableSuffix(from: reuse, itinerary: itinerary, startingAt: requestedEndIndex)
            : []
        let reusableRoutes = reusableRiderRoutes(
            from: reuse,
            itinerary: itinerary,
            outside: startIndex..<requestedEndIndex
        )
        var statuses = Dictionary(
            uniqueKeysWithValues: itinerary.legs.map { ($0.id, LegStatus.pending) }
        )
        if let reuse {
            let preservedIDs = Set((kept + preservedSuffix).map(\.riderLegID))
            for id in preservedIDs {
                statuses[id] = reuse.riderLegStatus[id] ?? .built
            }
        } else {
            for leg in kept { statuses[leg.riderLegID] = .built }
        }
        var committed = BuiltItinerary(
            generation: itinerary.generation,
            legs: kept,
            riderLegStatus: statuses,
            riderRoutes: reusableRoutes,
            waypointFuelStops: [:]
        )

        guard !itinerary.legs.isEmpty else {
            RoutingDebugLog.shared.event(
                "build committed gen=\(itinerary.generation) legs=\(kept.count)"
            )
            return committed
        }

        let firstRequest = routeRequest(
            itinerary: itinerary,
            legIndex: min(startIndex, itinerary.legs.count - 1),
            maxPathMeters: nil
        )
        let selectedSource = policy.select(for: firstRequest)
        RoutingDebugLog.shared.event(
            "build start gen=\(itinerary.generation) fromLeg=\(startIndex) " +
                "throughLeg=\(max(startIndex, requestedEndIndex - 1)) " +
                "requestedFrom=\(requestedStartIndex) reusePrefix=\(kept.count) " +
                "reuseSuffix=\(preservedSuffix.count) localEdit=\(localEdit ? 1 : 0) " +
                "source=\(selectedSource.name)"
        )

        // Fuel-enabled routing is built forward from one proven anchor to the
        // next. There is deliberately no disposable Point 1 -> Point 2 scout
        // route: each feeler asks whether the rider waypoint is reachable with
        // the fuel currently available, otherwise it returns one forward pump.
        if fuelReplan {
            return await buildForwardFuelItinerary(
                itinerary,
                startIndex: startIndex,
                endIndex: requestedEndIndex,
                resume: resume,
                kept: kept,
                preservedSuffix: preservedSuffix,
                preservedStatuses: statuses,
                preservedRoutes: reusableRoutes,
                preservedWaypointFuelStops: reuse?.waypointFuelStops ?? [:],
                preservedArrivalFuelUsedByLeg: reuse?.legs.reduce(into: [:]) {
                    $0[$1.riderLegID] = $1.fuelUsedOnArrivalMeters
                } ?? [:],
                fuel: fuel,
                source: selectedSource,
                allowFuelRewind: !localEdit,
                onFuelStatus: onFuelStatus,
                onProgress: onProgress
            )
        }

        // Distance discovery is intentionally complete before the first fuel
        // decision. The next rider leg can therefore never be a nil fallback.
        var baseline: [Int: RouteResponse] = [:]
        var baselineProfiles: [Int: RouteProfile] = [:]
        var baselineHistory: [Int: EdgeHistory] = [:]
        var discoveryHistory = EdgeHistory()
        var baselineFailure: (index: Int, message: String)?
        for index in 0..<requestedEndIndex {
            do {
                baselineHistory[index] = discoveryHistory
                let riderLeg = itinerary.legs[index]
                let from = itinerary.waypoints[index].coordinate
                let to = itinerary.waypoints[index + 1].coordinate
                let straightMeters = straightLineMeters(from, to)
                // Province/state families only — never treat internal pack-shard
                // seams (or coarse bbox overlaps within one province) as cross-region.
                let crossProvince = GraphPackStore.endpointsCrossProvince([
                    from.locationCoordinate, to.locationCoordinate
                ])
                let cleanFoundation = fuelReplan && (
                    straightMeters >= 1_000_000
                        || crossProvince
                )
                var discoveryProfile: RouteProfile = cleanFoundation ? .cleanest : riderLeg.profile
                var response: RouteResponse
                if (index < startIndex || (resume != nil && index == startIndex)),
                   let cached = reuse?.riderRoutes[riderLeg.id] ?? reusableRoutes[riderLeg.id] {
                    response = cached
                    discoveryProfile = reuse?.legs.first(where: { $0.riderLegID == riderLeg.id })?.routeProfile
                        ?? discoveryProfile
                } else {
                    response = try await selectedSource.route(routeRequest(
                        itinerary: itinerary,
                        legIndex: index,
                        maxPathMeters: nil,
                        history: discoveryHistory,
                        profileOverride: discoveryProfile
                    ))
                }
                // Clean is the fast connectivity foundation only for a true
                // long-haul or cross-region leg. Requiring several pumps is not
                // itself permission to replace a sub-1,000 km adventure route.
                if fuelReplan,
                   (straightMeters >= 1_000_000 || crossProvince),
                   discoveryProfile != .cleanest {
                    discoveryProfile = .cleanest
                    response = try await selectedSource.route(routeRequest(
                        itinerary: itinerary,
                        legIndex: index,
                        maxPathMeters: nil,
                        history: discoveryHistory,
                        profileOverride: .cleanest
                    ))
                }
                guard active(itinerary) else {
                    return dropped(itinerary, committed: committed)
                }
                baseline[index] = response
                baselineProfiles[index] = discoveryProfile
                if discoveryProfile == .cleanest, riderLeg.profile != .cleanest {
                    RoutingDebugLog.shared.event(
                        "fuel longhaul default riderLeg=\(riderLeg.id) requested=\(riderLeg.profile.rawValue) " +
                        "sections=clean reason=\(crossProvince ? "cross_region" : "over_1000km")"
                    )
                }
                discoveryHistory.append(response)
            } catch is CancellationError {
                return dropped(itinerary, committed: committed, cancelled: true)
            } catch {
                guard active(itinerary) else {
                    return dropped(itinerary, committed: committed)
                }
                baselineFailure = (index, error.localizedDescription)
                break
            }
        }

        var routedResponses = reusableRoutes
        for (index, response) in baseline {
            routedResponses[itinerary.legs[index].id] = response
        }
        committed = BuiltItinerary(
            generation: itinerary.generation,
            legs: kept,
            riderLegStatus: statuses,
            riderRoutes: routedResponses,
            waypointFuelStops: [:]
        )

        var waypointFuelStops: [UUID: FuelStop] = [:]
        var firstReachableFuel = [Int: Double]()
        // Look-ahead is advisory. It gets a small budget of its own and must
        // never consume the 20 seconds reserved for building the actual chain.
        let fuelProbeDeadline = fuelReplan ? Date().addingTimeInterval(3) : .distantFuture
        if fuelReplan, baselineFailure == nil {
            RoutingDebugLog.shared.event(
                "fuel replan fromLeg=0 reason=\(startIndex == 0 ? "build" : "edit")"
            )
            for waypointIndex in 1..<itinerary.waypoints.count - 1 {
                let waypoint = itinerary.waypoints[waypointIndex]
                if let station = try? await selectedSource.fuelStation(
                    near: waypoint.coordinate, within: HopSearchPolicy.fuelWaypointSnapMeters
                ) {
                    let precedingLeg = itinerary.legs[waypointIndex - 1]
                    waypointFuelStops[waypoint.id] = FuelStop(
                        coordinate: station.coordinate,
                        stationID: station.id,
                        name: station.displayName,
                        afterRiderLegID: precedingLeg.id
                    )
                }
            }
            let knownOnwardFuelDistance = distanceToNextFuelOpportunity(
                itinerary: itinerary,
                baseline: baseline,
                firstReachableFuel: [:],
                waypointFuelStops: waypointFuelStops
            )
            // Index zero is never an onward leg for another rider leg. A leg
            // whose known route already reaches the next reset/destination in
            // one tank also needs no station probe. This is the common
            // Point 1 -> Point 2 -> Point 3 edit and must build immediately.
            for index in itinerary.legs.indices where itinerary.legs.count > 1 && index > 0 {
                guard Date() < fuelProbeDeadline else { break }
                guard (knownOnwardFuelDistance[index] ?? .infinity) > fuel.usableMeters + 1
                else { continue }
                guard let base = baseline[index],
                      let meters = base.distanceMeters
                else { continue }
                let riderLeg = itinerary.legs[index]
                let from = itinerary.waypoints[index].coordinate
                let to = itinerary.waypoints[index + 1].coordinate
                let probe = try? await selectedSource.fuelChain(FuelChainRequest(
                    profile: riderLeg.profile,
                    from: from,
                    to: to,
                    allowUnknown: riderLeg.allowUnknown,
                    usableRangeMeters: fuel.usableMeters,
                    firstLegMaxMeters: fuel.usableMeters,
                    requireFuelStopBeforeEnd: false,
                    minimumFuelStops: 0,
                    profileMeters: meters,
                    riderLegId: riderLeg.id.uuidString,
                    avoidEdgeIds: Array(itinerary.impassableEdgeIDs),
                    cleanMetroMultiplier: nil,
                    avoidMotorways: riderLeg.avoidMotorways,
                    probeFirstReachableStation: true,
                    windowTimeBudgetMs: min(
                        2_500,
                        max(100, Int(fuelProbeDeadline.timeIntervalSinceNow * 1_000))
                    )
                ))
                if let distance = probe?.firstReachableStationMeters {
                    firstReachableFuel[index] = distance
                }
            }
            committed = BuiltItinerary(
                generation: committed.generation,
                legs: committed.legs,
                riderLegStatus: committed.riderLegStatus,
                riderRoutes: committed.riderRoutes,
                waypointFuelStops: waypointFuelStops
            )
        }

        // Actual construction always receives its complete budget regardless
        // of whether an optional look-ahead probe succeeded, failed, or timed out.
        let fuelDeadline = fuelReplan ? Date().addingTimeInterval(20) : .distantFuture

        let onwardFuelDistance = distanceToNextFuelOpportunity(
            itinerary: itinerary,
            baseline: baseline,
            firstReachableFuel: firstReachableFuel,
            waypointFuelStops: waypointFuelStops
        )

        let lastBuildable = baselineFailure?.index ?? requestedEndIndex
        let finalStartIndex = resume == nil && fuelReplan ? 0 : startIndex
        let fuelAttemptBase = committed
        var excludedStationsByLeg = [Int: Set<String>]()
        var forcedFuelLegs = Set<Int>()
        var minimumFuelStopsByLeg = [Int: Int]()
        var attemptedStationSets = Set<String>()
        var fuelBacktrackAttempts = 0
        var lookaheadEnabled = true

        fuelAttempts: while true {
            if fuelReplan, Date() >= fuelDeadline {
                let failedIndex = min(max(0, finalStartIndex), itinerary.legs.count - 1)
                let failedID = itinerary.legs[failedIndex].id
                let message = "Fuel planning reached its 20-second itinerary budget."
                committed = fuelAttemptBase
                var markedUnknown = false
                for index in finalStartIndex..<lastBuildable {
                    guard let response = baseline[index] else { continue }
                    let riderLeg = itinerary.legs[index]
                    committed = replacing(
                        riderLegID: riderLeg.id,
                        with: [unconstrainedFuelLeg(
                            riderLeg: riderLeg,
                            from: itinerary.waypoints[index].coordinate,
                            to: itinerary.waypoints[index + 1].coordinate,
                            response: response,
                            fuelUsedAtStart: 0
                        )],
                        in: committed,
                        status: .fuelUnknown(index == failedIndex
                            ? message
                            : "Fuel continuity is unknown after the interrupted plan.")
                    )
                    markedUnknown = true
                }
                if !markedUnknown {
                    committed = markingFailed(failedID, message: message, in: committed)
                }
                RoutingDebugLog.shared.event(
                    "fuel planning budget exceeded riderLeg=\(failedID) attempts=\(fuelBacktrackAttempts)"
                )
                onProgress(committed)
                return committed
            }
            if fuelBacktrackAttempts > 0 { committed = fuelAttemptBase }
            var fuelUsed = resume != nil ? 0 : (fuelReplan ? 0 : carriedFuel(from: kept))
            var finalHistory = resume == nil && fuelReplan ? EdgeHistory() : EdgeHistory(legs: kept)
            for index in finalStartIndex..<lastBuildable {
            guard let base = baseline[index] else { break }
            let riderLeg = itinerary.legs[index]
            let reusedPrefix = index == startIndex ? (resume?.riderLegPrefix ?? []) : []
            do {
                let builtLegs = try await buildRiderLeg(
                    itinerary: itinerary,
                    index: index,
                    baseline: base,
                    baselineHistory: baselineHistory[index] ?? EdgeHistory(),
                    allBaseline: baseline,
                    fuelUsedAtStart: fuelUsed,
                    fuel: fuelReplan ? fuel : .routeOnly,
                    source: selectedSource,
                    history: finalHistory,
                    destinationFuelUsedLimitMeters: lookaheadEnabled && index + 1 < itinerary.legs.count
                        ? onwardFuelDistance[index + 1].map { max(0, fuel.usableMeters - $0) }
                        : nil,
                    waypointFuelReset: waypointFuelStops[itinerary.waypoints[index + 1].id],
                    forceFuelStop: forcedFuelLegs.contains(index),
                    minimumFuelStopsOverride: minimumFuelStopsByLeg[index],
                    excludedStationIDs: excludedStationsByLeg[index] ?? [],
                    resumeAfterStation: index == startIndex ? resume?.station : nil,
                    fuelDeadline: fuelDeadline,
                    defaultProfile: baselineProfiles[index] ?? riderLeg.profile,
                    onHop: { partial in
                        committed = replacing(
                            riderLegID: riderLeg.id,
                            with: reusedPrefix + partial,
                            in: committed,
                            status: .pending
                        )
                        onProgress(committed)
                    }
                )
                guard active(itinerary) else {
                    return dropped(itinerary, committed: committed)
                }
                committed = replacing(
                    riderLegID: riderLeg.id,
                    with: reusedPrefix + builtLegs,
                    in: committed,
                    status: .built
                )
                fuelUsed = builtLegs.last?.fuelUsedOnArrivalMeters ?? fuelUsed
                let requestPriorCount = finalHistory.edgeIDs.count
                let requestArrival = finalHistory.arrivalEdgeID ?? "nil"
                for builtLeg in builtLegs { finalHistory.append(builtLeg.response) }
                let meters = builtLegs.reduce(0) { $0 + ($1.response.distanceMeters ?? 0) }
                let weightedDirt = builtLegs.reduce(0.0) {
                    $0 + Double($1.response.dirtPercent) * ($1.response.distanceMeters ?? 0)
                }
                let dirt = meters > 0 ? Int((weightedDirt / meters).rounded()) : 0
                RoutingDebugLog.shared.event(
                    "build leg riderLeg=\(riderLeg.id) " +
                        "fuelStops=\(builtLegs.filter { $0.endsAtFuelStop != nil }.count) " +
                        "meters=\(Int(meters)) dirt%=\(dirt)"
                )
                let backtrackMeters = builtLegs.reduce(0.0) {
                    $0 + ($1.response.backtrackMeters ?? 0)
                }
                let backtrackPct = meters > 0 ? backtrackMeters / meters * 100 : 0
                RoutingDebugLog.shared.event(
                    "build leg riderLeg=\(riderLeg.id) priorEdges=\(requestPriorCount) " +
                        "arrivalEdge=\(requestArrival) backtrackPct=\(String(format: "%.1f", backtrackPct))"
                )
                let restrictedMeters = builtLegs.reduce(0.0) {
                    $0 + ($1.response.restrictedMeters ?? 0)
                }
                let restrictedReason = builtLegs.compactMap(\.response.restrictedReason).first ?? "none"
                RoutingDebugLog.shared.event(
                    "build leg riderLeg=\(riderLeg.id) restrictedMeters=\(Int(restrictedMeters)) " +
                        "restrictedReason=\(restrictedReason)"
                )
                onProgress(committed)
            } catch is CancellationError {
                return dropped(itinerary, committed: committed, cancelled: true)
            } catch {
                guard active(itinerary) else {
                    return dropped(itinerary, committed: committed)
                }
                if case RoutingError.fuelUnknown(let message) = error {
                    committed = replacing(
                        riderLegID: riderLeg.id,
                        with: [unconstrainedFuelLeg(
                            riderLeg: riderLeg,
                            from: itinerary.waypoints[index].coordinate,
                            to: itinerary.waypoints[index + 1].coordinate,
                            response: base,
                            fuelUsedAtStart: fuelUsed
                        )],
                        in: committed,
                        status: .fuelUnknown(message)
                    )
                    for laterIndex in (index + 1)..<lastBuildable {
                        guard let laterBase = baseline[laterIndex] else { continue }
                        let laterLeg = itinerary.legs[laterIndex]
                        committed = replacing(
                            riderLegID: laterLeg.id,
                            with: [unconstrainedFuelLeg(
                                riderLeg: laterLeg,
                                from: itinerary.waypoints[laterIndex].coordinate,
                                to: itinerary.waypoints[laterIndex + 1].coordinate,
                                response: laterBase,
                                fuelUsedAtStart: 0
                            )],
                            in: committed,
                            status: .fuelUnknown("Fuel continuity is unknown after the preceding leg.")
                        )
                    }
                    RoutingDebugLog.shared.event(
                        "fuel unknown riderLeg=\(riderLeg.id) msg=\(message)"
                    )
                    onProgress(committed)
                    return committed
                }
                let explicitFuelGap: Bool = {
                    if case RoutingError.fuelGap = error { return true }
                    return false
                }()
                if explicitFuelGap,
                   fuelReplan, index == 0, lookaheadEnabled, fuelBacktrackAttempts < 2 {
                    lookaheadEnabled = false
                    fuelBacktrackAttempts += 1
                    RoutingDebugLog.shared.event(
                        "fuel backtrack failedLeg=\(riderLeg.id) replanLeg=\(riderLeg.id) " +
                            "attempt=\(fuelBacktrackAttempts) reason=probe_inconclusive"
                    )
                    continue fuelAttempts
                }
                if explicitFuelGap,
                   fuelReplan, index > 0, fuelBacktrackAttempts < 2 {
                    let priorIndex = index - 1
                    let priorLegID = itinerary.legs[priorIndex].id
                    let priorStops = committed.legs
                        .filter { $0.riderLegID == priorLegID }
                        .compactMap { $0.endsAtFuelStop?.stationID }
                    let signature = "\(priorLegID.uuidString):\(priorStops.joined(separator: ">"))"
                    guard attemptedStationSets.insert(signature).inserted else {
                        let message = "No different route-connected fuel chain is available."
                        (committed, _) = markingFuelGap(
                            itinerary: itinerary,
                            baseline: baseline,
                            lastBuildable: lastBuildable,
                            committed: committed,
                            index: index,
                            fuel: fuel,
                            fuelUsed: fuelUsed,
                            reason: message
                        )
                        RoutingDebugLog.shared.event(
                            "fuel backtrack abort riderLeg=\(riderLeg.id) reason=identical_station_set " +
                                "signature=\(signature)"
                        )
                        onProgress(committed)
                        return committed
                    }
                    if let latest = priorStops.last {
                        excludedStationsByLeg[priorIndex, default: []].insert(latest)
                    } else {
                        forcedFuelLegs.insert(priorIndex)
                    }
                    fuelBacktrackAttempts += 1
                    if fuelBacktrackAttempts == 2 {
                        minimumFuelStopsByLeg[priorIndex] = max(1, priorStops.count + 1)
                    }
                    RoutingDebugLog.shared.event(
                        "fuel backtrack failedLeg=\(riderLeg.id) replanLeg=\(priorLegID) " +
                            "attempt=\(fuelBacktrackAttempts) stationSet=\(signature) " +
                            "minimumStops=\(minimumFuelStopsByLeg[priorIndex] ?? 0)"
                    )
                    continue fuelAttempts
                }
                if case RoutingError.fuelGap(let serverGap) = error {
                    let gap: FuelGap
                    (committed, gap) = markingFuelGap(
                        itinerary: itinerary,
                        baseline: baseline,
                        lastBuildable: lastBuildable,
                        committed: committed,
                        index: index,
                        fuel: fuel,
                        fuelUsed: fuelUsed,
                        reason: serverGap.reason
                    )
                    RoutingDebugLog.shared.event(
                        "fuel gap riderLeg=\(riderLeg.id) gapMeters=\(Int(gap.gapMeters)) " +
                            "overByMeters=\(Int(gap.overByMeters)) attempts=\(fuelBacktrackAttempts)"
                    )
                    onProgress(committed)
                    return committed
                }
                // A transport/time-budget failure is not proof of an impossible
                // fuel gap. Keep the already routed geometry explorable and
                // label fuel continuity honestly as unknown.
                let message = "Fuel planning unavailable: \(error.localizedDescription)"
                committed = replacing(
                    riderLegID: riderLeg.id,
                    with: [unconstrainedFuelLeg(
                        riderLeg: riderLeg,
                        from: itinerary.waypoints[index].coordinate,
                        to: itinerary.waypoints[index + 1].coordinate,
                        response: base,
                        fuelUsedAtStart: fuelUsed
                    )],
                    in: committed,
                    status: .fuelUnknown(message)
                )
                for laterIndex in (index + 1)..<lastBuildable {
                    guard let laterBase = baseline[laterIndex] else { continue }
                    let laterLeg = itinerary.legs[laterIndex]
                    committed = replacing(
                        riderLegID: laterLeg.id,
                        with: [unconstrainedFuelLeg(
                            riderLeg: laterLeg,
                            from: itinerary.waypoints[laterIndex].coordinate,
                            to: itinerary.waypoints[laterIndex + 1].coordinate,
                            response: laterBase,
                            fuelUsedAtStart: 0
                        )],
                        in: committed,
                        status: .fuelUnknown("Fuel continuity is unknown after the preceding leg.")
                    )
                }
                RoutingDebugLog.shared.event(
                    "fuel unavailable riderLeg=\(riderLeg.id) msg=\(message)"
                )
                onProgress(committed)
                return committed
            }
            }
            break fuelAttempts
        }

        if let failure = baselineFailure {
            let legID = itinerary.legs[failure.index].id
            committed = markingFailed(legID, message: failure.message, in: committed)
            RoutingDebugLog.shared.event(
                "build failed riderLeg=\(legID) msg=\(failure.message)"
            )
            onProgress(committed)
            return appendingPreservedSuffix(
                preservedSuffix,
                statuses: statuses,
                routes: reusableRoutes,
                to: committed
            )
        }

        RoutingDebugLog.shared.event(
            "build committed gen=\(itinerary.generation) legs=\(committed.legs.count)"
        )
        return appendingPreservedSuffix(
            preservedSuffix,
            statuses: statuses,
            routes: reusableRoutes,
            to: committed
        )
    }

    private func buildForwardFuelItinerary(
        _ itinerary: RiderItinerary,
        startIndex: Int,
        endIndex: Int,
        resume: FuelResume?,
        kept: [BuiltLeg],
        preservedSuffix: [BuiltLeg],
        preservedStatuses: [UUID: LegStatus],
        preservedRoutes: [UUID: RouteResponse],
        preservedWaypointFuelStops: [UUID: FuelStop],
        preservedArrivalFuelUsedByLeg: [UUID: Double],
        fuel: FuelRangePrefs.Snapshot,
        source: any RoutingSource,
        allowFuelRewind: Bool,
        forcedFuelLegIndex: Int? = nil,
        recoveryDepth: Int = 0,
        excludedFuelStationsByLeg: [Int: Set<String>] = [:],
        onFuelStatus: @MainActor (String) -> Void,
        onProgress: @MainActor (BuiltItinerary) -> Void
    ) async -> BuiltItinerary {
        var statuses = preservedStatuses
        for index in startIndex..<endIndex where itinerary.legs.indices.contains(index) {
            statuses[itinerary.legs[index].id] = .pending
        }
        if resume != nil, itinerary.legs.indices.contains(startIndex) {
            statuses[itinerary.legs[startIndex].id] = .pending
        }
        var waypointFuelStops = preservedWaypointFuelStops
        let firstWaypointToProbe = min(itinerary.waypoints.count, startIndex + 1)
        let waypointProbeEnd = min(itinerary.waypoints.count, endIndex + 1)
        if firstWaypointToProbe < waypointProbeEnd {
            for waypointIndex in firstWaypointToProbe..<waypointProbeEnd {
                let waypoint = itinerary.waypoints[waypointIndex]
                if let station = try? await source.fuelStation(
                    near: waypoint.coordinate,
                    within: HopSearchPolicy.fuelWaypointSnapMeters
                ) {
                    waypointFuelStops[waypoint.id] = FuelStop(
                        coordinate: station.coordinate,
                        stationID: station.id,
                        name: station.displayName,
                        afterRiderLegID: itinerary.legs[waypointIndex - 1].id
                    )
                } else {
                    // Coordinates inside the rebuilt rider-leg range may have
                    // moved away from a previously detected pump.
                    waypointFuelStops[waypoint.id] = nil
                }
            }
        }

        // A final waypoint is safe only when the fuel remaining on arrival can
        // reach the nearest pump by road. The search is deliberately 360°: with
        // no later rider waypoint, "forward" has no useful meaning. A final
        // waypoint already on a packed pump resets the tank instead.
        let finalWaypoint = itinerary.waypoints.last
        let finalWaypointIsFuel = finalWaypoint.map { waypointFuelStops[$0.id] != nil } ?? false
        var finalEscapeFuelMeters: Double?
        var finalEscapeVerificationWarning: String?
        if endIndex == itinerary.legs.count,
           let finalWaypoint,
           !finalWaypointIsFuel,
           !source.supportsCombinedFuelPlanning {
            onFuelStatus("Checking fuel after destination")
            do {
                let escape = try await source.fuelChain(FuelChainRequest(
                    profile: .cleanest,
                    from: finalWaypoint.coordinate,
                    to: finalWaypoint.coordinate,
                    allowUnknown: false,
                    usableRangeMeters: fuel.usableMeters,
                    firstLegMaxMeters: fuel.usableMeters,
                    requireFuelStopBeforeEnd: false,
                    minimumFuelStops: 0,
                    profileMeters: 0,
                    riderLegId: "destination-escape",
                    probeFirstReachableStation: true,
                    windowTimeBudgetMs: 2_500,
                    forwardFeeler: true
                ))
                if escape.isComplete {
                    // Nil after an exhaustive full-tank probe means the
                    // destination itself has no safe fuel escape. A zero arrival
                    // limit forces an honest gap instead of pretending otherwise.
                    finalEscapeFuelMeters = escape.firstReachableStationMeters
                        .map { min(fuel.usableMeters, max(0, $0)) }
                        ?? fuel.usableMeters
                    RoutingDebugLog.shared.event(
                        "fuel destination escape meters=\(Int(finalEscapeFuelMeters ?? 0)) "
                            + "arrivalLimit=\(Int(max(0, fuel.usableMeters - (finalEscapeFuelMeters ?? 0))))"
                    )
                } else {
                    finalEscapeVerificationWarning = escape.message
                        ?? "Fuel safety after the destination could not be checked."
                }
            } catch {
                finalEscapeVerificationWarning =
                    "Fuel safety after the destination could not be checked: \(error.localizedDescription)"
                RoutingDebugLog.shared.event(
                    "fuel destination escape unavailable msg=\(error.localizedDescription)"
                )
            }
        }

        var committed = BuiltItinerary(
            generation: itinerary.generation,
            legs: kept,
            riderLegStatus: statuses,
            riderRoutes: preservedRoutes,
            waypointFuelStops: waypointFuelStops
        )
        var history = EdgeHistory(legs: kept)
        let revalidatedPrefix = revalidatedFuelPrefix(
            kept,
            itinerary: itinerary,
            waypointFuelStops: waypointFuelStops,
            usableRangeMeters: fuel.usableMeters
        )
        if allowFuelRewind,
           resume == nil,
           let invalidIndex = revalidatedPrefix.firstInvalidRiderLegIndex,
           invalidIndex < startIndex {
            let repairedPrefix = builtPrefix(
                before: invalidIndex,
                from: kept,
                itinerary: itinerary
            )
            RoutingDebugLog.shared.event(
                "fuel prefix invalid gen=\(itinerary.generation) "
                    + "replanLeg=\(invalidIndex) keptLegs=\(repairedPrefix.count)"
            )
            return await buildForwardFuelItinerary(
                itinerary,
                startIndex: invalidIndex,
                endIndex: endIndex,
                resume: nil,
                kept: repairedPrefix,
                preservedSuffix: preservedSuffix,
                preservedStatuses: preservedStatuses,
                preservedRoutes: preservedRoutes,
                preservedWaypointFuelStops: preservedWaypointFuelStops,
                preservedArrivalFuelUsedByLeg: preservedArrivalFuelUsedByLeg,
                fuel: fuel,
                source: source,
                allowFuelRewind: allowFuelRewind,
                forcedFuelLegIndex: invalidIndex,
                recoveryDepth: recoveryDepth + 1,
                excludedFuelStationsByLeg: excludedFuelStationsByLeg,
                onFuelStatus: onFuelStatus,
                onProgress: onProgress
            )
        }
        var fuelUsed = resume == nil
            ? (revalidatedPrefix.firstInvalidRiderLegIndex == nil
                ? revalidatedPrefix.fuelUsedMeters
                : 0)
            : 0
        // This is an inactivity watchdog, not a cap on total itinerary time.
        // Long routes may legitimately need many quick fuel hops; every proven
        // forward leg renews the window while stalled searches still terminate.
        var progressWatchdog = FuelPlanningProgressWatchdog()

        if let resume {
            RoutingDebugLog.shared.event(
                "fuel forward resume gen=\(itinerary.generation) "
                    + "fromLeg=\(startIndex) station=\(resume.station.stationID ?? "unknown") "
                    + "keptLegs=\(kept.count)"
            )
        }

        for index in startIndex..<endIndex {
            let riderLeg = itinerary.legs[index]
            let riderDestination = itinerary.waypoints[index + 1]
            // A scoped option edit inherits the old arrival-fuel ceiling at
            // its boundary. Meeting or improving that ceiling proves the
            // untouched suffix remains at least as safe as it was before,
            // without probing or rebuilding any later rider leg.
            let inheritedArrivalFuelLimit = index == endIndex - 1
                && endIndex < itinerary.legs.count
                && waypointFuelStops[riderDestination.id] == nil
                ? preservedArrivalFuelUsedByLeg[riderLeg.id]
                : nil
            let needsOnwardFuel = inheritedArrivalFuelLimit == nil
                && index + 1 < itinerary.legs.count
                && waypointFuelStops[riderDestination.id] == nil
            let onwardFuelMeters: Double?
            if needsOnwardFuel {
                let nextLeg = itinerary.legs[index + 1]
                let nextFrom = riderDestination.coordinate
                let nextTo = itinerary.waypoints[index + 2].coordinate
                // A proven profile-routed pump is preferred. When no pump is
                // returned, use route distance only if that next leg is
                // already built. A full on-device build may measure the next
                // leg once because it has no combined route-and-fuel response;
                // incremental edits never issue that duplicate lookup.
                let cachedMeters = (kept + preservedSuffix)
                    .filter { $0.riderLegID == nextLeg.id }
                    .reduce(0.0) { $0 + ($1.response.distanceMeters ?? 0) }
                if source.supportsCombinedFuelPlanning {
                    // The live endpoint plans the profile route and its fuel
                    // chain together. A speculative next-leg request here used
                    // to cold-load another regional graph, compete with the
                    // real request, and often time out before returning useful
                    // information. Build the actual next leg once. Scoped
                    // edits instead inherit the preserved suffix's arrival
                    // ceiling above.
                    onwardFuelMeters = cachedMeters > 0 ? cachedMeters : nil
                    RoutingDebugLog.shared.event(
                        "fuel onward probe skipped gen=\(itinerary.generation) "
                            + "riderLeg=\(riderLeg.id) nextLeg=\(nextLeg.id) "
                            + "reason=combined_single_pass "
                            + "cachedMeters=\(cachedMeters > 0 ? String(Int(cachedMeters)) : "-")"
                    )
                } else {
                    let probe = try? await source.fuelChain(FuelChainRequest(
                        profile: nextLeg.profile,
                        from: nextFrom,
                        to: nextTo,
                        allowUnknown: nextLeg.profile == .cleanest ? false : nextLeg.allowUnknown,
                        usableRangeMeters: fuel.usableMeters,
                        firstLegMaxMeters: fuel.usableMeters,
                        requireFuelStopBeforeEnd: false,
                        minimumFuelStops: 0,
                        profileMeters: straightLineMeters(nextFrom, nextTo),
                        riderLegId: nextLeg.id.uuidString,
                        avoidEdgeIds: Array(itinerary.impassableEdgeIDs),
                        cleanMetroMultiplier: nil,
                        avoidMotorways: nextLeg.avoidMotorways,
                        probeFirstReachableStation: true,
                        windowTimeBudgetMs: min(
                            2_500,
                            max(100, progressWatchdog.remainingMilliseconds())
                        )
                    ))
                    if let firstPumpMeters = probe?.firstReachableStationMeters {
                        onwardFuelMeters = firstPumpMeters
                    } else if cachedMeters > 0 {
                        onwardFuelMeters = cachedMeters
                    } else if startIndex == 0,
                              let response = try? await source.route(routeRequest(
                                  profile: nextLeg.profile,
                                  allowUnknown: nextLeg.profile == .cleanest
                                      ? false
                                      : nextLeg.allowUnknown,
                                  from: nextFrom,
                                  to: nextTo,
                                  avoidEdgeIDs: itinerary.impassableEdgeIDs,
                                  maxPathMeters: nil,
                                  history: EdgeHistory(),
                                  avoidMotorways: nextLeg.avoidMotorways,
                                  preferBackRoads: nextLeg.preferBackRoads
                              )),
                              let meters = try? responseMeters(response) {
                        onwardFuelMeters = meters
                    } else {
                        onwardFuelMeters = nil
                    }
                }
            } else if index == itinerary.legs.count - 1, !finalWaypointIsFuel {
                onwardFuelMeters = finalEscapeFuelMeters
            } else {
                onwardFuelMeters = nil
            }
            let arrivalFuelLimit = inheritedArrivalFuelLimit ?? onwardFuelMeters.map {
                max(0, fuel.usableMeters - $0)
            }
            let resumesThisLeg = index == startIndex ? resume : nil
            var current = resumesThisLeg?.station.coordinate
                ?? itinerary.waypoints[index].coordinate
            var builtLegs = resumesThisLeg?.riderLegPrefix ?? []
            var excludedStations = excludedFuelStationsByLeg[index] ?? []
            var forceFuelStop = forcedFuelLegIndex == index
            var attempts = 0
            var lastRejectedStationID: String?
            var lastRejectedReason: String?
            func finishWithFuelAdvisory(_ issue: FuelAdvisoryIssue) async -> BuiltItinerary {
                await buildAdvisoryRemainder(
                    itinerary: itinerary,
                    startIndex: index,
                    endIndex: endIndex,
                    current: current,
                    builtLegPrefix: builtLegs,
                    fuelUsedAtCurrent: fuelUsed,
                    issue: issue,
                    committed: committed,
                    preservedSuffix: preservedSuffix,
                    preservedStatuses: preservedStatuses,
                    preservedRoutes: preservedRoutes,
                    fuel: fuel,
                    source: source,
                    history: history,
                    onProgress: onProgress
                )
            }

            while true {
                guard active(itinerary) else {
                    return dropped(itinerary, committed: committed, cancelled: true)
                }
                guard !progressWatchdog.isExpired() else {
                    let message = "Fuel planning made no forward progress for 28 seconds."
                    let diagnostic = [
                        message,
                        lastRejectedStationID.map { "last selected station=\($0)" },
                        lastRejectedReason.map { "rejection=\($0)" }
                    ].compactMap { $0 }.joined(separator: "; ")
                    RoutingDebugLog.shared.event(
                        "fuel progress timeout gen=\(itinerary.generation) "
                            + "riderLeg=\(riderLeg.id) attempts=\(attempts) committed=\(committed.legs.count) "
                            + "lastRejectedStation=\(lastRejectedStationID ?? "-") "
                            + "lastRejectedCause=\(lastRejectedReason ?? "-")"
                    )
                    return await finishWithFuelAdvisory(.unknown(diagnostic))
                }
                attempts += 1
                guard attempts <= 16 else {
                    return await finishWithFuelAdvisory(.unknown(
                        "Fuel planning could not find a stable forward sequence."
                    ))
                }

                let remaining = max(0, fuel.usableMeters - fuelUsed)
                guard remaining > 0 else {
                    return await finishWithFuelAdvisory(.gap(
                        "No usable fuel remains before the next waypoint."
                    ))
                }

                let departureID = builtLegs.last?.endsAtFuelStop?.stationID
                    ?? riderLeg.from.uuidString
                let activeProfile = riderLeg.hopOverrides[departureID]
                    ?? riderLeg.profile
                let activeAvoidMotorways = riderLeg.avoidsMajorHighways(
                    departingFrom: departureID,
                    effectiveProfile: activeProfile
                )
                let requiredStationID = riderLeg.fuelStopOverrides[departureID]
                let committedFuelStopCount = builtLegs.filter {
                    $0.endsAtFuelStop != nil
                }.count
                onFuelStatus(committedFuelStopCount == 0
                    ? "Checking fuel range"
                    : "Checking range after fuel stop \(committedFuelStopCount)")

                // A rider pin placed on a packed pump is already the next
                // useful fuel anchor. Build that real leg directly up to the
                // hard range ceiling; the comfort window must not manufacture
                // an earlier automatic stop before a chosen refuel waypoint.
                if !source.supportsCombinedFuelPlanning,
                   waypointFuelStops[riderDestination.id] != nil,
                   requiredStationID == nil,
                   let response = try? await source.route(routeRequest(
                       profile: activeProfile,
                       allowUnknown: activeProfile == .cleanest ? false : riderLeg.allowUnknown,
                       from: current,
                       to: riderDestination.coordinate,
                       avoidEdgeIDs: itinerary.impassableEdgeIDs,
                       maxPathMeters: remaining,
                       history: history,
                       avoidMotorways: activeAvoidMotorways,
                       preferBackRoads: riderLeg.preferBackRoads
                   )),
                   let meters = try? responseMeters(response),
                   meters <= remaining + 1 {
                    let built = BuiltLeg(
                        riderLegID: riderLeg.id,
                        fromCoordinate: current,
                        toCoordinate: riderDestination.coordinate,
                        endsAtFuelStop: nil,
                        response: response,
                        fuelUsedOnArrivalMeters: 0,
                        routeProfile: activeProfile
                    )
                    builtLegs.append(built)
                    history.append(response)
                    fuelUsed = 0
                    current = riderDestination.coordinate
                    statuses[riderLeg.id] = .built
                    committed = replacing(
                        riderLegID: riderLeg.id,
                        with: builtLegs,
                        in: committed,
                        status: .built
                    )
                    progressWatchdog.recordProgress()
                    onProgress(committed)
                    onFuelStatus("Leg complete")
                    break
                }

                // A cross-province request deliberately advances one real
                // pump at a time. The regional service selects that anchor
                // from graph reachability, this client proves the requested
                // riding profile to it, and the next pump receives a fresh
                // planning window. Regional seams are never fuel resets.
                let crossesProvinceBoundary = GraphPackStore.endpointsCrossProvince([
                    current.locationCoordinate,
                    riderDestination.coordinate.locationCoordinate
                ])

                // A multi-stop response is only safe when every generated hop
                // uses the same riding profile and one regional runtime can
                // return all of the corresponding route geometry.
                let canConsumeCombinedWindow = source.supportsCombinedFuelPlanning
                    && riderLeg.hopOverrides.isEmpty
                    && !crossesProvinceBoundary
                let chain: FuelChainResponse
                let requestBudgetMs = min(
                    Self.liveFuelWindowBudgetMs,
                    max(100, progressWatchdog.remainingMilliseconds())
                )
                RoutingDebugLog.shared.event(
                    "fuel operation begin gen=\(itinerary.generation) "
                        + "riderLeg=\(riderLeg.id) attempt=\(attempts) "
                        + "profile=\(activeProfile.rawValue) "
                        + "from=\(String(format: "%.5f,%.5f", current.latitude, current.longitude)) "
                        + "to=\(String(format: "%.5f,%.5f", riderDestination.coordinate.latitude, riderDestination.coordinate.longitude)) "
                        + "used=\(Int(fuelUsed))m remaining=\(Int(remaining))m "
                        + "forceStop=\(forceFuelStop ? 1 : 0) "
                        + "requiredStation=\(requiredStationID ?? "-") "
                        + "windowAnchor=\(builtLegs.last?.endsAtFuelStop == nil ? "rider" : "pump") "
                        + "crossProvince=\(crossesProvinceBoundary ? 1 : 0) "
                        + "windowStops=\(canConsumeCombinedWindow ? 4 : 1) "
                        + "budgetMs=\(requestBudgetMs)"
                )
                do {
                    chain = try await source.fuelChain(FuelChainRequest(
                        profile: activeProfile,
                        from: current,
                        to: riderDestination.coordinate,
                        allowUnknown: activeProfile == .cleanest ? false : riderLeg.allowUnknown,
                        usableRangeMeters: fuel.usableMeters,
                        firstLegMaxMeters: remaining,
                        requireFuelStopBeforeEnd: forceFuelStop,
                        minimumFuelStops: forceFuelStop ? 1 : 0,
                        destinationFuelUsedLimitMeters: arrivalFuelLimit,
                        profileMeters: straightLineMeters(current, riderDestination.coordinate),
                        riderLegId: riderLeg.id.uuidString,
                        avoidEdgeIds: Array(itinerary.impassableEdgeIDs),
                        cleanMetroMultiplier: nil,
                        avoidMotorways: activeAvoidMotorways,
                        priorEdgeIds: history.edgeIDs,
                        arrivalEdgeId: history.arrivalEdgeID,
                        backtrackFactor: 4,
                        excludedStationIds: Array(excludedStations),
                        windowMaxStops: canConsumeCombinedWindow ? 4 : 1,
                        allowPartialWindow: true,
                        windowTimeBudgetMs: requestBudgetMs,
                        requiredFirstStationId: requiredStationID,
                        forwardFeeler: crossesProvinceBoundary,
                        routeFirstPlan: source.supportsCombinedFuelPlanning,
                        ensureDestinationFuelEscape: source.supportsCombinedFuelPlanning
                            && index == itinerary.legs.count - 1
                            && !finalWaypointIsFuel
                    ))
                } catch is CancellationError {
                    return dropped(itinerary, committed: committed, cancelled: true)
                } catch {
                    RoutingDebugLog.shared.routeFailure(
                        error,
                        context: "fuel operation gen=\(itinerary.generation) "
                            + "riderLeg=\(riderLeg.id) attempt=\(attempts) "
                            + "active=\(active(itinerary) ? 1 : 0)"
                    )
                    guard active(itinerary) else {
                        return dropped(
                            itinerary,
                            committed: committed,
                            cancelled: Task.isCancelled
                        )
                    }
                    return await finishWithFuelAdvisory(.unknown(
                        "Fuel planning unavailable: \(error.localizedDescription)"
                    ))
                }

                if chain.isFuelUnknown {
                    return await finishWithFuelAdvisory(.unknown(
                        chain.message ?? "Fuel data is unavailable for this part of the route."
                    ))
                }
                if chain.isGap {
                    if allowFuelRewind,
                       resume == nil,
                       index > 0,
                       recoveryDepth < min(16, itinerary.legs.count) {
                        let priorIndex = index - 1
                        let priorStops = committed.legs
                            .filter { $0.riderLegID == itinerary.legs[priorIndex].id }
                            .compactMap(\.endsAtFuelStop?.stationID)
                        var recoveryExclusions = excludedFuelStationsByLeg
                        if let latestStop = priorStops.last {
                            recoveryExclusions[priorIndex, default: []].insert(latestStop)
                        }
                        let repairedPrefix = builtPrefix(
                            before: priorIndex,
                            from: committed.legs,
                            itinerary: itinerary
                        )
                        RoutingDebugLog.shared.event(
                            "fuel rewind failedLeg=\(index) replanLeg=\(priorIndex) "
                                + "attempt=\(recoveryDepth + 1) keptLegs=\(repairedPrefix.count)"
                        )
                        onFuelStatus("Rechecking an earlier fuel stop")
                        return await buildForwardFuelItinerary(
                            itinerary,
                            startIndex: priorIndex,
                            endIndex: endIndex,
                            resume: nil,
                            kept: repairedPrefix,
                            preservedSuffix: preservedSuffix,
                            preservedStatuses: preservedStatuses,
                            preservedRoutes: preservedRoutes,
                            preservedWaypointFuelStops: preservedWaypointFuelStops,
                            preservedArrivalFuelUsedByLeg: preservedArrivalFuelUsedByLeg,
                            fuel: fuel,
                            source: source,
                            allowFuelRewind: allowFuelRewind,
                            forcedFuelLegIndex: priorIndex,
                            recoveryDepth: recoveryDepth + 1,
                            excludedFuelStationsByLeg: recoveryExclusions,
                            onFuelStatus: onFuelStatus,
                            onProgress: onProgress
                        )
                    }
                    return await finishWithFuelAdvisory(.gap(
                        chain.message ?? "No forward fuel stop is reachable within range."
                    ))
                }

                let selectedStop = chain.stops?.first
                guard selectedStop != nil || chain.reachesDestination else {
                    return await finishWithFuelAdvisory(.unknown(
                        "Fuel planning returned no forward anchor."
                    ))
                }

                // The live planner routes the selected chain while the graph
                // is already loaded. Consume every returned hop instead of
                // throwing those routes away and asking another serverless
                // invocation to calculate each one again.
                let plannedStops = chain.stops ?? []
                var plannedTargets: [(coordinate: RouteCoordinate, stop: FuelChainStop?)] =
                    plannedStops.map { ($0.coordinate, Optional($0)) }
                if chain.reachesDestination {
                    plannedTargets.append((riderDestination.coordinate, nil))
                }
                if source.supportsCombinedFuelPlanning,
                   let plannedRoutes = chain.routes,
                   !plannedTargets.isEmpty,
                   plannedRoutes.count >= plannedTargets.count {
                    // Validate the entire returned window before committing any
                    // hop. A malformed later hop must not leave a half-consumed
                    // chain and then rebuild the first stop a second time.
                    let plannedMeters = plannedTargets.indices.compactMap { hopIndex in
                        try? responseMeters(plannedRoutes[hopIndex])
                    }
                    let routesAreUsable = plannedMeters.count == plannedTargets.count
                        && plannedMeters.indices.allSatisfy { hopIndex in
                            let cap = hopIndex == 0 ? remaining : fuel.usableMeters
                            return plannedMeters[hopIndex] <= cap + 1
                        }
                    if !routesAreUsable {
                        RoutingDebugLog.shared.event(
                            "fuel combined fallback riderLeg=\(riderLeg.id) "
                                + "routes=\(plannedRoutes.count) targets=\(plannedTargets.count)"
                        )
                    } else {
                        var departureCandidateID = "start"
                        for hopIndex in plannedTargets.indices {
                            let planned = plannedTargets[hopIndex]
                            let response = plannedRoutes[hopIndex]
                            let meters = plannedMeters[hopIndex]
                            let number = builtLegs.filter { $0.endsAtFuelStop != nil }.count + 1
                            onFuelStatus(planned.stop == nil
                                ? "No fuel stop required"
                                : "Creating fuel stop \(number)")
                            let fuelStop = planned.stop.map {
                                FuelStop(
                                    coordinate: $0.coordinate,
                                    stationID: $0.id,
                                    name: $0.displayName,
                                    afterRiderLegID: riderLeg.id
                                )
                            }
                            let resetsAtWaypoint = planned.stop == nil
                                && waypointFuelStops[riderDestination.id] != nil
                            let arrivalFuel = fuelStop != nil || resetsAtWaypoint
                                ? 0
                                : fuelUsed + meters
                            let validFuelTargets = fuelStop == nil ? [] : (chain.stationCandidates ?? []).filter {
                                $0.departureId == departureCandidateID
                                    && $0.validForward == true
                                    && $0.latitude != nil
                                    && $0.longitude != nil
                            }
                            let built = BuiltLeg(
                                riderLegID: riderLeg.id,
                                fromCoordinate: current,
                                toCoordinate: planned.coordinate,
                                endsAtFuelStop: fuelStop,
                                response: response,
                                fuelUsedOnArrivalMeters: arrivalFuel,
                                routeProfile: activeProfile,
                                validFuelTargets: validFuelTargets
                            )
                            builtLegs.append(built)
                            history.append(response)
                            fuelUsed = arrivalFuel
                            current = planned.coordinate
                            statuses[riderLeg.id] = planned.stop == nil ? .built : .pending
                            committed = replacing(
                                riderLegID: riderLeg.id,
                                with: builtLegs,
                                in: committed,
                                status: statuses[riderLeg.id] ?? .pending
                            )
                            progressWatchdog.recordProgress()
                            RoutingDebugLog.shared.event(
                                "fuel combined progress gen=\(itinerary.generation) "
                                    + "riderLeg=\(riderLeg.id) hop=\(hopIndex + 1)/\(plannedTargets.count) "
                                    + "kind=\(planned.stop == nil ? "waypoint" : "pump")"
                            )
                            onProgress(committed)
                            if let stop = planned.stop {
                                excludedStations.insert(stop.id)
                                departureCandidateID = stop.id
                                onFuelStatus("Fuel stop \(number) added")
                            }
                        }
                        if chain.reachesDestination {
                            statuses[riderLeg.id] = .built
                            committed = replacing(
                                riderLegID: riderLeg.id,
                                with: builtLegs,
                                in: committed,
                                status: .built
                            )
                            onProgress(committed)
                            onFuelStatus("Leg complete")
                            break
                        }
                        forceFuelStop = false
                        continue
                    }
                }

                let target = selectedStop?.coordinate ?? riderDestination.coordinate
                let nextFuelStopNumber = committedFuelStopCount + 1
                onFuelStatus(selectedStop == nil
                    ? "No fuel stop required"
                    : "Creating fuel stop \(nextFuelStopNumber)")
                do {
                    let response: RouteResponse
                    if let planned = chain.routes?.first,
                       (try? responseMeters(planned)) != nil {
                        response = planned
                    } else {
                        response = try await source.route(routeRequest(
                            profile: activeProfile,
                            allowUnknown: activeProfile == .cleanest ? false : riderLeg.allowUnknown,
                            from: current,
                            to: target,
                            avoidEdgeIDs: itinerary.impassableEdgeIDs,
                            maxPathMeters: remaining,
                            regionalHopMinimumMeters: chain.graphMeters ?? [],
                            history: history,
                            avoidMotorways: activeAvoidMotorways,
                            preferBackRoads: riderLeg.preferBackRoads
                        ))
                    }
                    let meters = try responseMeters(response)
                    guard meters <= remaining + 1 else { throw RoutingError.invalidResponse }
                    let fuelStop = selectedStop.map {
                        FuelStop(
                            coordinate: $0.coordinate,
                            stationID: $0.id,
                            name: $0.displayName,
                            afterRiderLegID: riderLeg.id
                        )
                    }
                    let resetsAtWaypoint = selectedStop == nil
                        && waypointFuelStops[riderDestination.id] != nil
                    let arrivalFuel = fuelStop != nil || resetsAtWaypoint
                        ? 0
                        : fuelUsed + meters
                    let validFuelTargets = fuelStop == nil ? [] : (chain.stationCandidates ?? []).filter {
                        $0.departureId == "start"
                            && $0.validForward == true
                            && $0.latitude != nil
                            && $0.longitude != nil
                    }
                    let built = BuiltLeg(
                        riderLegID: riderLeg.id,
                        fromCoordinate: current,
                        toCoordinate: target,
                        endsAtFuelStop: fuelStop,
                        response: response,
                        fuelUsedOnArrivalMeters: arrivalFuel,
                        routeProfile: activeProfile,
                        validFuelTargets: validFuelTargets
                    )
                    builtLegs.append(built)
                    history.append(response)
                    fuelUsed = arrivalFuel
                    current = target
                    let completedWithUnknownDestinationFuel = selectedStop == nil
                        && index == itinerary.legs.count - 1
                        && finalEscapeVerificationWarning != nil
                    statuses[riderLeg.id] = selectedStop == nil
                        ? (completedWithUnknownDestinationFuel
                            ? .fuelUnknown(finalEscapeVerificationWarning!)
                            : .built)
                        : .pending
                    committed = replacing(
                        riderLegID: riderLeg.id,
                        with: builtLegs,
                        in: committed,
                        status: statuses[riderLeg.id] ?? .pending
                    )
                    progressWatchdog.recordProgress()
                    RoutingDebugLog.shared.event(
                        "fuel progress renewed gen=\(itinerary.generation) "
                            + "riderLeg=\(riderLeg.id) kind=\(selectedStop == nil ? "waypoint" : "pump") "
                            + "committed=\(committed.legs.count)"
                    )
                    onProgress(committed)

                    if selectedStop != nil {
                        lastRejectedStationID = nil
                        lastRejectedReason = nil
                        onFuelStatus("Fuel stop \(nextFuelStopNumber) added")
                        await Task.yield()
                        // Keep every committed pump excluded for the rest of
                        // this rider leg. Clearing here allowed short urban
                        // stations to alternate forever near the destination.
                        if let selectedStop { excludedStations.insert(selectedStop.id) }
                        forceFuelStop = false
                        continue
                    }
                    onFuelStatus(completedWithUnknownDestinationFuel
                        ? "Destination fuel safety not verified"
                        : "Leg complete")
                    break
                } catch is CancellationError {
                    return dropped(itinerary, committed: committed, cancelled: true)
                } catch {
                    if let selectedStop {
                        excludedStations.insert(selectedStop.id)
                        lastRejectedStationID = selectedStop.id
                        lastRejectedReason = error.localizedDescription
                        RoutingDebugLog.shared.event(
                            "fuel feeler reject riderLeg=\(riderLeg.id) station=\(selectedStop.id) " +
                                "reason=route_failed msg=\(error.localizedDescription)"
                        )
                        continue
                    }
                    if !forceFuelStop {
                        forceFuelStop = true
                        RoutingDebugLog.shared.event(
                            "fuel feeler direct retry riderLeg=\(riderLeg.id) reason=profile_route_exceeds_range"
                        )
                        continue
                    }
                    return await finishWithFuelAdvisory(.gap(
                        "No fuel-safe route to the next waypoint fits the planned range."
                    ))
                }
            }
        }

        RoutingDebugLog.shared.event(
            "fuel forward committed gen=\(itinerary.generation) legs=\(committed.legs.count)"
        )
        return appendingPreservedSuffix(
            preservedSuffix,
            statuses: preservedStatuses,
            routes: preservedRoutes,
            to: committed
        )
    }

    /// Fuel planning is advisory. Once its proof ends, finish the road route
    /// without a range ceiling, retain any pumps already proved in this rider
    /// leg, and attach the warning to the exact leg whose fuel state is unsafe.
    private func buildAdvisoryRemainder(
        itinerary: RiderItinerary,
        startIndex: Int,
        endIndex: Int,
        current: RouteCoordinate,
        builtLegPrefix: [BuiltLeg],
        fuelUsedAtCurrent: Double,
        issue: FuelAdvisoryIssue,
        committed initial: BuiltItinerary,
        preservedSuffix: [BuiltLeg],
        preservedStatuses: [UUID: LegStatus],
        preservedRoutes: [UUID: RouteResponse],
        fuel: FuelRangePrefs.Snapshot,
        source: any RoutingSource,
        history initialHistory: EdgeHistory,
        onProgress: @MainActor (BuiltItinerary) -> Void
    ) async -> BuiltItinerary {
        var committed = initial
        var history = initialHistory
        var firstFrom = current
        var firstPrefix = builtLegPrefix
        var fuelUsed = fuelUsedAtCurrent
        let confirmedPumpCount = builtLegPrefix.filter { $0.endsAtFuelStop != nil }.count
        let advisoryMessage = issue.riderMessage(hasConfirmedPump: confirmedPumpCount > 0)

        RoutingDebugLog.shared.event(
            "fuel advisory fallback begin gen=\(itinerary.generation) "
                + "fromLeg=\(startIndex) throughLeg=\(max(startIndex, endIndex - 1)) "
                + "issue=\(issue.logValue) preservedPumps=\(confirmedPumpCount) "
                + "boundary=\(String(format: "%.5f,%.5f", current.latitude, current.longitude)) "
                + "statusScope=unverified_tail detail=\(issue.logDetail)"
        )

        for index in startIndex..<endIndex {
            guard active(itinerary) else {
                return dropped(itinerary, committed: committed, cancelled: Task.isCancelled)
            }
            let riderLeg = itinerary.legs[index]
            let destination = itinerary.waypoints[index + 1].coordinate
            let departureID = firstPrefix.last?.endsAtFuelStop?.stationID
                ?? riderLeg.from.uuidString
            let profile = index == startIndex
                ? (riderLeg.hopOverrides[departureID] ?? riderLeg.profile)
                : riderLeg.profile
            let avoidMotorways = riderLeg.avoidsMajorHighways(
                departingFrom: departureID,
                effectiveProfile: profile
            )
            do {
                let response = try await source.route(routeRequest(
                    profile: profile,
                    allowUnknown: profile == .cleanest ? false : riderLeg.allowUnknown,
                    from: firstFrom,
                    to: destination,
                    avoidEdgeIDs: itinerary.impassableEdgeIDs,
                    maxPathMeters: nil,
                    history: history,
                    avoidMotorways: avoidMotorways,
                    preferBackRoads: riderLeg.preferBackRoads
                ))
                let meters = try responseMeters(response)
                let resetsAtWaypoint = committed.waypointFuelStops.values.contains {
                    $0.coordinate == destination
                }
                let arrivalFuel = resetsAtWaypoint ? 0 : fuelUsed + meters
                let routed = BuiltLeg(
                    riderLegID: riderLeg.id,
                    fromCoordinate: firstFrom,
                    toCoordinate: destination,
                    endsAtFuelStop: nil,
                    response: response,
                    fuelUsedOnArrivalMeters: arrivalFuel,
                    routeProfile: profile
                )
                let status: LegStatus
                if index == startIndex {
                    switch issue {
                    case .gap(let reason):
                        let remaining = max(0, fuel.usableMeters - fuelUsed)
                        let gap = FuelGap(
                            id: fuelGapID(
                                riderLegID: riderLeg.id,
                                gapMeters: meters,
                                usableRangeMeters: fuel.usableMeters,
                                from: firstFrom,
                                to: destination
                            ),
                            gapMeters: meters,
                            overByMeters: max(0, meters - remaining),
                            usableRangeMeters: fuel.usableMeters,
                            remainingFuelMeters: remaining,
                            reason: reason,
                            fromCoordinate: firstFrom,
                            toCoordinate: destination
                        )
                        status = .gap(gap)
                    case .unknown:
                        status = .fuelUnknown(advisoryMessage ??
                            "Fuel coverage could not be verified. Route kept—carry extra fuel.")
                    }
                } else {
                    status = .fuelUnknown(
                        "Fuel continuity is unknown after the preceding fuel warning."
                    )
                }
                committed = replacing(
                    riderLegID: riderLeg.id,
                    with: firstPrefix + [routed],
                    in: committed,
                    status: status
                )
                history.append(response)
                RoutingDebugLog.shared.event(
                    "fuel advisory fallback committed gen=\(itinerary.generation) "
                        + "riderLeg=\(riderLeg.id) issue=\(issue.logValue) "
                        + "meters=\(Int(meters)) remaining=\(Int(max(0, fuel.usableMeters - fuelUsed))) "
                        + "statusScope=unverified_tail"
                )
                onProgress(committed)
                firstFrom = destination
                firstPrefix = []
                // Once continuity is unresolved, later rider legs are still
                // useful route geometry but no arrival-fuel figure is proven.
                fuelUsed = 0
            } catch is CancellationError {
                return dropped(itinerary, committed: committed, cancelled: true)
            } catch {
                committed = markingFailed(
                    riderLeg.id,
                    message: error.localizedDescription,
                    in: committed
                )
                RoutingDebugLog.shared.routeFailure(
                    error,
                    context: "fuel advisory road route riderLeg=\(riderLeg.id)"
                )
                onProgress(committed)
                break
            }
        }

        return appendingPreservedSuffix(
            preservedSuffix,
            statuses: preservedStatuses,
            routes: preservedRoutes,
            to: committed
        )
    }

    private func buildRiderLeg(
        itinerary: RiderItinerary,
        index: Int,
        baseline: RouteResponse,
        baselineHistory: EdgeHistory,
        allBaseline: [Int: RouteResponse],
        fuelUsedAtStart: Double,
        fuel: FuelRangePrefs.Snapshot,
        source: any RoutingSource,
        history: EdgeHistory,
        destinationFuelUsedLimitMeters: Double?,
        waypointFuelReset: FuelStop?,
        forceFuelStop: Bool,
        minimumFuelStopsOverride: Int?,
        excludedStationIDs: Set<String>,
        resumeAfterStation: FuelStop?,
        fuelDeadline: Date,
        defaultProfile: RouteProfile,
        onHop: @MainActor ([BuiltLeg]) -> Void
    ) async throws -> [BuiltLeg] {
        let riderLeg = itinerary.legs[index]
        let from = resumeAfterStation?.coordinate ?? itinerary.waypoints[index].coordinate
        let to = itinerary.waypoints[index + 1].coordinate
        let riderDepartureID = riderLeg.from.uuidString
        let initialDepartureID = resumeAfterStation?.stationID ?? riderDepartureID
        var activeProfile = resumeAfterStation?.stationID.flatMap {
            riderLeg.hopOverrides[$0]
        } ?? riderLeg.hopOverrides[riderDepartureID] ?? defaultProfile
        func allowUnknown(for profile: RouteProfile) -> Bool {
            profile == .cleanest ? false : riderLeg.allowUnknown
        }
        let effectiveBaseline: RouteResponse
        if resumeAfterStation != nil {
            effectiveBaseline = try await source.route(routeRequest(
                profile: activeProfile,
                allowUnknown: allowUnknown(for: activeProfile),
                from: from,
                to: to,
                avoidEdgeIDs: itinerary.impassableEdgeIDs,
                maxPathMeters: nil,
                history: history,
                avoidMotorways: riderLeg.avoidsMajorHighways(
                    departingFrom: initialDepartureID,
                    effectiveProfile: activeProfile
                ),
                preferBackRoads: riderLeg.preferBackRoads
            ))
        } else {
            effectiveBaseline = baseline
        }
        let meters = try responseMeters(effectiveBaseline)
        guard fuel.usableMeters > 0 else {
            let finalResponse = baselineHistory == history && resumeAfterStation == nil
                ? effectiveBaseline
                : try await source.route(routeRequest(
                    profile: activeProfile,
                    allowUnknown: allowUnknown(for: activeProfile),
                    from: from,
                    to: to,
                    avoidEdgeIDs: itinerary.impassableEdgeIDs,
                    maxPathMeters: nil,
                    history: history,
                    avoidMotorways: riderLeg.avoidsMajorHighways(
                        departingFrom: initialDepartureID,
                        effectiveProfile: activeProfile
                    ),
                    preferBackRoads: riderLeg.preferBackRoads
                ))
            guard active(itinerary) else { throw CancellationError() }
            let finalMeters = try responseMeters(finalResponse)
            return [BuiltLeg(
                riderLegID: riderLeg.id,
                fromCoordinate: from,
                toCoordinate: to,
                endsAtFuelStop: nil,
                response: finalResponse,
                fuelUsedOnArrivalMeters: fuelUsedAtStart + finalMeters,
                routeProfile: activeProfile
            )]
        }

        let firstCap = max(0, fuel.usableMeters - fuelUsedAtStart)
        let firstComfortCap = FuelItinerary.comfortCapMeters(
            firstLegMaxMeters: firstCap,
            usableRangeMeters: fuel.usableMeters
        )
        let stopsNeeded = FuelItinerary.fuelStopCountNeeded(
            profileMeters: meters,
            firstLegMaxMeters: firstCap,
            usableRangeMeters: fuel.usableMeters
        )
        RoutingDebugLog.shared.event(
            "fuel need riderLeg=\(riderLeg.id) profileMeters=\(Int(meters)) " +
                "usable=\(Int(fuel.usableMeters)) stopsNeeded=\(stopsNeeded)"
        )
        _ = allBaseline
        let arrivalWithoutPump = fuelUsedAtStart + meters
        let requirePumpBeforeWaypoint = forceFuelStop || (waypointFuelReset == nil
            && destinationFuelUsedLimitMeters.map { arrivalWithoutPump > $0 + 1 } == true)

        if meters <= firstComfortCap + 1, !requirePumpBeforeWaypoint {
            let arrival = waypointFuelReset == nil ? fuelUsedAtStart + meters : 0
            if let reset = waypointFuelReset {
                RoutingDebugLog.shared.event(
                    "fuel reset riderLeg=\(riderLeg.id) station=\(reset.stationID ?? "unknown") source=waypoint"
                )
            }
            RoutingDebugLog.shared.event(
                "fuel carry riderLeg=\(riderLeg.id) used=\(Int(arrival))"
            )
            return [BuiltLeg(
                riderLegID: riderLeg.id,
                fromCoordinate: from,
                toCoordinate: to,
                endsAtFuelStop: nil,
                response: effectiveBaseline,
                fuelUsedOnArrivalMeters: arrival,
                routeProfile: activeProfile
            )]
        }

        var output: [BuiltLeg] = []
        output.reserveCapacity(max(1, stopsNeeded + 1))
        var used = fuelUsedAtStart
        var sublegHistory = history
        var windowStart = from
        var routedMeters = 0.0
        var excluded = excludedStationIDs
        let packProvinces = GraphPackStore.endpointProvinceIds(containingAny: [
            from.locationCoordinate, to.locationCoordinate
        ])
        // Fuel allocation is intentionally resumable one pump at a time. A
        // single service request must prove the next useful stop, not solve an
        // entire multi-stop itinerary before the rider sees any progress.
        let usesWindows = stopsNeeded > 0 || requirePumpBeforeWaypoint
            || meters > 600_000 || packProvinces.count > 1
        var windowIndex = 0

        while true {
            let remainingBudgetMs = Int(fuelDeadline.timeIntervalSinceNow * 1_000)
            guard remainingBudgetMs > 0 else {
                throw RoutingError.server("Fuel planning reached its 20-second itinerary budget.")
            }
            windowIndex += 1
            guard windowIndex <= 16 else {
                throw RoutingError.server("The long-route fuel chain exceeded 16 planning windows.")
            }
            let windowFirstCap = max(0, fuel.usableMeters - used)
            let departureAnchorID = (windowStart == from
                ? (resumeAfterStation?.stationID ?? riderDepartureID)
                : output.last?.endsAtFuelStop?.stationID) ?? riderDepartureID
            let activeAvoidMotorways = riderLeg.avoidsMajorHighways(
                departingFrom: departureAnchorID,
                effectiveProfile: activeProfile
            )
            let requiredStationID = riderLeg.fuelStopOverrides[departureAnchorID]
            let remainingProfileMeters = max(0, meters - routedMeters)
            let remainingStops = FuelItinerary.fuelStopCountNeeded(
                profileMeters: remainingProfileMeters,
                firstLegMaxMeters: windowFirstCap,
                usableRangeMeters: fuel.usableMeters
            )
            let chain: FuelChainResponse
            do {
                chain = try await source.fuelChain(FuelChainRequest(
                    profile: activeProfile,
                    from: windowStart,
                    to: to,
                    allowUnknown: allowUnknown(for: activeProfile),
                    usableRangeMeters: fuel.usableMeters,
                    firstLegMaxMeters: windowFirstCap,
                    requireFuelStopBeforeEnd: requirePumpBeforeWaypoint || remainingStops > 0,
                    minimumFuelStops: max(remainingStops, minimumFuelStopsOverride ?? 0),
                    destinationFuelUsedLimitMeters: waypointFuelReset == nil
                        ? destinationFuelUsedLimitMeters
                        : nil,
                    profileMeters: remainingProfileMeters,
                    riderLegId: riderLeg.id.uuidString,
                    avoidEdgeIds: Array(itinerary.impassableEdgeIDs),
                    cleanMetroMultiplier: nil,
                    avoidMotorways: activeAvoidMotorways,
                    priorEdgeIds: sublegHistory.edgeIDs,
                    arrivalEdgeId: sublegHistory.arrivalEdgeID,
                    backtrackFactor: 4,
                    excludedStationIds: Array(excluded),
                    // Rendering remains progressive, but selection sees several
                    // anchors so a rural/profile-correct chain can beat the first
                    // feasible town pump.
                    windowMaxStops: usesWindows
                        ? min(4, max(1, remainingStops + 1))
                        : nil,
                    allowPartialWindow: usesWindows,
                    windowTimeBudgetMs: min(Self.liveFuelWindowBudgetMs, remainingBudgetMs),
                    requiredFirstStationId: requiredStationID
                ))
            } catch {
                // A timeout, transport failure, or server error is not proof
                // that no pump exists. Preserve the working route and surface
                // the honest failure; only an explicit `status=gap` response
                // may offer the rider an auxiliary-fuel acknowledgement.
                throw error
            }
            guard active(itinerary) else { throw CancellationError() }
            if chain.isFuelUnknown {
                throw RoutingError.fuelUnknown(
                    chain.message ?? "Fuel data is unavailable for this part of the route."
                )
            }
            if chain.isGap {
                let chainGap = chain.gapMeters ?? remainingProfileMeters
                let remaining = max(0, fuel.usableMeters - used)
                throw RoutingError.fuelGap(FuelGap(
                    id: fuelGapID(
                        riderLegID: riderLeg.id,
                        gapMeters: chainGap,
                        usableRangeMeters: fuel.usableMeters,
                        from: windowStart,
                        to: to
                    ),
                    gapMeters: chainGap,
                    overByMeters: chain.overByMeters ?? max(0, chainGap - remaining),
                    usableRangeMeters: fuel.usableMeters,
                    remainingFuelMeters: remaining,
                    reason: chain.message ?? "No route-connected fuel chain fits the usable range.",
                    fromCoordinate: windowStart,
                    toCoordinate: to
                ))
            }
            let stops = chain.stops ?? []
            if !chain.reachesDestination, stops.isEmpty {
                throw RoutingError.server("A fuel window ended without a forward pump.")
            }
            let points = [windowStart] + stops.map(\.coordinate) + (chain.reachesDestination ? [to] : [])
            for subIndex in 0..<(points.count - 1) {
                let cap = subIndex == 0 ? windowFirstCap : fuel.usableMeters
                let hopProfile = subIndex == 0
                    ? activeProfile
                    : (riderLeg.hopOverrides[stops[subIndex - 1].id] ?? defaultProfile)
                let hopDepartureID = subIndex == 0
                    ? departureAnchorID
                    : stops[subIndex - 1].id
                let hopAllowUnknown = hopProfile == .cleanest ? false : riderLeg.allowUnknown
                let request = routeRequest(
                    profile: hopProfile,
                    allowUnknown: hopAllowUnknown,
                    from: points[subIndex],
                    to: points[subIndex + 1],
                    avoidEdgeIDs: itinerary.impassableEdgeIDs,
                    maxPathMeters: cap,
                    history: sublegHistory,
                    avoidMotorways: riderLeg.avoidsMajorHighways(
                        departingFrom: hopDepartureID,
                        effectiveProfile: hopProfile
                    ),
                    preferBackRoads: riderLeg.preferBackRoads
                )
                let response = try await source.route(request)
                guard active(itinerary) else { throw CancellationError() }
                let subMeters = try responseMeters(response)
                sublegHistory.append(response)
                guard subMeters <= cap + 1 else {
                    throw RoutingError.server("A selected fuel leg exceeds usable range.")
                }
                routedMeters += subMeters
                if subIndex < stops.count {
                    let station = stops[subIndex]
                    let candidateDepartureID = subIndex == 0 ? "start" : stops[subIndex - 1].id
                    let validTargets = (chain.stationCandidates ?? []).filter {
                        $0.departureId == candidateDepartureID
                            && $0.validForward == true
                            && $0.latitude != nil
                            && $0.longitude != nil
                    }
                    let stop = FuelStop(
                        coordinate: station.coordinate,
                        stationID: station.id,
                        name: station.displayName,
                        afterRiderLegID: riderLeg.id
                    )
                    output.append(BuiltLeg(
                        riderLegID: riderLeg.id,
                        fromCoordinate: points[subIndex],
                        toCoordinate: points[subIndex + 1],
                        endsAtFuelStop: stop,
                        response: response,
                        fuelUsedOnArrivalMeters: 0,
                        routeProfile: hopProfile,
                        validFuelTargets: validTargets
                    ))
                    excluded.insert(station.id)
                    let stationLog = station.id.isEmpty
                        ? "\(station.latitude),\(station.longitude)"
                        : station.id
                    RoutingDebugLog.shared.event(
                        "fuel reset riderLeg=\(riderLeg.id) station=\(stationLog)"
                    )
                    RoutingDebugLog.shared.event(
                        "fuel station chosen riderLeg=\(riderLeg.id) station=\(stationLog) " +
                            "dirt%=\(response.dirtPercent) meters=\(Int(subMeters)) " +
                            "candidates=\(chain.stationCandidates?.count ?? 0)"
                    )
                    used = 0
                } else {
                    used = waypointFuelReset == nil ? used + subMeters : 0
                    output.append(BuiltLeg(
                        riderLegID: riderLeg.id,
                        fromCoordinate: points[subIndex],
                        toCoordinate: points[subIndex + 1],
                        endsAtFuelStop: nil,
                        response: response,
                        fuelUsedOnArrivalMeters: used,
                        routeProfile: hopProfile
                    ))
                    RoutingDebugLog.shared.event(
                        "fuel carry riderLeg=\(riderLeg.id) used=\(Int(used))"
                    )
                    if let reset = waypointFuelReset {
                        RoutingDebugLog.shared.event(
                            "fuel reset riderLeg=\(riderLeg.id) station=\(reset.stationID ?? "unknown") source=waypoint"
                        )
                    }
                }
                if usesWindows || !riderLeg.hopOverrides.isEmpty { onHop(output) }
            }
            if chain.reachesDestination { break }
            guard let lastStop = stops.last else {
                throw RoutingError.server("A fuel window ended without a continuation pump.")
            }
            windowStart = lastStop.coordinate
            activeProfile = riderLeg.hopOverrides[lastStop.id] ?? defaultProfile
            RoutingDebugLog.shared.event(
                "fuel window riderLeg=\(riderLeg.id) window=\(windowIndex) " +
                    "stops=\(stops.count) committedHops=\(output.count)"
            )
        }
        return output
    }

    private func active(_ itinerary: RiderItinerary) -> Bool {
        !Task.isCancelled && currentGeneration == itinerary.generation
    }

    private func dropped(
        _ itinerary: RiderItinerary,
        committed: BuiltItinerary,
        cancelled: Bool = false
    ) -> BuiltItinerary {
        RoutingDebugLog.shared.event(
            "build dropped gen=\(itinerary.generation) reason=\(cancelled || Task.isCancelled ? "cancelled" : "stale")"
        )
        return committed
    }
}

private struct ReusablePrefix {
    let legs: [BuiltLeg]
    let riderLegCount: Int
}

private func reusablePrefix(
    from reuse: BuiltItinerary?,
    itinerary: RiderItinerary,
    before legIndex: Int
) -> ReusablePrefix {
    guard let reuse else { return ReusablePrefix(legs: [], riderLegCount: 0) }
    var legs: [BuiltLeg] = []
    var riderLegCount = 0
    for riderLeg in itinerary.legs.prefix(legIndex) {
        let matches = reuse.legs.filter { $0.riderLegID == riderLeg.id }
        guard isReusableRouteStatus(reuse.riderLegStatus[riderLeg.id]),
              !matches.isEmpty
        else { break }
        legs.append(contentsOf: matches)
        riderLegCount += 1
    }
    return ReusablePrefix(legs: legs, riderLegCount: riderLegCount)
}

private func reusableSuffix(
    from reuse: BuiltItinerary?,
    itinerary: RiderItinerary,
    startingAt legIndex: Int
) -> [BuiltLeg] {
    guard let reuse, legIndex < itinerary.legs.count else { return [] }
    let ids = Set(itinerary.legs.suffix(from: legIndex).map(\.id))
    return reuse.legs.filter {
        ids.contains($0.riderLegID)
            && isReusableRouteStatus(reuse.riderLegStatus[$0.riderLegID])
    }
}

private func isReusableRouteStatus(_ status: LegStatus?) -> Bool {
    switch status {
    case .built, .gap, .fuelUnknown:
        return true
    case .pending, .failed, nil:
        return false
    }
}

private struct FuelResume {
    let station: FuelStop
    let kept: [BuiltLeg]
    let riderLegPrefix: [BuiltLeg]
}

private func fuelResume(
    stationID: String?,
    riderLegIndex: Int,
    itinerary: RiderItinerary,
    reuse: BuiltItinerary?
) -> FuelResume? {
    guard let stationID,
          itinerary.legs.indices.contains(riderLegIndex),
          let reuse,
          let matchIndex = reuse.legs.firstIndex(where: {
              $0.riderLegID == itinerary.legs[riderLegIndex].id
                  && $0.endsAtFuelStop?.stationID == stationID
          }),
          let station = reuse.legs[matchIndex].endsAtFuelStop
    else { return nil }
    let kept = Array(reuse.legs.prefix(through: matchIndex))
    return FuelResume(
        station: station,
        kept: kept,
        riderLegPrefix: kept.filter { $0.riderLegID == itinerary.legs[riderLegIndex].id }
    )
}

private func reusableRiderRoutes(
    from reuse: BuiltItinerary?,
    itinerary: RiderItinerary,
    outside rebuiltRange: Range<Int>
) -> [UUID: RouteResponse] {
    guard let reuse else { return [:] }
    var routes: [UUID: RouteResponse] = [:]
    for (index, leg) in itinerary.legs.enumerated() where !rebuiltRange.contains(index) {
        if let response = reuse.riderRoutes[leg.id] {
            routes[leg.id] = response
            continue
        }
        // Compatibility with builds produced before riderRoutes existed: an
        // unsplit leg is itself the reusable rider route. Split fuel work is
        // deliberately never reconstructed or reused.
        let matches = reuse.legs.filter { $0.riderLegID == leg.id }
        if matches.count == 1, let response = matches.first?.response {
            routes[leg.id] = response
        }
    }
    return routes
}

private func appendingPreservedSuffix(
    _ suffix: [BuiltLeg],
    statuses preservedStatuses: [UUID: LegStatus],
    routes preservedRoutes: [UUID: RouteResponse],
    to built: BuiltItinerary
) -> BuiltItinerary {
    guard !suffix.isEmpty else { return built }
    let suffixIDs = Set(suffix.map(\.riderLegID))
    var statuses = built.riderLegStatus
    for id in suffixIDs {
        if let preserved = preservedStatuses[id] { statuses[id] = preserved }
    }
    var routes = built.riderRoutes
    for (id, response) in preservedRoutes where suffixIDs.contains(id) {
        routes[id] = response
    }
    return BuiltItinerary(
        generation: built.generation,
        legs: built.legs.filter { !suffixIDs.contains($0.riderLegID) } + suffix,
        riderLegStatus: statuses,
        riderRoutes: routes,
        waypointFuelStops: built.waypointFuelStops
    )
}

/// Distance from each rider-leg start to the first possible tank reset on the
/// remaining itinerary (or to the final destination when no reset is needed).
private func distanceToNextFuelOpportunity(
    itinerary: RiderItinerary,
    baseline: [Int: RouteResponse],
    firstReachableFuel: [Int: Double],
    waypointFuelStops: [UUID: FuelStop]
) -> [Int: Double] {
    var result: [Int: Double] = [:]
    var tailDistance = 0.0
    for index in itinerary.legs.indices.reversed() {
        let legMeters = baseline[index]?.distanceMeters ?? .infinity
        let endpointID = itinerary.waypoints[index + 1].id
        let throughWaypoint = legMeters + (
            waypointFuelStops[endpointID] == nil ? tailDistance : 0
        )
        let firstPump = firstReachableFuel[index] ?? .infinity
        let distance = min(firstPump, throughWaypoint)
        result[index] = distance
        tailDistance = distance
    }
    return result
}

private func carriedFuel(from legs: [BuiltLeg]) -> Double {
    guard let last = legs.last else { return 0 }
    return last.endsAtFuelStop == nil ? last.fuelUsedOnArrivalMeters : 0
}

private struct RevalidatedFuelPrefix {
    let fuelUsedMeters: Double
    let firstInvalidRiderLegIndex: Int?
}

/// Replays fuel consumption across reusable geometry from Point 1. Stored
/// arrival values are deliberately ignored: a later waypoint edit may have
/// changed where fuel must be reserved even when the road geometry is unchanged.
private func revalidatedFuelPrefix(
    _ legs: [BuiltLeg],
    itinerary: RiderItinerary,
    waypointFuelStops: [UUID: FuelStop],
    usableRangeMeters: Double
) -> RevalidatedFuelPrefix {
    let riderLegIndices = Dictionary(
        uniqueKeysWithValues: itinerary.legs.enumerated().map { ($0.element.id, $0.offset) }
    )
    let resetCoordinates = itinerary.waypoints.compactMap { waypoint -> RouteCoordinate? in
        waypointFuelStops[waypoint.id] == nil ? nil : waypoint.coordinate
    }
    var fuelUsed = 0.0
    for leg in legs {
        guard let riderLegIndex = riderLegIndices[leg.riderLegID] else {
            return RevalidatedFuelPrefix(
                fuelUsedMeters: fuelUsed,
                firstInvalidRiderLegIndex: 0
            )
        }
        guard let meters = leg.response.distanceMeters,
              meters.isFinite,
              meters >= 0,
              meters <= max(0, usableRangeMeters - fuelUsed) + 1
        else {
            return RevalidatedFuelPrefix(
                fuelUsedMeters: fuelUsed,
                firstInvalidRiderLegIndex: riderLegIndex
            )
        }
        fuelUsed += meters
        if leg.endsAtFuelStop != nil || resetCoordinates.contains(leg.toCoordinate) {
            fuelUsed = 0
        }
    }
    return RevalidatedFuelPrefix(
        fuelUsedMeters: fuelUsed,
        firstInvalidRiderLegIndex: nil
    )
}

private func builtPrefix(
    before riderLegIndex: Int,
    from legs: [BuiltLeg],
    itinerary: RiderItinerary
) -> [BuiltLeg] {
    guard riderLegIndex > 0 else { return [] }
    let riderLegIDs = Set(itinerary.legs.prefix(riderLegIndex).map(\.id))
    return legs.filter { riderLegIDs.contains($0.riderLegID) }
}

private func unconstrainedFuelLeg(
    riderLeg: RiderLeg,
    from: RouteCoordinate,
    to: RouteCoordinate,
    response: RouteResponse,
    fuelUsedAtStart: Double
) -> BuiltLeg {
    BuiltLeg(
        riderLegID: riderLeg.id,
        fromCoordinate: from,
        toCoordinate: to,
        endsAtFuelStop: nil,
        response: response,
        fuelUsedOnArrivalMeters: fuelUsedAtStart + (response.distanceMeters ?? 0),
        routeProfile: riderLeg.profile
    )
}

private func markingFuelGap(
    itinerary: RiderItinerary,
    baseline: [Int: RouteResponse],
    lastBuildable: Int,
    committed: BuiltItinerary,
    index: Int,
    fuel: FuelRangePrefs.Snapshot,
    fuelUsed: Double,
    reason: String
) -> (BuiltItinerary, FuelGap) {
    let riderLeg = itinerary.legs[index]
    let from = itinerary.waypoints[index].coordinate
    let to = itinerary.waypoints[index + 1].coordinate
    let response = baseline[index]!
    let gapMeters = response.distanceMeters ?? 0
    let remaining = max(0, fuel.usableMeters - fuelUsed)
    let gap = FuelGap(
        id: fuelGapID(
            riderLegID: riderLeg.id,
            gapMeters: gapMeters,
            usableRangeMeters: fuel.usableMeters,
            from: from,
            to: to
        ),
        gapMeters: gapMeters,
        overByMeters: max(0, gapMeters - remaining),
        usableRangeMeters: fuel.usableMeters,
        remainingFuelMeters: remaining,
        reason: reason,
        fromCoordinate: from,
        toCoordinate: to
    )
    var result = replacing(
        riderLegID: riderLeg.id,
        with: [unconstrainedFuelLeg(
            riderLeg: riderLeg,
            from: from,
            to: to,
            response: response,
            fuelUsedAtStart: fuelUsed
        )],
        in: committed,
        status: .gap(gap)
    )
    for laterIndex in (index + 1)..<lastBuildable {
        guard let laterBase = baseline[laterIndex] else { continue }
        let laterLeg = itinerary.legs[laterIndex]
        result = replacing(
            riderLegID: laterLeg.id,
            with: [unconstrainedFuelLeg(
                riderLeg: laterLeg,
                from: itinerary.waypoints[laterIndex].coordinate,
                to: itinerary.waypoints[laterIndex + 1].coordinate,
                response: laterBase,
                fuelUsedAtStart: 0
            )],
            in: result,
            status: .fuelUnknown("Fuel continuity follows an unresolved gap.")
        )
    }
    return (result, gap)
}

private func fuelGapID(
    riderLegID: UUID,
    gapMeters: Double,
    usableRangeMeters: Double,
    from: RouteCoordinate,
    to: RouteCoordinate
) -> String {
    [
        riderLegID.uuidString.lowercased(),
        String(Int(gapMeters.rounded())),
        String(Int(usableRangeMeters.rounded())),
        String(format: "%.5f,%.5f", from.latitude, from.longitude),
        String(format: "%.5f,%.5f", to.latitude, to.longitude)
    ].joined(separator: "|")
}

private func responseMeters(_ response: RouteResponse) throws -> Double {
    guard response.status == "complete",
          let meters = response.distanceMeters,
          meters.isFinite,
          meters >= 0
    else { throw RoutingError.invalidResponse }
    return meters
}

private func routeRequest(
    itinerary: RiderItinerary,
    legIndex: Int,
    maxPathMeters: Double?,
    history: EdgeHistory = EdgeHistory(),
    profileOverride: RouteProfile? = nil
) -> RouteRequest {
    let leg = itinerary.legs[legIndex]
    let profile = profileOverride ?? leg.profile
    return routeRequest(
        profile: profile,
        allowUnknown: profile == .cleanest ? false : leg.allowUnknown,
        from: itinerary.waypoints[legIndex].coordinate,
        to: itinerary.waypoints[legIndex + 1].coordinate,
        avoidEdgeIDs: itinerary.impassableEdgeIDs,
        maxPathMeters: maxPathMeters,
        history: history,
        avoidMotorways: leg.avoidMotorways,
        preferBackRoads: leg.preferBackRoads
    )
}

private func straightLineMeters(_ from: RouteCoordinate, _ to: RouteCoordinate) -> Double {
    CLLocation(latitude: from.latitude, longitude: from.longitude).distance(
        from: CLLocation(latitude: to.latitude, longitude: to.longitude)
    )
}

private func routeRequest(
    profile: RouteProfile,
    allowUnknown: Bool,
    from: RouteCoordinate,
    to: RouteCoordinate,
    avoidEdgeIDs: Set<String>,
    maxPathMeters: Double?,
    directExtraBudgetMeters: Double? = nil,
    regionalHopMinimumMeters: [Double] = [],
    history: EdgeHistory = EdgeHistory(),
    avoidMotorways: Bool = false,
    preferBackRoads: Bool = false
) -> RouteRequest {
    RouteRequest(
        profile: profile,
        locations: [
            RouteLocation(latitude: from.latitude, longitude: from.longitude, label: "Point 1"),
            RouteLocation(latitude: to.latitude, longitude: to.longitude, label: "Point 2")
        ],
        allowUnknown: allowUnknown,
        avoidEdgeIds: Array(avoidEdgeIDs),
        priorEdgeIds: history.edgeIDs,
        arrivalEdgeId: history.arrivalEdgeID,
        backtrackFactor: 4,
        maxPathMeters: maxPathMeters,
        directExtraBudgetMeters: directExtraBudgetMeters,
        regionalHopMinimumMeters: regionalHopMinimumMeters,
        cleanMetroMultiplier: nil,
        avoidMotorways: avoidMotorways,
        preferBackRoads: preferBackRoads
    )
}

private struct EdgeHistory: Equatable {
    private struct Entry: Equatable {
        let id: String
        let meters: Double
    }

    /// Backtrack protection is local to the departure. Sending every edge from
    /// a thousand-kilometre ride made later fuel requests enormous and could
    /// discourage a perfectly sensible road merely because it crossed the
    /// route hundreds of kilometres earlier.
    private static let recentMeterLimit = 30_000.0
    private static let recentEdgeLimit = 256
    private var recent: [Entry] = []
    private var recentMeters = 0.0
    private(set) var arrivalEdgeID: String?

    var edgeIDs: [String] { recent.map(\.id) }

    init() {}

    init(legs: [BuiltLeg]) {
        for leg in legs { append(leg.response) }
    }

    mutating func append(_ response: RouteResponse) {
        for segment in response.segments ?? [] {
            guard let id = segment.edgeId, !id.isEmpty else { continue }
            if let duplicate = recent.firstIndex(where: { $0.id == id }) {
                recentMeters -= recent.remove(at: duplicate).meters
            }
            let meters = max(1, segment.distanceMeters ?? 0)
            recent.append(Entry(id: id, meters: meters))
            recentMeters += meters
            arrivalEdgeID = id
            while recent.count > 1,
                  (recent.count > Self.recentEdgeLimit
                    || recentMeters > Self.recentMeterLimit) {
                recentMeters -= recent.removeFirst().meters
            }
        }
    }
}

private func replacing(
    riderLegID: UUID,
    with replacement: [BuiltLeg],
    in built: BuiltItinerary,
    status: LegStatus
) -> BuiltItinerary {
    var statuses = built.riderLegStatus
    statuses[riderLegID] = status
    return BuiltItinerary(
        generation: built.generation,
        legs: built.legs.filter { $0.riderLegID != riderLegID } + replacement,
        riderLegStatus: statuses,
        riderRoutes: built.riderRoutes,
        waypointFuelStops: built.waypointFuelStops
    )
}

private func markingFailed(
    _ riderLegID: UUID,
    message: String,
    in built: BuiltItinerary
) -> BuiltItinerary {
    var statuses = built.riderLegStatus
    statuses[riderLegID] = .failed(message)
    return BuiltItinerary(
        generation: built.generation,
        legs: built.legs,
        riderLegStatus: statuses,
        riderRoutes: built.riderRoutes,
        waypointFuelStops: built.waypointFuelStops
    )
}
