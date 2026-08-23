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
        fromFuelSequence: Int = 0,
        preserveFuelStops: Bool = false,
        reuse: BuiltItinerary?,
        fuel: FuelRangePrefs.Snapshot,
        source policy: RoutingSourcePolicy,
        onProgress: @MainActor (BuiltItinerary) -> Void
    ) async -> BuiltItinerary {
        currentGeneration = itinerary.generation
        let startIndex = min(max(0, legIndex), itinerary.legs.count)
        let kept = reusableLegs(from: reuse, itinerary: itinerary, before: startIndex)
        var statuses = Dictionary(
            uniqueKeysWithValues: itinerary.legs.map { ($0.id, LegStatus.pending) }
        )
        for leg in kept { statuses[leg.riderLegID] = .built }
        var committed = BuiltItinerary(
            generation: itinerary.generation,
            legs: kept,
            riderLegStatus: statuses
        )

        guard startIndex < itinerary.legs.count else {
            RoutingDebugLog.shared.event(
                "build committed gen=\(itinerary.generation) legs=\(kept.count)"
            )
            return committed
        }

        let firstRequest = routeRequest(
            itinerary: itinerary,
            legIndex: startIndex,
            maxPathMeters: nil
        )
        let selectedSource = policy.select(for: firstRequest)
        RoutingDebugLog.shared.event(
            "build start gen=\(itinerary.generation) fromLeg=\(startIndex) " +
                "fromFuelSeq=\(fromFuelSequence) reuseLegs=\(kept.count) " +
                "source=\(selectedSource.name)"
        )

        // Distance discovery is intentionally complete before the first fuel
        // decision. The next rider leg can therefore never be a nil fallback.
        var baseline: [Int: RouteResponse] = [:]
        var baselineHistory: [Int: EdgeHistory] = [:]
        var discoveryHistory = EdgeHistory(legs: kept)
        var baselineFailure: (index: Int, message: String)?
        for index in startIndex..<itinerary.legs.count {
            do {
                baselineHistory[index] = discoveryHistory
                let response = try await selectedSource.route(routeRequest(
                    itinerary: itinerary,
                    legIndex: index,
                    maxPathMeters: nil,
                    history: discoveryHistory
                ))
                guard active(itinerary) else {
                    return dropped(itinerary, committed: committed)
                }
                baseline[index] = response
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

        var fuelUsed = carriedFuel(from: kept)
        var finalHistory = EdgeHistory(legs: kept)
        let lastBuildable = baselineFailure?.index ?? itinerary.legs.count
        for index in startIndex..<lastBuildable {
            guard let base = baseline[index] else { break }
            let riderLeg = itinerary.legs[index]
            do {
                let builtLegs = try await buildRiderLeg(
                    itinerary: itinerary,
                    index: index,
                    baseline: base,
                    baselineHistory: baselineHistory[index] ?? EdgeHistory(),
                    allBaseline: baseline,
                    fuelUsedAtStart: fuelUsed,
                    fromFuelSequence: index == startIndex ? fromFuelSequence : 0,
                    preserveFuelStops: index == startIndex && preserveFuelStops,
                    reuse: reuse,
                    fuel: fuel,
                    source: selectedSource,
                    history: finalHistory
                )
                guard active(itinerary) else {
                    return dropped(itinerary, committed: committed)
                }
                committed = replacing(
                    riderLegID: riderLeg.id,
                    with: builtLegs,
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
                let message = error.localizedDescription
                committed = markingFailed(riderLeg.id, message: message, in: committed)
                RoutingDebugLog.shared.event(
                    "build failed riderLeg=\(riderLeg.id) msg=\(message)"
                )
                onProgress(committed)
                return committed
            }
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
        fromFuelSequence: Int,
        preserveFuelStops: Bool,
        reuse: BuiltItinerary?,
        fuel: FuelRangePrefs.Snapshot,
        source: any RoutingSource,
        history: EdgeHistory
    ) async throws -> [BuiltLeg] {
        let riderLeg = itinerary.legs[index]
        let riderStart = itinerary.waypoints[index].coordinate
        let to = itinerary.waypoints[index + 1].coordinate
        let keptHops = reusedFuelPrefix(
            from: reuse,
            riderLegID: riderLeg.id,
            beforeSequence: fromFuelSequence
        )
        let from: RouteCoordinate
        let fuelAtDeparture: Double
        if let last = keptHops.last {
            from = last.toCoordinate
            fuelAtDeparture = last.endsAtFuelStop != nil ? 0 : last.fuelUsedOnArrivalMeters
        } else {
            from = riderStart
            fuelAtDeparture = fuelUsedAtStart
        }
        var hopHistory = history
        for hop in keptHops { hopHistory.append(hop.response) }
        let sequenceBase = keptHops.filter { $0.endsAtFuelStop != nil }.count
        let meters = try responseMeters(baseline)
        guard fuel.isEnabled, fuel.usableMeters > 0 else {
            let finalResponse = baselineHistory == history
                ? baseline
                : try await source.route(routeRequest(
                    profile: riderLeg.profile,
                    allowUnknown: riderLeg.allowUnknown,
                    from: riderStart,
                    to: to,
                    avoidEdgeIDs: itinerary.impassableEdgeIDs,
                    maxPathMeters: nil,
                    history: history
                ))
            guard active(itinerary) else { throw CancellationError() }
            let finalMeters = try responseMeters(finalResponse)
            return [BuiltLeg(
                riderLegID: riderLeg.id,
                fromCoordinate: riderStart,
                toCoordinate: to,
                endsAtFuelStop: nil,
                response: finalResponse,
                fuelUsedOnArrivalMeters: fuelUsedAtStart + finalMeters
            )]
        }

        let firstCap = max(0, fuel.usableMeters - fuelAtDeparture)
        let nextMeters = allBaseline[index + 1]?.distanceMeters
        let requirePumpBeforeWaypoint: Bool
        if index + 1 < itinerary.legs.count {
            guard let nextMeters else {
                throw RoutingError.invalidResponse
            }
            let arrivalWithoutPump = fuelAtDeparture + meters
            requirePumpBeforeWaypoint = meters <= firstCap + 1
                && nextMeters > max(0, fuel.usableMeters - arrivalWithoutPump) + 1
        } else {
            requirePumpBeforeWaypoint = false
        }

        let pinnedPrefix = consecutiveAnchors(
            on: riderLeg.id,
            in: itinerary,
            fromSequence: sequenceBase == 0 ? 0 : fromFuelSequence,
            includeUnpinned: preserveFuelStops,
            includeUnpinnedBelow: sequenceBase == 0 && !preserveFuelStops ? fromFuelSequence : 0
        )
        if keptHops.isEmpty, pinnedPrefix.isEmpty, meters <= firstCap + 1, !requirePumpBeforeWaypoint {
            let arrival = fuelAtDeparture + meters
            RoutingDebugLog.shared.event(
                "fuel carry riderLeg=\(riderLeg.id) used=\(Int(arrival))"
            )
            return [BuiltLeg(
                riderLegID: riderLeg.id,
                fromCoordinate: from,
                toCoordinate: to,
                endsAtFuelStop: nil,
                response: baseline,
                fuelUsedOnArrivalMeters: arrival
            )]
        }

        var autoStops: [FuelChainStop] = []
        var candidateCount = 0
        if pinnedPrefix.isEmpty, !keptHops.isEmpty, !requirePumpBeforeWaypoint {
            let tailPolicy = itinerary.hopPolicy(riderLeg: riderLeg, sequence: sequenceBase)
            let tailRequest = routeRequest(
                profile: tailPolicy.profile,
                allowUnknown: tailPolicy.allowUnknown,
                from: from,
                to: to,
                avoidEdgeIDs: itinerary.impassableEdgeIDs,
                maxPathMeters: firstCap,
                history: hopHistory
            )
            let tailResponse = try await source.route(tailRequest)
            guard active(itinerary) else { throw CancellationError() }
            let tailMeters = try responseMeters(tailResponse)
            if tailMeters <= firstCap + 1 {
                return keptHops + [BuiltLeg(
                    riderLegID: riderLeg.id,
                    fromCoordinate: from,
                    toCoordinate: to,
                    endsAtFuelStop: nil,
                    response: tailResponse,
                    fuelUsedOnArrivalMeters: tailMeters
                )]
            }
        }
        if pinnedPrefix.isEmpty {
            let chain = try await source.fuelChain(FuelChainRequest(
                profile: riderLeg.profile,
                from: from,
                to: to,
                allowUnknown: riderLeg.allowUnknown,
                usableRangeMeters: fuel.usableMeters,
                firstLegMaxMeters: firstCap,
                requireFuelStopBeforeEnd: requirePumpBeforeWaypoint,
                avoidEdgeIds: Array(itinerary.impassableEdgeIDs),
                priorEdgeIds: hopHistory.edgeIDs,
                arrivalEdgeId: hopHistory.arrivalEdgeID,
                backtrackFactor: 4
            ))
            guard active(itinerary) else { throw CancellationError() }
            autoStops = chain.stops ?? []
            candidateCount = chain.stationCandidates?.count ?? 0
        } else {
            let lastPinned = pinnedPrefix[pinnedPrefix.count - 1]
            let remainderMeters: Double
            do {
                let remainder = try await source.route(routeRequest(
                    profile: riderLeg.profile,
                    allowUnknown: riderLeg.allowUnknown,
                    from: lastPinned.coordinate,
                    to: to,
                    avoidEdgeIDs: itinerary.impassableEdgeIDs,
                    maxPathMeters: fuel.usableMeters,
                    history: hopHistory
                ))
                guard active(itinerary) else { throw CancellationError() }
                remainderMeters = (try? responseMeters(remainder)) ?? .infinity
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                remainderMeters = .infinity
            }
            if remainderMeters > fuel.usableMeters + 1 || requirePumpBeforeWaypoint {
                let chain = try await source.fuelChain(FuelChainRequest(
                    profile: riderLeg.profile,
                    from: lastPinned.coordinate,
                    to: to,
                    allowUnknown: riderLeg.allowUnknown,
                    usableRangeMeters: fuel.usableMeters,
                    firstLegMaxMeters: fuel.usableMeters,
                    requireFuelStopBeforeEnd: requirePumpBeforeWaypoint,
                    avoidEdgeIds: Array(itinerary.impassableEdgeIDs),
                    priorEdgeIds: hopHistory.edgeIDs,
                    arrivalEdgeId: hopHistory.arrivalEdgeID,
                    backtrackFactor: 4
                ))
                guard active(itinerary) else { throw CancellationError() }
                autoStops = chain.stops ?? []
                candidateCount = chain.stationCandidates?.count ?? 0
            }
        }

        let stops = pinnedPrefix + autoStops
        guard !stops.isEmpty else {
            throw RoutingError.server("No route-connected fuel stop was returned for this leg.")
        }

        let points = [from] + stops.map(\.coordinate) + [to]
        var output: [BuiltLeg] = keptHops
        output.reserveCapacity(keptHops.count + points.count - 1)
        var used = fuelAtDeparture
        var sublegHistory = hopHistory
        for subIndex in 0..<(points.count - 1) {
            let cap = subIndex == 0 ? firstCap : fuel.usableMeters
            let policy = itinerary.hopPolicy(riderLeg: riderLeg, sequence: sequenceBase + subIndex)
            let request = routeRequest(
                profile: policy.profile,
                allowUnknown: policy.allowUnknown,
                from: points[subIndex],
                to: points[subIndex + 1],
                avoidEdgeIDs: itinerary.impassableEdgeIDs,
                maxPathMeters: cap,
                history: sublegHistory
            )
            let response = try await source.route(request)
            guard active(itinerary) else { throw CancellationError() }
            let subMeters = try responseMeters(response)
            sublegHistory.append(response)
            guard subMeters <= cap + 1 else {
                throw RoutingError.server("A selected fuel leg exceeds usable range.")
            }
            if subIndex < stops.count {
                let station = stops[subIndex]
                let identity = itinerary.fuelAnchors.first {
                    $0.riderLegID == riderLeg.id && $0.sequence == sequenceBase + subIndex
                }?.id ?? UUID()
                let stop = FuelStop(
                    id: identity,
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
                    fuelUsedOnArrivalMeters: 0
                ))
                let stationLog = station.id.isEmpty
                    ? "\(station.latitude),\(station.longitude)"
                    : station.id
                RoutingDebugLog.shared.event(
                    "fuel reset riderLeg=\(riderLeg.id) station=\(stationLog)"
                )
                RoutingDebugLog.shared.event(
                    "fuel station chosen riderLeg=\(riderLeg.id) station=\(stationLog) " +
                        "dirt%=\(response.dirtPercent) meters=\(Int(subMeters)) " +
                        "candidates=\(candidateCount)"
                )
                used = 0
            } else {
                used += subMeters
                output.append(BuiltLeg(
                    riderLegID: riderLeg.id,
                    fromCoordinate: points[subIndex],
                    toCoordinate: points[subIndex + 1],
                    endsAtFuelStop: nil,
                    response: response,
                    fuelUsedOnArrivalMeters: used
                ))
                RoutingDebugLog.shared.event(
                    "fuel carry riderLeg=\(riderLeg.id) used=\(Int(used))"
                )
            }
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

private func consecutiveAnchors(
    on riderLegID: UUID,
    in itinerary: RiderItinerary,
    fromSequence: Int,
    includeUnpinned: Bool,
    includeUnpinnedBelow: Int
) -> [FuelChainStop] {
    let anchors = itinerary.fuelAnchors
        .filter { $0.riderLegID == riderLegID }
        .sorted { $0.sequence < $1.sequence }
    var prefix: [FuelChainStop] = []
    var expected = fromSequence
    for anchor in anchors {
        if anchor.sequence < fromSequence { continue }
        guard anchor.sequence == expected else { break }
        let frozen = includeUnpinned || anchor.sequence < includeUnpinnedBelow
        guard anchor.isPinned || frozen else { break }
        prefix.append(FuelChainStop(
            id: anchor.stationID,
            latitude: anchor.coordinate.latitude,
            longitude: anchor.coordinate.longitude,
            name: anchor.name,
            brand: nil,
            address: nil,
            graphMeters: nil
        ))
        expected += 1
    }
    return prefix
}

private func reusedFuelPrefix(
    from reuse: BuiltItinerary?,
    riderLegID: UUID,
    beforeSequence: Int
) -> [BuiltLeg] {
    guard beforeSequence > 0, let reuse else { return [] }
    var kept: [BuiltLeg] = []
    var sequence = 0
    for hop in reuse.legs where hop.riderLegID == riderLegID {
        if sequence >= beforeSequence { break }
        kept.append(hop)
        if hop.endsAtFuelStop != nil { sequence += 1 }
    }
    let fuelCount = kept.filter { $0.endsAtFuelStop != nil }.count
    return fuelCount == beforeSequence ? kept : []
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

private func carriedFuel(from legs: [BuiltLeg]) -> Double {
    guard let last = legs.last else { return 0 }
    return last.endsAtFuelStop == nil ? last.fuelUsedOnArrivalMeters : 0
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
    history: EdgeHistory = EdgeHistory()
) -> RouteRequest {
    let leg = itinerary.legs[legIndex]
    return routeRequest(
        profile: leg.profile,
        allowUnknown: leg.allowUnknown,
        from: itinerary.waypoints[legIndex].coordinate,
        to: itinerary.waypoints[legIndex + 1].coordinate,
        avoidEdgeIDs: itinerary.impassableEdgeIDs,
        maxPathMeters: maxPathMeters,
        history: history
    )
}

private func routeRequest(
    profile: RouteProfile,
    allowUnknown: Bool,
    from: RouteCoordinate,
    to: RouteCoordinate,
    avoidEdgeIDs: Set<String>,
    maxPathMeters: Double?,
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
        maxPathMeters: maxPathMeters
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
        riderLegStatus: statuses
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
        riderLegStatus: statuses
    )
}
