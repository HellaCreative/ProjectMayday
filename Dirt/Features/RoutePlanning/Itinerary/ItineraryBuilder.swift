import CoreLocation
import Foundation

@MainActor
final class ItineraryBuilder {
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
        reuse: BuiltItinerary?,
        fuel: FuelRangePrefs.Snapshot,
        source policy: RoutingSourcePolicy,
        replanFromStationID: String? = nil,
        onProgress: @MainActor (BuiltItinerary) -> Void
    ) async -> BuiltItinerary {
        currentGeneration = itinerary.generation
        let startIndex = min(max(0, legIndex), itinerary.legs.count)
        let fuelReplan = fuel.usableMeters > 0
        let resume = fuelReplan ? fuelResume(
            stationID: replanFromStationID,
            riderLegIndex: startIndex,
            itinerary: itinerary,
            reuse: reuse
        ) : nil
        let kept: [BuiltLeg] = {
            if let resume { return resume.kept }
            return fuelReplan ? [] : reusableLegs(from: reuse, itinerary: itinerary, before: startIndex)
        }()
        let reusableRoutes = reusableRiderRoutes(from: reuse, itinerary: itinerary, before: startIndex)
        var statuses = Dictionary(
            uniqueKeysWithValues: itinerary.legs.map { ($0.id, LegStatus.pending) }
        )
        for leg in kept { statuses[leg.riderLegID] = .built }
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
                "reuseLegs=\(kept.count) source=\(selectedSource.name)"
        )

        // Distance discovery is intentionally complete before the first fuel
        // decision. The next rider leg can therefore never be a nil fallback.
        var baseline: [Int: RouteResponse] = [:]
        var baselineProfiles: [Int: RouteProfile] = [:]
        var baselineHistory: [Int: EdgeHistory] = [:]
        var discoveryHistory = EdgeHistory()
        var baselineFailure: (index: Int, message: String)?
        for index in 0..<itinerary.legs.count {
            do {
                baselineHistory[index] = discoveryHistory
                let riderLeg = itinerary.legs[index]
                let from = itinerary.waypoints[index].coordinate
                let to = itinerary.waypoints[index + 1].coordinate
                let likelyLongHaul = fuel.usableMeters > 0
                    && straightLineMeters(from, to) > fuel.usableMeters * 3
                var discoveryProfile: RouteProfile = likelyLongHaul ? .cleanest : riderLeg.profile
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
                let discoveredStops = fuelStopCountNeeded(
                    meters: response.distanceMeters ?? 0,
                    usableMeters: fuel.usableMeters
                )
                if fuel.usableMeters > 0, discoveredStops > 3, discoveryProfile != .cleanest {
                    discoveryProfile = .cleanest
                    response = try await selectedSource.route(routeRequest(
                        itinerary: itinerary,
                        legIndex: index,
                        maxPathMeters: nil,
                        history: discoveryHistory,
                        profileOverride: .cleanest
                    ))
                } else if likelyLongHaul, discoveredStops <= 3, discoveryProfile == .cleanest,
                          riderLeg.profile != .cleanest {
                    discoveryProfile = riderLeg.profile
                    response = try await selectedSource.route(routeRequest(
                        itinerary: itinerary,
                        legIndex: index,
                        maxPathMeters: nil,
                        history: discoveryHistory,
                        profileOverride: riderLeg.profile
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
                            "sections=clean reason=more_than_3_stops"
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

        committed = BuiltItinerary(
            generation: itinerary.generation,
            legs: kept,
            riderLegStatus: statuses,
            riderRoutes: Dictionary(uniqueKeysWithValues: baseline.map {
                (itinerary.legs[$0.key].id, $0.value)
            }),
            waypointFuelStops: [:]
        )

        var waypointFuelStops: [UUID: FuelStop] = [:]
        var firstReachableFuel = [Int: Double]()
        if fuelReplan, baselineFailure == nil {
            RoutingDebugLog.shared.event(
                "fuel replan fromLeg=0 reason=\(startIndex == 0 ? "build" : "edit")"
            )
            for waypointIndex in 1..<itinerary.waypoints.count - 1 {
                let waypoint = itinerary.waypoints[waypointIndex]
                if let station = try? await selectedSource.fuelStation(
                    near: waypoint.coordinate, within: 150
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
            for index in itinerary.legs.indices where itinerary.legs.count > 1 {
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
                    probeFirstReachableStation: true
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

        let onwardFuelDistance = distanceToNextFuelOpportunity(
            itinerary: itinerary,
            baseline: baseline,
            firstReachableFuel: firstReachableFuel,
            waypointFuelStops: waypointFuelStops
        )

        let lastBuildable = baselineFailure?.index ?? itinerary.legs.count
        let finalStartIndex = resume == nil && fuelReplan ? 0 : startIndex
        let fuelAttemptBase = committed
        var excludedStationsByLeg = [Int: Set<String>]()
        var forcedFuelLegs = Set<Int>()
        var minimumFuelStopsByLeg = [Int: Int]()
        var attemptedStationSets = Set<String>()
        var fuelBacktrackAttempts = 0
        var lookaheadEnabled = true
        let fuelDeadline = fuelReplan ? Date().addingTimeInterval(20) : .distantFuture

        fuelAttempts: while true {
            if fuelReplan, Date() >= fuelDeadline {
                let failedIndex = min(max(0, finalStartIndex), itinerary.legs.count - 1)
                let failedID = itinerary.legs[failedIndex].id
                let message = "Fuel planning reached its 20-second itinerary budget."
                if baseline[failedIndex] != nil {
                    (committed, _) = markingFuelGap(
                        itinerary: itinerary,
                        baseline: baseline,
                        lastBuildable: lastBuildable,
                        committed: committed,
                        index: failedIndex,
                        fuel: fuel,
                        fuelUsed: 0,
                        reason: message
                    )
                } else {
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
                    fuel: fuel,
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
                if fuelReplan, index == 0, lookaheadEnabled, fuelBacktrackAttempts < 2 {
                    lookaheadEnabled = false
                    fuelBacktrackAttempts += 1
                    RoutingDebugLog.shared.event(
                        "fuel backtrack failedLeg=\(riderLeg.id) replanLeg=\(riderLeg.id) " +
                            "attempt=\(fuelBacktrackAttempts) reason=probe_inconclusive"
                    )
                    continue fuelAttempts
                }
                if fuelReplan, index > 0, fuelBacktrackAttempts < 2 {
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
                let message = error.localizedDescription
                committed = markingFailed(riderLeg.id, message: message, in: committed)
                RoutingDebugLog.shared.event(
                    "build failed riderLeg=\(riderLeg.id) msg=\(message)"
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
            return committed
        }

        RoutingDebugLog.shared.event(
            "build committed gen=\(itinerary.generation) legs=\(committed.legs.count)"
        )
        return committed
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
                history: history
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
                    history: history
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
        let stopsNeeded = meters <= firstCap + 1
            ? 0
            : Int(ceil((meters - firstCap) / fuel.usableMeters))
        RoutingDebugLog.shared.event(
            "fuel need riderLeg=\(riderLeg.id) profileMeters=\(Int(meters)) " +
                "usable=\(Int(fuel.usableMeters)) stopsNeeded=\(stopsNeeded)"
        )
        _ = allBaseline
        let arrivalWithoutPump = fuelUsedAtStart + meters
        let requirePumpBeforeWaypoint = forceFuelStop || (waypointFuelReset == nil
            && destinationFuelUsedLimitMeters.map { arrivalWithoutPump > $0 + 1 } == true)

        if meters <= firstCap + 1, !requirePumpBeforeWaypoint {
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
        let packRegions = GraphPackStore.regionIds(containingAny: [
            from.locationCoordinate, to.locationCoordinate
        ])
        let usesWindows = stopsNeeded > 3 || meters > 600_000 || packRegions.count > 1
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
            let departureAnchorID = windowStart == from
                ? (resumeAfterStation?.stationID ?? riderDepartureID)
                : output.last?.endsAtFuelStop?.stationID
            let requiredStationID = departureAnchorID.flatMap {
                riderLeg.fuelStopOverrides[$0]
            }
            let remainingProfileMeters = max(0, meters - routedMeters)
            let remainingStops = remainingProfileMeters <= windowFirstCap + 1
                ? 0
                : Int(ceil((remainingProfileMeters - windowFirstCap) / fuel.usableMeters))
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
                    priorEdgeIds: sublegHistory.edgeIDs,
                    arrivalEdgeId: sublegHistory.arrivalEdgeID,
                    backtrackFactor: 4,
                    excludedStationIds: Array(excluded),
                    windowMaxStops: !riderLeg.hopOverrides.isEmpty ? 1 : (usesWindows ? 3 : nil),
                    allowPartialWindow: !riderLeg.hopOverrides.isEmpty || usesWindows,
                    windowTimeBudgetMs: min(5_800, remainingBudgetMs),
                    requiredFirstStationId: requiredStationID
                ))
            } catch {
                let remaining = max(0, Int((fuel.usableMeters - used) / 1000))
                let reason = "No pump reachable with \(remaining) km remaining: \(error.localizedDescription)"
                throw RoutingError.fuelGap(FuelGap(
                    id: fuelGapID(
                        riderLegID: riderLeg.id,
                        gapMeters: remainingProfileMeters,
                        usableRangeMeters: fuel.usableMeters,
                        from: windowStart,
                        to: to
                    ),
                    gapMeters: remainingProfileMeters,
                    overByMeters: max(0, remainingProfileMeters - windowFirstCap),
                    usableRangeMeters: fuel.usableMeters,
                    remainingFuelMeters: windowFirstCap,
                    reason: reason,
                    fromCoordinate: windowStart,
                    toCoordinate: to
                ))
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
                let hopAllowUnknown = hopProfile == .cleanest ? false : riderLeg.allowUnknown
                let request = routeRequest(
                    profile: hopProfile,
                    allowUnknown: hopAllowUnknown,
                    from: points[subIndex],
                    to: points[subIndex + 1],
                    avoidEdgeIDs: itinerary.impassableEdgeIDs,
                    maxPathMeters: cap,
                    directExtraBudgetMeters: hopProfile == .direct ? 0 : nil,
                    history: sublegHistory
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

private func reusableLegs(
    from reuse: BuiltItinerary?,
    itinerary: RiderItinerary,
    before legIndex: Int
) -> [BuiltLeg] {
    guard let reuse else { return [] }
    let ids = Set(itinerary.legs.prefix(legIndex).map(\.id))
    return reuse.legs.filter { ids.contains($0.riderLegID) }
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
    before legIndex: Int
) -> [UUID: RouteResponse] {
    guard let reuse else { return [:] }
    var routes: [UUID: RouteResponse] = [:]
    for leg in itinerary.legs.prefix(legIndex) {
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
    let directLegCount = itinerary.legs.filter { $0.profile == .direct }.count
    let directExtraBudget = profile == .direct && directLegCount > 0
        ? 15_000 / Double(directLegCount)
        : nil
    return routeRequest(
        profile: profile,
        allowUnknown: profile == .cleanest ? false : leg.allowUnknown,
        from: itinerary.waypoints[legIndex].coordinate,
        to: itinerary.waypoints[legIndex + 1].coordinate,
        avoidEdgeIDs: itinerary.impassableEdgeIDs,
        maxPathMeters: maxPathMeters,
        directExtraBudgetMeters: directExtraBudget,
        history: history
    )
}

private func straightLineMeters(_ from: RouteCoordinate, _ to: RouteCoordinate) -> Double {
    CLLocation(latitude: from.latitude, longitude: from.longitude).distance(
        from: CLLocation(latitude: to.latitude, longitude: to.longitude)
    )
}

private func fuelStopCountNeeded(meters: Double, usableMeters: Double) -> Int {
    guard meters.isFinite, meters > 0, usableMeters > 0 else { return 0 }
    guard meters > usableMeters + 1 else { return 0 }
    return Int(ceil((meters - usableMeters) / usableMeters))
}

private func routeRequest(
    profile: RouteProfile,
    allowUnknown: Bool,
    from: RouteCoordinate,
    to: RouteCoordinate,
    avoidEdgeIDs: Set<String>,
    maxPathMeters: Double?,
    directExtraBudgetMeters: Double? = nil,
    history: EdgeHistory = EdgeHistory()
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
        directExtraBudgetMeters: directExtraBudgetMeters
    )
}

private struct EdgeHistory: Equatable {
    private(set) var edgeIDs: [String] = []
    private(set) var arrivalEdgeID: String?

    init() {}

    init(legs: [BuiltLeg]) {
        for leg in legs { append(leg.response) }
    }

    mutating func append(_ response: RouteResponse) {
        var seen = Set(edgeIDs)
        for segment in response.segments ?? [] {
            guard let id = segment.edgeId, !id.isEmpty else { continue }
            if seen.insert(id).inserted { edgeIDs.append(id) }
            arrivalEdgeID = id
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
