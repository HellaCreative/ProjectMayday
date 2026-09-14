import CoreLocation
import Foundation

@MainActor
protocol RoutingSource: AnyObject {
    var name: String { get }
    var supportsCombinedFuelPlanning: Bool { get }
    func route(_ req: RouteRequest) async throws -> RouteResponse
    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse
    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop?
}

extension RoutingSource {
    var supportsCombinedFuelPlanning: Bool { false }
}

@MainActor
final class RouteResponseCache {
    struct Key: Hashable, CustomStringConvertible {
        let from: RouteCoordinate
        let to: RouteCoordinate
        let profile: RouteProfile
        let allowUnknown: Bool
        let avoidEdgeIDs: [String]
        let priorEdgeIDs: [String]
        let arrivalEdgeID: String?
        let backtrackFactor: Double
        let sessionSeed: UInt64?
        let directExtraBudgetMeters: Double?
        let regionalHopMinimumMeters: [Double]
        let sourceName: String
        let packRevision: String
        let cleanMetroMultiplier: Double?
        let avoidMotorways: Bool
        let preferBackRoads: Bool
        var ridePreferences: RidePreferences? = nil
        let startEndpointKind: String?
        let endEndpointKind: String?

        var description: String {
            let recentPrior = priorEdgeIDs.suffix(4).joined(separator: ",")
            return "\(from.latitude),\(from.longitude)>\(to.latitude),\(to.longitude)" +
                "|\(profile.rawValue)|unknown=\(allowUnknown ? 1 : 0)" +
                "|avoid=\(avoidEdgeIDs.joined(separator: ","))" +
                "|prior=\(priorEdgeIDs.count)[\(recentPrior)]" +
                "|arrival=\(arrivalEdgeID ?? "nil")" +
                "|backtrack=\(backtrackFactor)" +
                "|seed=\(sessionSeed.map { String($0) } ?? "-")" +
                "|extra=\(directExtraBudgetMeters.map { String($0) } ?? "-")" +
                "|regional=\(regionalHopMinimumMeters.map { String($0) }.joined(separator: ","))" +
                "|metro=\(cleanMetroMultiplier.map { String(format: "%.0f", $0) } ?? "-")" +
                "|avoidMwy=\(avoidMotorways ? 1 : 0)|back=\(preferBackRoads ? 1 : 0)" +
                "|startKind=\(startEndpointKind ?? "-")|endKind=\(endEndpointKind ?? "-")" +
                "|\(sourceName)|\(packRevision)"
        }
    }

    private let capacity: Int
    private var values: [Key: RouteResponse] = [:]
    private var recency: [Key] = []

    init(capacity: Int = 64) {
        self.capacity = min(64, max(1, capacity))
    }

    func value(for key: Key) -> RouteResponse? {
        guard let value = values[key] else {
            RoutingDebugLog.shared.event("route cache miss key=\(key)")
            return nil
        }
        recency.removeAll { $0 == key }
        recency.append(key)
        RoutingDebugLog.shared.event("route cache hit key=\(key)")
        return value
    }

    func insert(_ value: RouteResponse, for key: Key) {
        values[key] = value
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    var count: Int { values.count }
}

@MainActor
final class LiveRoutingSource: RoutingSource {
    let name = "live"
    let supportsCombinedFuelPlanning = true
    private let client: RoutingClient
    private let cache: RouteResponseCache
    private let packRevision: () -> String
    private var fuelContextStationIDs: [String: [String]] = [:]
    private var fuelContextRecency: [String] = []

    init(
        client: RoutingClient,
        cache: RouteResponseCache,
        packRevision: @escaping () -> String
    ) {
        self.client = client
        self.cache = cache
        self.packRevision = packRevision
    }

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        let key = try cacheKey(req, sourceName: name, packRevision: packRevision())
        if req.options?.maxPathMeters == nil, let cached = cache.value(for: key) {
            return cached
        }
        if req.options?.maxPathMeters != nil {
            _ = cache.value(for: key)
        }
        if let from = req.locations.first, let to = req.locations.last {
            RoutingDebugLog.shared.routeAttempt(
                mode: name,
                from: (from.latitude, from.longitude),
                to: (to.latitude, to.longitude),
                profile: req.profile.rawValue,
                allowUnknown: req.accessPolicy.motorizedUnknown
            )
        }
        let response = try await client.route(req)
        if req.options?.maxPathMeters == nil { cache.insert(response, for: key) }
        return response
    }

    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        var request = req
        let canReuseContext = req.fuel.forwardFeeler != true
            && req.fuel.probeFirstReachableStation != true
        let contextKey = fuelContextKey(req)
        if canReuseContext,
           req.fuel.requiredFirstStationId == nil,
           let retained = fuelContextStationIDs[contextKey],
           !retained.isEmpty {
            request.fuel.preferredStationIds = retained
            RoutingDebugLog.shared.event(
                "fuel context reused candidates=\(retained.count) riderLeg=\(req.fuel.riderLegId)"
            )
        }
        let response = try await client.fuelChain(request)
        RoutingDebugLog.shared.event(
            "FUEL allowUnknown=\(req.accessPolicy.motorizedUnknown ? 1 : 0) "
                + "profile=\(req.profile.rawValue) "
                + "mapZoom=\(req.options?.mapZoom.map { String(format: "%.1f", $0) } ?? "-") "
                + "riderLeg=\(req.fuel.riderLegId)"
        )
        if canReuseContext, response.isComplete {
            var seen = Set<String>()
            let retained = ((response.stops ?? []).map(\.id) + (response.stationCandidates ?? [])
                .filter { $0.validForward == true }
                .map(\.id))
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .prefix(48)
            let stationIDs = Array(retained)
            if !stationIDs.isEmpty {
                fuelContextStationIDs[contextKey] = stationIDs
                fuelContextRecency.removeAll { $0 == contextKey }
                fuelContextRecency.append(contextKey)
                while fuelContextRecency.count > 16 {
                    let oldest = fuelContextRecency.removeFirst()
                    fuelContextStationIDs.removeValue(forKey: oldest)
                }
            }
        }
        return response
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        try await client.fuelStation(near: point, within: meters)
    }

    private func fuelContextKey(_ request: FuelChainRequest) -> String {
        let points = request.locations.map {
            String(format: "%.5f,%.5f", $0.latitude, $0.longitude)
        }.joined(separator: ">")
        let avoid = (request.options?.avoidEdgeIds ?? []).sorted().joined(separator: ",")
        return points
            + "|usable=\(Int(request.fuel.usableRangeMeters.rounded()))"
            + "|first=\(Int(request.fuel.firstLegMaxMeters.rounded()))"
            + "|avoid=\(avoid)"
    }
}

@MainActor
final class PackRoutingSource: RoutingSource {
    let name = "pack"
    private let packs: GraphPackStore
    private let cache: RouteResponseCache

    init(packs: GraphPackStore, cache: RouteResponseCache) {
        self.packs = packs
        self.cache = cache
    }

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        let endpoints = try routeEndpoints(req)
        let key = RouteResponseCache.Key(
            from: endpoints.0,
            to: endpoints.1,
            profile: req.profile,
            allowUnknown: req.accessPolicy.motorizedUnknown,
            avoidEdgeIDs: normalizedEdgeIDs(req.options?.avoidEdgeIds),
            priorEdgeIDs: normalizedEdgeIDs(req.options?.priorEdgeIds),
            arrivalEdgeID: req.options?.arrivalEdgeId,
            backtrackFactor: req.options?.backtrackFactor ?? 4,
            sessionSeed: req.options?.sessionSeed,
            directExtraBudgetMeters: req.options?.directExtraBudgetMeters,
            regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
            sourceName: name,
            packRevision: packs.lastManifestVersion,
            cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
            avoidMotorways: req.options?.avoidMotorways == true,
            preferBackRoads: req.options?.preferBackRoads == true,
            ridePreferences: req.options?.ridePreferences,
            startEndpointKind: req.options?.startEndpointKind,
            endEndpointKind: req.options?.endEndpointKind
        )
        if req.options?.maxPathMeters == nil, let cached = cache.value(for: key) {
            return cached
        }
        if req.options?.maxPathMeters != nil { _ = cache.value(for: key) }
        let result = await packs.routeOnDeviceDetailed(
            from: endpoints.0.locationCoordinate,
            to: endpoints.1.locationCoordinate,
            profile: req.profile,
            allowUnknown: req.accessPolicy.motorizedUnknown,
            avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
            priorEdgeIds: Set(req.options?.priorEdgeIds ?? []),
            arrivalEdgeId: req.options?.arrivalEdgeId,
            backtrackFactor: req.options?.backtrackFactor ?? 4,
            sessionSeed: req.options?.sessionSeed ?? 0,
            maxRouteMeters: req.options?.maxPathMeters,
            regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
            cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
            avoidMotorways: req.options?.avoidMotorways == true,
            preferBackRoads: req.options?.preferBackRoads == true,
            mapZoom: req.options?.mapZoom,
            matchLimitMeters: req.options?.matchLimitMeters,
            startEndpointKind: req.options?.startEndpointKind,
            endEndpointKind: req.options?.endEndpointKind,
            ridePreferences: req.options?.ridePreferences
        )
        guard case .success(let local) = result, local.coordinates.count > 1 else {
            throw RoutingError.server("No route is available on the installed pack.")
        }
        var response = RouteResponse(
            onDevice: local,
            priorEdgeIDs: Set(req.options?.priorEdgeIds ?? [])
        )
        var diagnostics = RouteResponseDiagnostics(
            cleanMetroMultiplier: req.options?.cleanMetroMultiplier
        )
        diagnostics.allowUnknown = req.accessPolicy.motorizedUnknown
        diagnostics.tapRadiusMeters = local.tapRadiusMeters
        diagnostics.mapZoom = local.mapZoom ?? req.options?.mapZoom
        diagnostics.snap = local.snapDiagnostics
        response.debug = RouteResponseDebug(
            routingRevision: nil,
            graphMode: "on-device",
            searchMeta: nil,
            fallback: nil,
            packIdentity: nil,
            diagnostics: diagnostics,
            failureReason: nil,
            searchMs: nil,
            pops: nil
        )
        RoutingDebugLog.shared.routeAttempt(
            mode: name,
            from: (endpoints.0.latitude, endpoints.0.longitude),
            to: (endpoints.1.latitude, endpoints.1.longitude),
            profile: req.profile.rawValue,
            allowUnknown: req.accessPolicy.motorizedUnknown
        )
        if let snap = local.snapDiagnostics {
            RoutingDebugLog.shared.snapSelection(
                allowUnknown: req.accessPolicy.motorizedUnknown,
                tapRadiusMeters: local.tapRadiusMeters,
                mapZoom: local.mapZoom ?? req.options?.mapZoom,
                start: snap.start,
                end: snap.end
            )
        }
        if req.options?.maxPathMeters == nil { cache.insert(response, for: key) }
        return response
    }

    /// Offline equivalent of the existing forward fuel-chain path: the pack's
    /// own reachability search proves each pump before it is committed.
    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        guard req.locations.count == 2 else { throw RoutingError.invalidEndpoints }
        let start = coordinate(req.locations[0])
        let end = coordinate(req.locations[1])
        let stations = packs.fuelStations(from: start, to: end)
        guard !stations.isEmpty else {
            return FuelChainResponse(
                status: "unknown",
                error: "fuel_data_unavailable",
                message: "Installed fuel data is unavailable for this part of the route.",
                regionIds: GraphPackStore.regionIds(containingAny: [
                    start.locationCoordinate, end.locationCoordinate
                ]),
                stops: [], graphMeters: [], diagnostics: nil
            )
        }
        if req.fuel.probeFirstReachableStation == true {
            let reachable = await packs.reachableFuelMeters(
                from: start.locationCoordinate,
                toward: end.locationCoordinate,
                pumps: stations,
                maxMeters: req.fuel.usableRangeMeters,
                profile: req.profile,
                allowUnknown: req.accessPolicy.motorizedUnknown
            )
            let first = reachable.values.min()
            return FuelChainResponse(
                status: "complete", error: nil, message: nil,
                regionIds: GraphPackStore.regionIds(containingAny: [
                    start.locationCoordinate, end.locationCoordinate
                ]),
                stops: [], graphMeters: [],
                diagnostics: FuelChainDiagnostics(
                    strategy: "pack-first-reachable-probe", states: 1,
                    dijkstraPops: nil, matchedFuel: reachable.count, elapsedMs: nil
                ),
                firstReachableStationMeters: first
            )
        }
        var current = start
        var visited = Set(req.fuel.excludedStationIds ?? [])
        var stops: [FuelChainStop] = []
        var graphMeters: [Double] = []
        var stationCandidates: [FuelStationCandidate] = []
        let returnedStopLimit = min(12, max(1, req.fuel.windowMaxStops ?? 12))
        let maximumStops = req.fuel.allowPartialWindow == true
            ? min(4, max(returnedStopLimit + 2, req.fuel.minimumFuelStops + 1))
            : returnedStopLimit
        var carriedHistory = Set(req.options?.priorEdgeIds ?? [])
        var carriedArrival = req.options?.arrivalEdgeId

        while stops.count <= maximumStops {
            try Task.checkCancellation()
            let firstCap = stops.isEmpty
                ? req.fuel.firstLegMaxMeters
                : req.fuel.usableRangeMeters
            let direct = await packs.shortestGraphMeters(
                from: current.locationCoordinate,
                to: end.locationCoordinate,
                maxMeters: firstCap,
                profile: req.profile,
                allowUnknown: req.accessPolicy.motorizedUnknown
            )
            let mustPump = stops.count < req.fuel.minimumFuelStops
                || (stops.isEmpty && req.fuel.requireFuelStopBeforeEnd)
            let destinationLimit = req.fuel.destinationFuelUsedLimitMeters
            var directFallback: Double?
            if let direct,
               destinationLimit == nil || direct <= (destinationLimit ?? .infinity) + 1 {
                let routed = await packs.routeOnDeviceDetailed(
                    from: current.locationCoordinate,
                    to: end.locationCoordinate,
                    profile: req.profile,
                    allowUnknown: req.accessPolicy.motorizedUnknown,
                    avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
                    priorEdgeIds: carriedHistory,
                    arrivalEdgeId: carriedArrival,
                    backtrackFactor: req.options?.backtrackFactor ?? 4,
                    sessionSeed: req.options?.sessionSeed ?? 0,
                    maxRouteMeters: firstCap,
                    regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
                    cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
                    avoidMotorways: req.options?.avoidMotorways == true,
                    preferBackRoads: req.options?.preferBackRoads == true,
                    startEndpointKind: stops.isEmpty ? nil : "customers",
                    endEndpointKind: nil
                )
                if case .success(let route) = routed, route.distanceMeters <= firstCap + 1 {
                    directFallback = route.distanceMeters
                }
            }
            if let directFallback, !mustPump {
                let visibleStops = Array(stops.prefix(returnedStopLimit))
                let windowComplete = stops.count <= returnedStopLimit
                let visibleMeters = windowComplete
                    ? graphMeters + [directFallback]
                    : Array(graphMeters.prefix(visibleStops.count))
                return FuelChainResponse(
                    status: "complete", error: nil, message: nil,
                    regionIds: GraphPackStore.regionIds(containingAny: [
                        start.locationCoordinate, end.locationCoordinate
                    ]),
                    stops: visibleStops, graphMeters: visibleMeters,
                    diagnostics: FuelChainDiagnostics(
                        strategy: "pack-forward", states: stops.count + 1,
                        dijkstraPops: nil, matchedFuel: stations.count, elapsedMs: nil
                    ),
                    stationCandidates: stationCandidates,
                    windowComplete: windowComplete
                )
            }

            if stops.count >= maximumStops, req.fuel.allowPartialWindow == true {
                let visibleStops = Array(stops.prefix(returnedStopLimit))
                return FuelChainResponse(
                    status: "complete", error: nil, message: nil,
                    regionIds: GraphPackStore.regionIds(containingAny: [
                        start.locationCoordinate, end.locationCoordinate
                    ]),
                    stops: visibleStops,
                    graphMeters: Array(graphMeters.prefix(visibleStops.count)),
                    diagnostics: FuelChainDiagnostics(
                        strategy: "pack-forward-window", states: stops.count,
                        dijkstraPops: nil, matchedFuel: stations.count, elapsedMs: nil
                    ),
                    stationCandidates: stationCandidates,
                    windowComplete: false
                )
            }

            let reachable = await packs.reachableFuelMeters(
                from: current.locationCoordinate,
                toward: end.locationCoordinate,
                pumps: stations,
                maxMeters: firstCap,
                profile: req.profile,
                allowUnknown: req.accessPolicy.motorizedUnknown
            )
            let fuelAvoidanceBoxes = await packs.fuelAvoidanceBoxes(
                from: current.locationCoordinate,
                toward: end.locationCoordinate
            )
            let ranked = FuelItinerary.rankedProgressFuel(
                fuels: stations,
                from: current,
                to: end,
                reachableMeters: reachable,
                tankMeters: firstCap,
                usableRangeMeters: req.fuel.usableRangeMeters,
                sessionSeed: 0,
                excluding: visited
            )
            let departureID = stops.last?.id ?? "start"
            var evaluated: [FuelItinerary.ProfileFuelCandidate] = []
            var evaluatedRoutesByID: [String: OnDeviceRouter.Result] = [:]
            // Match live: route-score every geographically bounded candidate.
            // Reachability keeps the rider safe; profile quality decides which
            // safe pump is worth riding to.
            for (rank, candidate) in ranked.prefix(6).enumerated() {
                let urbanEntry = FuelItinerary.fuelStopRequiresUrbanEntry(
                    candidate,
                    start: current,
                    destination: end,
                    boxes: fuelAvoidanceBoxes
                )
                let candidateCoordinate = CLLocationCoordinate2D(
                    latitude: candidate.latitude,
                    longitude: candidate.longitude
                )
                let firstResult = await packs.routeOnDeviceDetailed(
                    from: current.locationCoordinate,
                    to: candidateCoordinate,
                    profile: req.profile,
                    allowUnknown: req.accessPolicy.motorizedUnknown,
                    avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
                    priorEdgeIds: carriedHistory,
                    arrivalEdgeId: carriedArrival,
                    backtrackFactor: req.options?.backtrackFactor ?? 4,
                    sessionSeed: req.options?.sessionSeed ?? 0,
                    maxRouteMeters: firstCap,
                    regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
                    cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
                    avoidMotorways: req.options?.avoidMotorways == true,
                    preferBackRoads: req.options?.preferBackRoads == true,
                    startEndpointKind: stops.isEmpty ? nil : "customers",
                    endEndpointKind: "customers"
                )
                guard case .success(let firstRoute) = firstResult,
                      firstRoute.distanceMeters <= firstCap + 1
                else {
                    stationCandidates.append(FuelStationCandidate(
                        id: candidate.id,
                        meters: reachable[candidate.id] ?? 0,
                        dirtPct: 0,
                        departureId: departureID,
                        latitude: candidate.latitude,
                        longitude: candidate.longitude,
                        name: candidate.name ?? candidate.brand,
                        validForward: false,
                        urbanEntry: urbanEntry
                    ))
                    continue
                }
                evaluatedRoutesByID[candidate.id] = firstRoute
                let destinationCap = req.fuel.destinationFuelUsedLimitMeters
                    ?? req.fuel.usableRangeMeters
                let continuationResult = await packs.routeOnDeviceDetailed(
                    from: candidateCoordinate,
                    to: end.locationCoordinate,
                    profile: req.profile,
                    allowUnknown: req.accessPolicy.motorizedUnknown,
                    avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
                    priorEdgeIds: carriedHistory.union(firstRoute.edgeIds),
                    arrivalEdgeId: firstRoute.edgeIds.last ?? carriedArrival,
                    backtrackFactor: req.options?.backtrackFactor ?? 4,
                    sessionSeed: req.options?.sessionSeed ?? 0,
                    maxRouteMeters: destinationCap,
                    regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
                    cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
                    avoidMotorways: req.options?.avoidMotorways == true,
                    preferBackRoads: req.options?.preferBackRoads == true,
                    startEndpointKind: "customers",
                    endEndpointKind: nil
                )
                let continuationRoute: OnDeviceRouter.Result?
                if case .success(let route) = continuationResult,
                   route.distanceMeters <= destinationCap + 1 {
                    continuationRoute = route
                } else {
                    continuationRoute = nil
                }
                let onward: [String: Double]
                if continuationRoute != nil {
                    onward = [:]
                } else {
                    onward = await packs.reachableFuelMeters(
                        from: candidateCoordinate,
                        toward: end.locationCoordinate,
                        pumps: stations,
                        maxMeters: req.fuel.usableRangeMeters,
                        profile: req.profile,
                        allowUnknown: req.accessPolicy.motorizedUnknown
                    )
                }
                var onwardExclusions = visited
                onwardExclusions.insert(candidate.id)
                let hasOnwardPump = continuationRoute == nil && !FuelItinerary.rankedProgressFuel(
                    fuels: stations,
                    from: RouteCoordinate(
                        longitude: candidate.longitude,
                        latitude: candidate.latitude
                    ),
                    to: end,
                    reachableMeters: onward,
                    tankMeters: req.fuel.usableRangeMeters,
                    usableRangeMeters: req.fuel.usableRangeMeters,
                    sessionSeed: req.options?.sessionSeed ?? 0,
                    excluding: onwardExclusions
                ).isEmpty
                // A forecourt connector may repeat briefly; a meaningful
                // down-and-back fuel stem is never a valid chain anchor.
                let maximumFuelRetraceMeters = 1_000.0
                let avoidsMeaningfulRetrace = firstRoute.backtrackMeters <= maximumFuelRetraceMeters
                    && (continuationRoute?.backtrackMeters ?? 0) <= maximumFuelRetraceMeters
                let validForward = (continuationRoute != nil || hasOnwardPump)
                    && avoidsMeaningfulRetrace
                let chainDirt: Double
                if let continuationRoute {
                    let total = firstRoute.distanceMeters + continuationRoute.distanceMeters
                    chainDirt = total > 0
                        ? (firstRoute.distanceMeters * Double(firstRoute.dirtPercent)
                            + continuationRoute.distanceMeters * Double(continuationRoute.dirtPercent)) / total
                        : Double(firstRoute.dirtPercent)
                } else {
                    chainDirt = Double(firstRoute.dirtPercent)
                }
                var clean = FuelItinerary.cleanQuality(
                    firstRoute,
                    penalizeMajorRoads: req.options?.avoidMotorways == true
                )
                if let continuationRoute {
                    let tail = FuelItinerary.cleanQuality(
                        continuationRoute,
                        penalizeMajorRoads: req.options?.avoidMotorways == true
                    )
                    clean.fallbackCount += tail.fallbackCount
                    clean.majorRoadMeters += tail.majorRoadMeters
                    clean.routedMeters += tail.routedMeters
                }
                evaluated.append(FuelItinerary.ProfileFuelCandidate(
                    fuel: candidate,
                    routedMeters: firstRoute.distanceMeters,
                    chainDirtPercent: chainDirt,
                    validForward: validForward,
                    cleanFallbackCount: clean.fallbackCount,
                    cleanMajorRoadMeters: clean.majorRoadMeters,
                    cleanRoutedMeters: clean.routedMeters,
                    chainBacktrackMeters: firstRoute.backtrackMeters
                        + (continuationRoute?.backtrackMeters ?? 0),
                    chainStopCount: continuationRoute == nil ? 2 : 1,
                    urbanEntry: urbanEntry,
                    progressMeters: GeoMath.progressAlongAB(from: current, to: end, point: RouteCoordinate(
                        longitude: candidate.longitude,
                        latitude: candidate.latitude
                    )),
                    directionalDetourMeters: abs(GeoMath.crossTrackMeters(
                        point: candidateCoordinate,
                        lineFrom: current.locationCoordinate,
                        to: end.locationCoordinate
                    )),
                    discoveryRank: rank
                ))
                stationCandidates.append(FuelStationCandidate(
                    id: candidate.id,
                    meters: firstRoute.distanceMeters,
                    dirtPct: firstRoute.dirtPercent,
                    departureId: departureID,
                    latitude: candidate.latitude,
                    longitude: candidate.longitude,
                    name: candidate.name ?? candidate.brand,
                    validForward: validForward,
                    urbanEntry: urbanEntry
                ))
            }
            let required = stops.isEmpty ? req.fuel.requiredFirstStationId : nil
            let choices = FuelItinerary.eligibleProfileFuelCandidates(
                evaluated,
                firstLegMaxMeters: firstCap,
                usableRangeMeters: req.fuel.usableRangeMeters,
                requiredFirstStationID: required
            ).sorted {
                FuelItinerary.prefersProfileFuelCandidate(
                    $0, over: $1, profile: req.profile, tankMeters: firstCap
                )
            }
            guard let choice = choices.first else {
                if let directFallback,
                   !mustPump,
                   !(stops.isEmpty && req.fuel.requiredFirstStationId != nil) {
                    let visibleStops = Array(stops.prefix(returnedStopLimit))
                    let windowComplete = stops.count <= returnedStopLimit
                    let visibleMeters = windowComplete
                        ? graphMeters + [directFallback]
                        : Array(graphMeters.prefix(visibleStops.count))
                    return FuelChainResponse(
                        status: "complete", error: nil, message: nil,
                        regionIds: GraphPackStore.regionIds(containingAny: [
                            start.locationCoordinate, end.locationCoordinate
                        ]),
                        stops: Array(stops.prefix(returnedStopLimit)),
                        graphMeters: visibleMeters,
                        diagnostics: FuelChainDiagnostics(
                            strategy: "pack-forward-hard-cap-fallback", states: stops.count + 1,
                            dijkstraPops: nil, matchedFuel: stations.count, elapsedMs: nil
                        ),
                        stationCandidates: stationCandidates,
                        windowComplete: windowComplete
                    )
                }
                let routedPrefix = graphMeters.reduce(0, +)
                let gap = max(0, req.fuel.profileMeters - routedPrefix)
                let remaining = stops.isEmpty ? req.fuel.firstLegMaxMeters : req.fuel.usableRangeMeters
                let forcedMessage = required.map {
                    "The selected fuel stop \($0) is not reachable without stranding the next section."
                }
                return FuelChainResponse(
                    status: "gap",
                    error: "no_route_connected_fuel_chain",
                    message: forcedMessage ?? "No route-connected fuel chain fits the usable range.",
                    regionIds: GraphPackStore.regionIds(containingAny: [
                        start.locationCoordinate, end.locationCoordinate
                    ]),
                    stops: stops,
                    graphMeters: graphMeters,
                    diagnostics: FuelChainDiagnostics(
                        strategy: "pack-forward-gap", states: stops.count + 1,
                        dijkstraPops: nil, matchedFuel: stations.count, elapsedMs: nil
                    ),
                    stationCandidates: stationCandidates,
                    gapMeters: gap,
                    overByMeters: max(0, gap - remaining)
                )
            }
            let station = choice.fuel
            let meters = choice.routedMeters
            visited.insert(station.id)
            graphMeters.append(meters)
            stops.append(FuelChainStop(
                id: station.id,
                latitude: station.latitude,
                longitude: station.longitude,
                name: station.name,
                brand: station.brand,
                address: nil,
                graphMeters: meters
            ))
            current = RouteCoordinate(longitude: station.longitude, latitude: station.latitude)
            // Repeated edges and immediate U-turns remain expensive on every
            // downstream hop, not just the first request in the chain.
            if let route = evaluatedRoutesByID[station.id] {
                carriedHistory.formUnion(route.edgeIds)
                carriedArrival = route.edgeIds.last ?? carriedArrival
            }
        }
        let routedPrefix = graphMeters.reduce(0, +)
        let gap = max(0, req.fuel.profileMeters - routedPrefix)
        return FuelChainResponse(
            status: "gap",
            error: "no_route_connected_fuel_chain",
            message: "No route-connected fuel chain fits the usable range.",
            regionIds: GraphPackStore.regionIds(containingAny: [
                start.locationCoordinate, end.locationCoordinate
            ]),
            stops: stops,
            graphMeters: graphMeters,
            diagnostics: FuelChainDiagnostics(
                strategy: "pack-forward-gap", states: stops.count,
                dijkstraPops: nil, matchedFuel: stations.count, elapsedMs: nil
            ),
            stationCandidates: stationCandidates,
            gapMeters: gap,
            overByMeters: max(0, gap - req.fuel.usableRangeMeters)
        )
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        let pad = max(0.002, meters / 111_000)
        let candidates = packs.fuelStations(
            minLat: point.latitude - pad,
            maxLat: point.latitude + pad,
            minLon: point.longitude - pad,
            maxLon: point.longitude + pad
        )
        return FuelItinerary.nearestFuelStation(
            to: point,
            stations: candidates,
            within: meters
        ).map { hit in
            FuelChainStop(
                id: hit.station.id, latitude: hit.station.latitude, longitude: hit.station.longitude,
                name: hit.station.name, brand: hit.station.brand, address: hit.station.address,
                graphMeters: 0
            )
        }
    }
}

@MainActor
protocol RoutingInstalledPackRegistry: AnyObject {
    var routingManifestVersion: String { get }
    func isRoutingPackInstalled(_ regionID: String) -> Bool
    func installedRoutingGraphPath(regionID: String) -> String?
}

extension GraphPackStore: PackCoverageInspecting, PackInstalling {
    var routingManifestVersion: String { lastManifestVersion }

    func isRoutingPackInstalled(_ regionID: String) -> Bool {
        isInstalled(regionID)
    }

    func installedRoutingGraphPath(regionID: String) -> String? {
        installedGraphPath(regionId: regionID)
    }
}

@MainActor
struct RoutingSourcePolicy {
    private let selector: @MainActor (RouteRequest) -> any RoutingSource

    init(selector: @escaping @MainActor (RouteRequest) -> any RoutingSource) {
        self.selector = selector
    }

    init(
        network: NetworkPathMonitor,
        packs: GraphPackStore,
        live: any RoutingSource,
        pack: any RoutingSource
    ) {
        self.init(
            isOnline: { network.isOnline },
            installedPacks: packs,
            live: live,
            pack: pack
        )
    }

    init(
        isOnline: @escaping () -> Bool,
        installedPacks: any RoutingInstalledPackRegistry,
        live: any RoutingSource,
        pack: any RoutingSource,
        report: @escaping @MainActor (String) -> Void = { RoutingDebugLog.shared.event($0) }
    ) {
        selector = { request in
            let locations = request.locations.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            let needed = GraphPackStore.regionIds(containingAny: locations)
            let provinces = GraphPackStore.endpointProvinceIds(containingAny: locations)
            let installed = needed.filter { installedPacks.isRoutingPackInstalled($0) }
            let packsCover = installedPacksCover(locations, registry: installedPacks)
            let singleRegion = provinces.count <= 1
            let chosen = packsCover ? pack : (isOnline() ? live : pack)
            report(
                "policy packsCover=\(packsCover) singleRegion=\(singleRegion) " +
                    "provinces=[\(provinces.joined(separator: ","))] " +
                    "installed=[\(installed.joined(separator: ","))] " +
                    "path=\(needed.first.flatMap { installedPacks.installedRoutingGraphPath(regionID: $0) } ?? "nil") " +
                    "manifest=\(installedPacks.routingManifestVersion) online=\(isOnline()) " +
                    "selected=\(chosen.name)"
            )
            return chosen
        }
    }

    static func fixed(_ source: any RoutingSource) -> RoutingSourcePolicy {
        RoutingSourcePolicy { _ in source }
    }

    func select(for request: RouteRequest) -> any RoutingSource {
        selector(request)
    }
}

private func installedPacksCover(
    _ endpoints: [CLLocationCoordinate2D],
    registry: any RoutingInstalledPackRegistry
) -> Bool {
    let needed = GraphPackStore.regionIds(containingAny: endpoints)
    if !needed.isEmpty, needed.allSatisfy({ registry.isRoutingPackInstalled($0) }) { return true }
    let primaries = endpoints.compactMap { GraphPackStore.primaryRegionId(containing: $0) }
    guard let first = primaries.first, primaries.allSatisfy({ $0 == first }) else { return false }
    return registry.isRoutingPackInstalled(first)
}

private func coordinate(_ location: RouteLocation) -> RouteCoordinate {
    RouteCoordinate(longitude: location.longitude, latitude: location.latitude)
}

private func routeEndpoints(_ request: RouteRequest) throws -> (RouteCoordinate, RouteCoordinate) {
    guard request.locations.count == 2 else { throw RoutingError.invalidEndpoints }
    return (coordinate(request.locations[0]), coordinate(request.locations[1]))
}

private func cacheKey(
    _ request: RouteRequest,
    sourceName: String,
    packRevision: String
) throws -> RouteResponseCache.Key {
    let endpoints = try routeEndpoints(request)
    return RouteResponseCache.Key(
        from: endpoints.0, to: endpoints.1, profile: request.profile,
        allowUnknown: request.accessPolicy.motorizedUnknown,
        avoidEdgeIDs: normalizedEdgeIDs(request.options?.avoidEdgeIds),
        priorEdgeIDs: normalizedEdgeIDs(request.options?.priorEdgeIds),
        arrivalEdgeID: request.options?.arrivalEdgeId,
        backtrackFactor: request.options?.backtrackFactor ?? 4,
        sessionSeed: request.options?.sessionSeed,
        directExtraBudgetMeters: request.options?.directExtraBudgetMeters,
        regionalHopMinimumMeters: request.options?.regionalHopMinimumMeters ?? [],
        sourceName: sourceName, packRevision: packRevision,
        cleanMetroMultiplier: request.options?.cleanMetroMultiplier,
        avoidMotorways: request.options?.avoidMotorways == true,
        preferBackRoads: request.options?.preferBackRoads == true,
        ridePreferences: request.options?.ridePreferences,
        startEndpointKind: request.options?.startEndpointKind,
        endEndpointKind: request.options?.endEndpointKind
    )
}

private func normalizedEdgeIDs(_ ids: [String]?) -> [String] {
    Array(Set(ids ?? [])).sorted()
}

private extension RouteResponse {
    init(onDevice local: OnDeviceRouter.Result, priorEdgeIDs: Set<String>) {
        let geometry = local.coordinates.map {
            RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude)
        }
        let segments = local.legs.map { leg in
            RouteSegment(
                surfaceClass: leg.paintSurfaceName,
                trackClass: leg.roadClassName,
                accessClass: leg.accessName,
                distanceMeters: leg.distanceMeters,
                geometry: leg.coordinates.map {
                    RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude)
                },
                coords: nil,
                edgeId: leg.edgeId.isEmpty ? nil : leg.edgeId,
                structureType: leg.structureType,
                structureLeaf: leg.structureLeaf,
                layer: leg.layer,
                crossingLabel: leg.crossingLabel,
                waterCrossing: leg.waterCrossing,
                surfaceLeaf: leg.surfaceLeaf
            )
        }
        let repeatedMeters = local.legs.reduce(0.0) {
            priorEdgeIDs.contains($1.edgeId) ? $0 + $1.distanceMeters : $0
        }
        let repeatedPct = local.distanceMeters > 0
            ? repeatedMeters / local.distanceMeters * 100
            : 0
        self.init(
            status: "complete", error: nil, message: nil,
            distanceMeters: local.distanceMeters,
            estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
            geometry: geometry, segments: segments,
            stats: RouteStats(
                dirtPercent: local.reportedDirtPercent,
                pavedPercent: local.reportedPavedPercent,
                unknownAccessPercent: local.unknownAccessPercent,
                unknownSurfacePercent: local.unknownSurfacePercent,
                surfaceFamilyMode: local.hasSurfaceLeaves ? "leaf-v3" : nil
            ),
            maneuvers: local.maneuvers, warnings: nil,
            dirtPercentValue: nil, pavedPercentValue: nil,
            backtrackMeters: repeatedMeters,
            backtrackPct: repeatedPct,
            backtrackReason: repeatedMeters > 0 ? "dead_end_or_only_connector" : nil,
            restrictedMeters: 0,
            restrictedReason: nil
        )
    }
}
