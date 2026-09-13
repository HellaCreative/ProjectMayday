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
        guard req.options?.ridePreferences == nil else { throw RoutingError.server("Custom ride settings require online planning.") }
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
            packRevision: packs.routingCacheIdentity(),
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
            endEndpointKind: req.options?.endEndpointKind
        )
        try Task.checkCancellation()
        guard case .success(let local) = result, local.coordinates.count > 1 else {
            let failure: OnDeviceRouter.Failure? = {
                if case .failure(let reason) = result { return reason }
                return nil
            }()
            throw RoutingError.server(packs.onDeviceRouteFailureMessage(
                for: [endpoints.0.locationCoordinate, endpoints.1.locationCoordinate],
                reason: failure
            ))
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
        let deadline = RoutingWorkContext.limitedDeadline(milliseconds: req.fuel.windowTimeBudgetMs)
        return try await RoutingWorkContext.$deadline.withValue(deadline) {
            try await fuelChainUsingPack(req)
        }
    }

    private func fuelChainUsingPack(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        try RoutingWorkContext.check()
        guard req.options?.ridePreferences == nil else { throw RoutingError.server("Custom ride settings require online planning.") }
        guard req.locations.count == 2 else { throw RoutingError.invalidEndpoints }
        let start = coordinate(req.locations[0])
        let end = coordinate(req.locations[1])
        if req.fuel.initialFillUp == true { return try await initialFillUp(req, from: start) }
        let stations = packs.fuelStations(from: start, to: end)
        guard !stations.isEmpty else {
            try RoutingWorkContext.check()
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
            try RoutingWorkContext.check()
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
        var plannedRoutes: [RouteResponse] = []
        var stationCandidates: [FuelStationCandidate] = []
        let returnedStopLimit = min(12, max(1, req.fuel.windowMaxStops ?? 12))
        let maximumStops = returnedStopLimit
        var carriedHistory = Set(req.options?.priorEdgeIds ?? [])
        var carriedArrival = req.options?.arrivalEdgeId
        var roadProgress: FuelItinerary.RoadProgress?
        let fuelBegan = ProcessInfo.processInfo.systemUptime
        func trace(_ phase: String) {
            RoutingDebugLog.shared.event("pack fuel phase=\(phase) profile=\(req.profile.rawValue) elapsed=\(ProcessInfo.processInfo.systemUptime - fuelBegan)")
        }
        func retraceMeters(_ route: OnDeviceRouter.Result, history: Set<String>) -> Double {
            // Native search metadata alone does not include prior-window roads.
            max(route.backtrackMeters, route.legs.reduce(0) {
                $0 + (history.contains($1.edgeId) ? $1.distanceMeters : 0)
            })
        }

        while stops.count <= maximumStops {
            try RoutingWorkContext.check()
            let firstCap = stops.isEmpty
                ? req.fuel.firstLegMaxMeters
                : req.fuel.usableRangeMeters
            if stops.count >= maximumStops, req.fuel.allowPartialWindow == true {
                let visibleStops = Array(stops.prefix(returnedStopLimit))
                try RoutingWorkContext.check()
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
                    routes: Array(plannedRoutes.prefix(visibleStops.count)),
                    stationCandidates: stationCandidates,
                    windowComplete: false
                )
            }

            let direct = await packs.shortestGraphMeters(
                from: current.locationCoordinate,
                to: end.locationCoordinate,
                maxMeters: firstCap,
                profile: req.profile,
                allowUnknown: req.accessPolicy.motorizedUnknown
            )
            let mustPump = stops.count < req.fuel.minimumFuelStops
                || (stops.isEmpty && (req.fuel.requireFuelStopBeforeEnd || req.fuel.requiredFirstStationId != nil))
            let destinationLimit = req.fuel.destinationFuelUsedLimitMeters
            var incompleteSearchReason: String?
            var directFallback: Double?
            var directRoute: RouteResponse?
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
                    startEndpointKind: stops.isEmpty ? req.options?.startEndpointKind : "customers",
                    endEndpointKind: nil
                )
                if case .failure(.searchLimit(let reason)) = routed { incompleteSearchReason = reason }
                if case .success(let route) = routed, route.distanceMeters <= firstCap + 1,
                   (carriedHistory.isEmpty || retraceMeters(route, history: carriedHistory) <= 1_000) {
                    directFallback = route.distanceMeters
                    directRoute = RouteResponse(onDevice: route, priorEdgeIDs: carriedHistory)
                }
            }
            if let directFallback, !mustPump {
                let visibleStops = Array(stops.prefix(returnedStopLimit))
                let windowComplete = stops.count <= returnedStopLimit
                let visibleMeters = windowComplete
                    ? graphMeters + [directFallback]
                    : Array(graphMeters.prefix(visibleStops.count))
                try RoutingWorkContext.check()
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
                    routes: windowComplete ? plannedRoutes + [directRoute].compactMap { $0 } : Array(plannedRoutes.prefix(visibleStops.count)),
                    stationCandidates: stationCandidates,
                    windowComplete: windowComplete
                )
            }


            if stops.count >= maximumStops {
                return FuelChainResponse(status: "unknown", error: "fuel_window_stop_limit",
                    message: "Fuel planning reached its stop limit before proving the destination leg.",
                    regionIds: nil, stops: stops, graphMeters: graphMeters, diagnostics: nil,
                    routes: plannedRoutes, windowComplete: false)
            }
            if roadProgress == nil {
                roadProgress = await packs.fuelRoadProgress(from: current.locationCoordinate,
                    to: end.locationCoordinate, pumps: stations, profile: req.profile,
                    allowUnknown: req.accessPolicy.motorizedUnknown)
            }
            try RoutingWorkContext.check()
            guard let guidance = roadProgress else {
                return FuelChainResponse(status: "unknown", error: "road_progress_unavailable",
                    message: "A connected road direction to the destination has not been established.",
                    regionIds: nil, stops: stops, graphMeters: graphMeters, diagnostics: nil,
                    routes: plannedRoutes, windowComplete: false)
            }
            trace("guidance-ready")
            let currentRemaining = stops.last.flatMap { guidance.stationRemainingMeters[$0.id] }
                ?? guidance.originRemainingMeters
            let currentGuidance = FuelItinerary.RoadProgress(originRemainingMeters: currentRemaining,
                stationRemainingMeters: guidance.stationRemainingMeters)
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
                sessionSeed: req.options?.sessionSeed ?? 0,
                excluding: visited,
                roadProgress: currentGuidance
            )
            trace("candidates-\(ranked.count)")
            let departureID = stops.last?.id ?? "start"
            var evaluated: [FuelItinerary.ProfileFuelCandidate] = []
            var evaluatedRoutesByID: [String: OnDeviceRouter.Result] = [:]
            // Owner-directed forward ride: accept the first suitable proven leg.
            // Keep early/urban candidates as fallback while checking the existing
            // preferred fuel zone; do not optimize six complete future rides.
            let required = stops.isEmpty ? req.fuel.requiredFirstStationId : nil
            let urbanEntries = Dictionary(uniqueKeysWithValues: ranked.map { station in
                (station.id, FuelItinerary.fuelStopRequiresUrbanEntry(station,
                    start: current, destination: end, boxes: fuelAvoidanceBoxes))
            })
            // Preserve town avoidance before spending route work on candidates,
            // rather than discovering the preferred non-urban choice last.
            let nonUrban = ranked.filter { urbanEntries[$0.id] != true }
            let urban = ranked.filter { urbanEntries[$0.id] == true }
            let candidates = required.map { id in ranked.filter { $0.id == id } } ?? (FuelItinerary.distinctStationsFirst(nonUrban) + FuelItinerary.distinctStationsFirst(urban))
            for (rank, candidate) in candidates.enumerated() {
                try RoutingWorkContext.check()
                let urbanEntry = urbanEntries[candidate.id] == true
                let candidateCoordinate = CLLocationCoordinate2D(
                    latitude: candidate.latitude,
                    longitude: candidate.longitude
                )
                trace("leg-start-\(candidate.id)-road-\(Int(reachable[candidate.id] ?? 0))-cap-\(Int(firstCap))")
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
                    startEndpointKind: stops.isEmpty ? req.options?.startEndpointKind : "customers",
                    endEndpointKind: "customers"
                )
                try RoutingWorkContext.check()
                if case .failure(let reason) = firstResult {
                    RoutingDebugLog.shared.event("pack fuel leg-failed station=\(candidate.id) reason=\(reason)")
                }
                let firstUnverified: Bool
                if case .failure(.searchLimit(let reason)) = firstResult {
                    incompleteSearchReason = reason
                    firstUnverified = true
                } else {
                    firstUnverified = false
                }
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
                        validForward: firstUnverified ? nil : false,
                        urbanEntry: urbanEntry
                    ))
                    continue
                }
                trace("leg-proved-\(candidate.id)")
                evaluatedRoutesByID[candidate.id] = firstRoute
                let destinationCap = req.fuel.destinationFuelUsedLimitMeters
                    ?? req.fuel.usableRangeMeters
                // The next ride is built in its own window. Road distance is
                // only a continuation check, never a completed/fuel-proven tail.
                let destinationMayFit = (guidance.stationRemainingMeters[candidate.id] ?? .infinity) <= destinationCap
                // Near the destination, verify the exit before committing the
                // pump: a station down a long spur can otherwise force retrace
                // even though its overall road-distance progress is positive.
                let maximumFuelRetraceMeters = 1_000.0
                let firstRetrace = retraceMeters(firstRoute, history: carriedHistory)
                let avoidsMeaningfulRetrace = firstRetrace <= maximumFuelRetraceMeters
                var finalExitAvoidsRetrace = true
                // A rejected incoming leg cannot become valid by calculating an
                // exit. Preserve the same acceptance rule without spending a
                // second profile search on a station already known to retrace.
                if destinationMayFit && avoidsMeaningfulRetrace {
                    let exit = await packs.routeOnDeviceDetailed(
                        from: candidateCoordinate, to: end.locationCoordinate,
                        profile: req.profile, allowUnknown: req.accessPolicy.motorizedUnknown,
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
                        startEndpointKind: "customers", endEndpointKind: nil)
                    try RoutingWorkContext.check()
                    if case .success(let route) = exit {
                        finalExitAvoidsRetrace = route.distanceMeters <= destinationCap + 1
                            && retraceMeters(route, history: carriedHistory.union(firstRoute.edgeIds)) <= 1_000
                    } else {
                        finalExitAvoidsRetrace = false
                        if case .failure(.searchLimit(let reason)) = exit { incompleteSearchReason = reason }
                    }
                }
                let onward: [String: Double]
                if destinationMayFit || !avoidsMeaningfulRetrace {
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
                let hasOnwardPump = !destinationMayFit && !FuelItinerary.rankedProgressFuel(
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
                    excluding: onwardExclusions,
                    roadProgress: FuelItinerary.RoadProgress(
                        originRemainingMeters: guidance.stationRemainingMeters[candidate.id] ?? .infinity,
                        stationRemainingMeters: guidance.stationRemainingMeters)
                ).isEmpty
                // A forecourt connector may repeat briefly; a meaningful
                // down-and-back fuel stem is never a valid chain anchor.
                let validForward = (destinationMayFit || hasOnwardPump)
                    && avoidsMeaningfulRetrace && finalExitAvoidsRetrace
                trace("leg-assessed-\(candidate.id)-forward-\(validForward)-retrace-\(Int(firstRetrace))")
                let clean = FuelItinerary.cleanQuality(
                    firstRoute, penalizeMajorRoads: req.options?.avoidMotorways == true)
                evaluated.append(FuelItinerary.ProfileFuelCandidate(
                    fuel: candidate,
                    routedMeters: firstRoute.distanceMeters,
                    chainDirtPercent: Double(firstRoute.dirtPercent),
                    validForward: validForward,
                    cleanFallbackCount: clean.fallbackCount,
                    cleanMajorRoadMeters: clean.majorRoadMeters,
                    cleanRoutedMeters: clean.routedMeters,
                    chainBacktrackMeters: firstRetrace,
                    chainStopCount: destinationMayFit ? 1 : 2,
                    urbanEntry: urbanEntry,
                    progressMeters: currentRemaining - (guidance.stationRemainingMeters[candidate.id] ?? currentRemaining),
                    directionalDetourMeters: max(0, (reachable[candidate.id] ?? firstRoute.distanceMeters)
                        + (guidance.stationRemainingMeters[candidate.id] ?? currentRemaining) - currentRemaining),
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
                let reachesFuelZone = firstRoute.distanceMeters >= FuelItinerary.fuelSearchStartMeters(
                    firstLegMaxMeters: firstCap, usableRangeMeters: req.fuel.usableRangeMeters)
                if validForward && (required != nil || (!urbanEntry && reachesFuelZone)) { break }
            }
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
                    try RoutingWorkContext.check()
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
                        routes: windowComplete ? plannedRoutes + [directRoute].compactMap { $0 } : Array(plannedRoutes.prefix(visibleStops.count)),
                        stationCandidates: stationCandidates,
                        windowComplete: windowComplete
                    )
                }
                try RoutingWorkContext.check()
                if let incompleteSearchReason {
                    try RoutingWorkContext.check()
                    return FuelChainResponse(
                        status: "unknown", error: "on_device_search_incomplete",
                        message: "Fuel planning reached a search limit. A fuel gap has not been proved.",
                        regionIds: GraphPackStore.regionIds(containingAny: [start.locationCoordinate, end.locationCoordinate]),
                        stops: stops, graphMeters: graphMeters,
                        diagnostics: FuelChainDiagnostics(
                            strategy: "pack-forward-incomplete-\(incompleteSearchReason)",
                            states: stops.count + 1, dijkstraPops: nil,
                            matchedFuel: stations.count, elapsedMs: nil),
                        stationCandidates: stationCandidates, windowComplete: false)
                }
                let routedPrefix = graphMeters.reduce(0, +)
                let gap = max(0, req.fuel.profileMeters - routedPrefix)
                let remaining = stops.isEmpty ? req.fuel.firstLegMaxMeters : req.fuel.usableRangeMeters
                let forcedMessage = required.map {
                    "The selected fuel stop \($0) could not be included within the ride’s fuel and forward-progress constraints."
                }
                try RoutingWorkContext.check()
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
                plannedRoutes.append(RouteResponse(onDevice: route, priorEdgeIDs: carriedHistory))
                carriedHistory.formUnion(route.edgeIds)
                carriedArrival = route.edgeIds.last ?? carriedArrival
            }
        }
        let routedPrefix = graphMeters.reduce(0, +)
        let gap = max(0, req.fuel.profileMeters - routedPrefix)
        try RoutingWorkContext.check()
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

    /// The first refill is deliberately independent of forward progress and
    /// the later fuel search zone. A pump 500 metres away is still required.
    private func initialFillUp(_ req: FuelChainRequest, from start: RouteCoordinate) async throws -> FuelChainResponse {
        let excluded = Set((req.fuel.excludedStationIds ?? []).map(FuelItinerary.physicalStationID))
        let stations = packs.installedFuelStations().filter {
            !excluded.contains(FuelItinerary.physicalStationID($0.id))
        }
        let grouped = Dictionary(grouping: stations) {
            GraphPackStore.primaryRegionId(containing: .init(latitude: $0.latitude, longitude: $0.longitude)) ?? ""
        }
        var distances: [String: Double] = [:]
        for region in grouped.keys.sorted() {
            try RoutingWorkContext.check()
            guard let group = grouped[region], let first = group.first else { continue }
            let found = await packs.reachableFuelMeters(from: start.locationCoordinate,
                toward: .init(latitude: first.latitude, longitude: first.longitude), pumps: group,
                maxMeters: req.fuel.usableRangeMeters, profile: req.profile,
                allowUnknown: req.accessPolicy.motorizedUnknown)
            distances.merge(found, uniquingKeysWith: min)
        }
        let ranked = stations.filter { distances[$0.id] != nil }.sorted {
            let a = distances[$0.id]!, b = distances[$1.id]!
            return a == b ? $0.id < $1.id : a < b
        }
        let candidates = req.fuel.requiredFirstStationId.map { id in ranked.filter { $0.id == id } } ?? ranked
        for station in candidates {
            try RoutingWorkContext.check()
            let target = CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
            let result = await packs.routeOnDeviceDetailed(from: start.locationCoordinate, to: target,
                profile: req.profile, allowUnknown: req.accessPolicy.motorizedUnknown,
                avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
                priorEdgeIds: Set(req.options?.priorEdgeIds ?? []), arrivalEdgeId: req.options?.arrivalEdgeId,
                backtrackFactor: req.options?.backtrackFactor ?? 4, sessionSeed: req.options?.sessionSeed ?? 0,
                maxRouteMeters: req.fuel.usableRangeMeters,
                cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
                avoidMotorways: req.options?.avoidMotorways == true,
                preferBackRoads: req.options?.preferBackRoads == true,
                mapZoom: req.options?.mapZoom, matchLimitMeters: req.options?.matchLimitMeters,
                startEndpointKind: req.options?.startEndpointKind, endEndpointKind: "customers",
                initialFuelApproach: true)
            try RoutingWorkContext.check()
            switch result {
            case .success(let native):
                let route = RouteResponse(onDevice: native, priorEdgeIDs: Set(req.options?.priorEdgeIds ?? []))
                let stop = FuelChainStop(id: station.id, latitude: station.latitude,
                    longitude: station.longitude, name: station.name, brand: station.brand,
                    address: station.address, graphMeters: native.distanceMeters)
                return FuelChainResponse(status: "complete", error: nil, message: nil,
                    regionIds: nil, stops: [stop], graphMeters: [native.distanceMeters],
                    diagnostics: FuelChainDiagnostics(strategy: "pack-initial-refill", states: 1,
                        dijkstraPops: nil, matchedFuel: distances.count, elapsedMs: nil),
                    routes: [route], windowComplete: false)
            case .failure(.noPath): continue
            case .failure(let reason):
                RoutingDebugLog.shared.event("initial fuel candidate=\(station.id) failure=\(reason)")
                // An unfinished search cannot eliminate a nearer station.
                throw RoutingError.fuelUnknown("The closest fuel station has not been verified yet.")
            }
        }
        return FuelChainResponse(status: "unknown", error: "initial_fuel_unproved",
            message: "The initial fuel stop has not been established.", regionIds: nil,
            stops: [], graphMeters: [], diagnostics: nil, windowComplete: false)
    }

    /// The production fuel-data query, evaluated over installed station sidecars.
    /// Candidate reachability/ranking remains the itinerary builder's job.
    func fuelStations(near point: RouteCoordinate, within meters: Double) -> [FuelChainStop] {
        let pad = max(0.002, meters / 111_000)
        let longitudePad = pad / max(0.01, cos(point.latitude * .pi / 180))
        let candidates = packs.fuelStations(
            minLat: point.latitude - pad, maxLat: point.latitude + pad,
            minLon: point.longitude - longitudePad, maxLon: point.longitude + longitudePad)
        let origin = CLLocation(latitude: point.latitude, longitude: point.longitude)
        return candidates.compactMap { station -> (FuelChainStop, Double)? in
            let distance = origin.distance(from: CLLocation(latitude: station.latitude, longitude: station.longitude))
            guard distance <= meters else { return nil }
            return (FuelChainStop(id: station.id, latitude: station.latitude, longitude: station.longitude,
                name: station.name, brand: station.brand, address: station.address, graphMeters: 0), distance)
        }.sorted { $0.1 < $1.1 }.map { $0.0 }
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
        pack: any RoutingSource,
        onDeviceOnly: Bool = false
    ) {
        self.init(
            isOnline: { network.isOnline },
            installedPacks: packs,
            live: live,
            pack: pack,
            onDeviceOnly: onDeviceOnly
        )
    }

    init(
        isOnline: @escaping () -> Bool,
        installedPacks: any RoutingInstalledPackRegistry,
        live: any RoutingSource,
        pack: any RoutingSource,
        onDeviceOnly: Bool = false,
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
            let chosen = onDeviceOnly ? pack : (isOnline() ? live : pack)
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
        let repeatedMeters = max(local.backtrackMeters, local.legs.reduce(0.0) {
            priorEdgeIDs.contains($1.edgeId) ? $0 + $1.distanceMeters : $0
        })
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
