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
                "reuseLegs=\(kept.count) source=\(selectedSource.name)"
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
        fuel: FuelRangePrefs.Snapshot,
        source: any RoutingSource,
        history: EdgeHistory
    ) async throws -> [BuiltLeg] {
        let riderLeg = itinerary.legs[index]
        let from = itinerary.waypoints[index].coordinate
        let to = itinerary.waypoints[index + 1].coordinate
        let meters = try responseMeters(baseline)
        guard fuel.isEnabled, fuel.usableMeters > 0 else {
            let finalResponse = baselineHistory == history
                ? baseline
                : try await source.route(routeRequest(
                    itinerary: itinerary,
                    legIndex: index,
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
                fuelUsedOnArrivalMeters: fuelUsedAtStart + finalMeters
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
        let nextMeters = allBaseline[index + 1]?.distanceMeters
        let requirePumpBeforeWaypoint: Bool
        let destinationFuelUsedLimitMeters: Double?
        if index + 1 < itinerary.legs.count {
            guard let nextMeters else {
                throw RoutingError.invalidResponse
            }
            let arrivalWithoutPump = fuelUsedAtStart + meters
            requirePumpBeforeWaypoint = meters <= firstCap + 1
                && nextMeters > max(0, fuel.usableMeters - arrivalWithoutPump) + 1
            destinationFuelUsedLimitMeters = requirePumpBeforeWaypoint && nextMeters <= fuel.usableMeters + 1
                ? max(0, fuel.usableMeters - nextMeters)
                : nil
        } else {
            requirePumpBeforeWaypoint = false
            destinationFuelUsedLimitMeters = nil
        }

        if meters <= firstCap + 1, !requirePumpBeforeWaypoint {
            let arrival = fuelUsedAtStart + meters
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

        let chain = try await source.fuelChain(FuelChainRequest(
            profile: riderLeg.profile,
            from: from,
            to: to,
            allowUnknown: riderLeg.allowUnknown,
            usableRangeMeters: fuel.usableMeters,
            firstLegMaxMeters: firstCap,
            requireFuelStopBeforeEnd: requirePumpBeforeWaypoint || stopsNeeded > 0,
            minimumFuelStops: stopsNeeded,
            destinationFuelUsedLimitMeters: destinationFuelUsedLimitMeters,
            profileMeters: meters,
            riderLegId: riderLeg.id.uuidString,
            avoidEdgeIds: Array(itinerary.impassableEdgeIDs),
            priorEdgeIds: history.edgeIDs,
            arrivalEdgeId: history.arrivalEdgeID,
            backtrackFactor: 4
        ))
        guard active(itinerary) else { throw CancellationError() }
        let stops = chain.stops ?? []
        guard !stops.isEmpty else {
            throw RoutingError.server("No route-connected fuel stop was returned for this leg.")
        }

        let points = [from] + stops.map(\.coordinate) + [to]
        var output: [BuiltLeg] = []
        output.reserveCapacity(points.count - 1)
        var used = fuelUsedAtStart
        var sublegHistory = history
        for subIndex in 0..<(points.count - 1) {
            let cap = subIndex == 0 ? firstCap : fuel.usableMeters
            let request = routeRequest(
                profile: riderLeg.profile,
                allowUnknown: riderLeg.allowUnknown,
                from: points[subIndex],
                to: points[subIndex + 1],
                avoidEdgeIDs: itinerary.impassableEdgeIDs,
                maxPathMeters: cap,
                directExtraBudgetMeters: riderLeg.profile == .direct ? 0 : nil,
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
                        "candidates=\(chain.stationCandidates?.count ?? 0)"
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
    let directLegCount = itinerary.legs.filter { $0.profile == .direct }.count
    let directExtraBudget = leg.profile == .direct && directLegCount > 0
        ? 15_000 / Double(directLegCount)
        : nil
    return routeRequest(
        profile: leg.profile,
        allowUnknown: leg.allowUnknown,
        from: itinerary.waypoints[legIndex].coordinate,
        to: itinerary.waypoints[legIndex + 1].coordinate,
        avoidEdgeIDs: itinerary.impassableEdgeIDs,
        maxPathMeters: maxPathMeters,
        directExtraBudgetMeters: directExtraBudget,
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
