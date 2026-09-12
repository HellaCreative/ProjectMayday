import CoreLocation
import Foundation

@MainActor
protocol RoutingSource: AnyObject {
    var name: String { get }
    var supportsCombinedFuelPlanning: Bool { get }
    /// Whether the source can prove a short ordinary route locally before
    /// entering the fuel-chain planner. Test doubles and remote sources keep
    /// the conservative default; the packed on-device source opts in.
    var supportsDirectFuelCarry: Bool { get }
    func route(_ req: RouteRequest) async throws -> RouteResponse
    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse
    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop?
}

extension RoutingSource {
    var supportsCombinedFuelPlanning: Bool { false }
    var supportsDirectFuelCarry: Bool { false }
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
    let supportsDirectFuelCarry = true
    private let packs: GraphPackStore
    private let cache: RouteResponseCache

    init(packs: GraphPackStore, cache: RouteResponseCache) {
        self.packs = packs
        self.cache = cache
    }

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        let endpoints = try routeEndpoints(req)
        // A DEV build must never silently exercise a previous candidate. The
        // old behavior searched every version directory and routed from the
        // first checksum-valid graph, which made an apparently successful
        // phone run impossible to compare with the current pack candidate.
        // Pack identity is checked from the installed release directory so
        // this route path remains fully offline.
        let neededRegions = GraphPackStore.regionIds(containingAny: [
            endpoints.0.locationCoordinate,
            endpoints.1.locationCoordinate
        ])
        let revisionStates = neededRegions.map {
            "\($0)=\(packs.packRevisionState($0).rawValue)"
        }.joined(separator: ",")
        let identities = neededRegions.compactMap {
            packs.installedRoutingPackIdentity(regionId: $0)
        }
        let identitySummary = identities.map { identity in
            "\(identity.regionId ?? "?")@\(identity.releaseId ?? "?")/\((identity.graphSha256 ?? "-").prefix(8))"
        }.joined(separator: ",")
        RoutingDebugLog.shared.event(
            "on-device identity manifest=\(packs.lastManifestVersion) "
                + "needed=[\(neededRegions.joined(separator: ","))] "
                + "states=[\(revisionStates)] identities=[\(identitySummary)]"
        )
        #if DIRT_DEVELOPMENT
        let staleRegions = neededRegions.filter { packs.packRevisionState($0) == .stale }
        if !staleRegions.isEmpty {
            let titles = staleRegions.map { packs.displayTitle(forRegionId: $0) }
            throw RoutingError.server(
                "Update the installed routing pack before planning on this DEV build: "
                    + titles.joined(separator: ", ") + "."
            )
        }
        #endif
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
            preferBackRoads: req.options?.preferBackRoads == true
        )
        if req.options?.maxPathMeters == nil, let cached = cache.value(for: key) {
            return cached
        }
        if req.options?.maxPathMeters != nil { _ = cache.value(for: key) }
        // A direct phone route has the same rider-facing contract as the
        // bounded fuel path: return a qualified result quickly or surface a
        // bounded failure. Without this deadline a no-path Dirt search could
        // spend the router's seven-second candidate cap before the UI learned
        // that the request was not viable.
        // The measured 40 km Dirt envelope completes the difficult same-region
        // Yarmouth case in about 2.06 s on the simulator. Keep a narrow 2.2 s
        // ceiling there so a dead search returns promptly. A cross-region
        // route must prove one legal hop per pack; give that bounded chain
        // enough time to finish its two searches without falling back to the
        // old seven-second candidate cap.
        let fastBudget: TimeInterval = neededRegions.count > 1 ? 3.5 : 2.2
        let fastDeadline = Date().addingTimeInterval(fastBudget)
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
            fastSearch: true,
            deadline: fastDeadline
        )
        guard case .success(let local) = result, local.coordinates.count > 1 else {
            RoutingDebugLog.shared.event(
                "on-device route failed from=\(endpoints.0.latitude),\(endpoints.0.longitude) "
                    + "to=\(endpoints.1.latitude),\(endpoints.1.longitude) "
                    + "profile=\(req.profile.rawValue) reason=\(String(describing: result))"
            )
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
        diagnostics.searchMs = local.searchMeta.elapsedMs
        diagnostics.pops = local.searchMeta.pops
        diagnostics.corridorMeters = local.searchMeta.corridorMeters
        diagnostics.corridorWidened = local.searchMeta.corridorWidened
        diagnostics.maxCrossTrackMeters = local.searchMeta.maxCrossTrackMeters
        diagnostics.searchOutcome = local.searchMeta.pass2Outcome
        diagnostics.effectiveProfile = req.profile.rawValue
        response.debug = RouteResponseDebug(
            routingRevision: packs.lastManifestVersion,
            graphMode: "on-device",
            searchMeta: RouteResponseSearchMeta(
                pass2Outcome: local.searchMeta.pass2Outcome,
                pops: local.searchMeta.pops,
                timedOut: local.searchMeta.timedOut,
                rideObjective: local.searchMeta.rideObjective,
                corridorMeters: local.searchMeta.corridorMeters,
                maxCrossTrackMeters: local.searchMeta.maxCrossTrackMeters,
                corridorWidened: local.searchMeta.corridorWidened,
                shortestMeters: local.searchMeta.shortestMeters,
                extraUsedMeters: local.searchMeta.extraUsedMeters,
                extraBudgetMeters: local.searchMeta.extraBudgetMeters,
                urbanCoreFallbackUsed: local.searchMeta.urbanCoreFallbackUsed,
                cleanUnpavedFallbackUsed: local.searchMeta.cleanUnpavedFallbackUsed,
                settlementFallbackUsed: local.searchMeta.settlementFallbackUsed,
                corridorCandidates: nil
            ),
            fallback: nil,
            packIdentity: identities,
            diagnostics: diagnostics,
            failureReason: nil,
            searchMs: local.searchMeta.elapsedMs,
            pops: local.searchMeta.pops
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
        RoutingDebugLog.shared.event(
            "on-device result profile=\(req.profile.rawValue) "
                + "ms=\(local.searchMeta.elapsedMs) pops=\(local.searchMeta.pops) "
                + "meters=\(Int(local.distanceMeters)) dirt=\(local.reportedDirtPercent) "
                + "objective=\(local.searchMeta.rideObjective ?? "-")"
        )
        return response
    }

    /// Offline equivalent of the existing forward fuel-chain path: the pack's
    /// own reachability search proves each pump before it is committed.
    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        guard req.locations.count == 2 else { throw RoutingError.invalidEndpoints }
        let start = coordinate(req.locations[0])
        let end = coordinate(req.locations[1])
        let budgetDeadline = req.fuel.windowTimeBudgetMs.map {
            Date().addingTimeInterval(max(0.001, Double($0) / 1_000))
        }
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
        let crossesRegion = GraphPackStore.endpointsCrossProvince([
            start.locationCoordinate, end.locationCoordinate
        ])
        if req.fuel.probeFirstReachableStation == true {
            let reachable = await packs.reachableFuelMeters(
                from: start.locationCoordinate,
                toward: end.locationCoordinate,
                pumps: stations,
                maxMeters: req.fuel.usableRangeMeters,
                profile: req.profile,
                allowUnknown: req.accessPolicy.motorizedUnknown,
                deadline: budgetDeadline
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
        // First response path for the phone. A full target-aware flood is the
        // right qualification tool, but it can spend several seconds proving
        // stations that will never be selected. For one-stop windows across
        // every profile we use a small geographic cohort and prove the next
        // legal pump hop before returning. Partial windows deliberately stop
        // there; the next itinerary window starts at that pump. Non-partial
        // callers may still request the complete continuation proof below.
        // A route can need a pump even when the caller did not explicitly
        // mark the window as mandatory.  The itinerary builder intentionally
        // leaves that flag clear while it is deciding whether the destination
        // can be carried.  Once the cheap geographic lower bound already
        // exceeds the usable first-leg range, carrying to the destination is
        // impossible, so go straight to the bounded next-pump search instead
        // of spending the full reachability budget proving the same fact.
        let lowerBoundRequiresPump = req.fuel.profileMeters.isFinite
            && req.fuel.profileMeters
                > req.fuel.firstLegMaxMeters * HopSearchPolicy.fuelAirLowerBoundFraction + 1
        let shouldPlanNextPump = req.fuel.requireFuelStopBeforeEnd || lowerBoundRequiresPump
        if req.fuel.minimumFuelStops <= 1,
           shouldPlanNextPump,
           req.fuel.requiredFirstStationId == nil {
            if lowerBoundRequiresPump && !req.fuel.requireFuelStopBeforeEnd {
                RoutingDebugLog.shared.event(
                    "fuel fast-path trigger reason=range-lower-bound "
                        + "profileMeters=\(Int(req.fuel.profileMeters)) "
                        + "firstLegMaxMeters=\(Int(req.fuel.firstLegMaxMeters))"
                )
            }
            // A chained seam has activation and stitch overhead in addition
            // to the local graph search. Give cross-region fuel qualification
            // a shorter hard budget so a rejected window still returns inside
            // the rider-facing two-second contract; same-region routes keep
            // the wider direct-route budget.
            let fastCutoff = Date().addingTimeInterval(crossesRegion ? 1.45 : 1.8)
            let fastDeadline = budgetDeadline.map { min($0, fastCutoff) } ?? fastCutoff
            let firstCap = req.fuel.firstLegMaxMeters
            let destinationCap = req.fuel.destinationFuelUsedLimitMeters
                ?? req.fuel.usableRangeMeters
            let seed = req.options?.sessionSeed
                ?? UInt64.random(in: 1...9_007_199_254_740_991)
            let targets = FuelItinerary.boundedOnDeviceFuelTargets(
                fuels: stations,
                from: start,
                to: end,
                maxMeters: firstCap,
                // Keep discovery bounded on the phone. The route proof still
                // tries only three candidates; widening this cohort consumes
                // the same deadline before any route search can begin.
                limit: 16
            )
            let approximateReachability = Dictionary(uniqueKeysWithValues: targets.map { station in
                let point = RouteCoordinate(longitude: station.longitude, latitude: station.latitude)
                return (station.id, GeoMath.meters(start, point))
            })
            let ranked = FuelItinerary.rankedProgressFuel(
                fuels: targets,
                from: start,
                to: end,
                reachableMeters: approximateReachability,
                tankMeters: firstCap,
                usableRangeMeters: req.fuel.usableRangeMeters,
                sessionSeed: seed,
                excluding: Set(req.fuel.excludedStationIds ?? [])
            )
            RoutingDebugLog.shared.event(
                "fuel fast cohort stations=\(stations.count) targets=\(targets.count) "
                    + "ranked=\(ranked.count) partial=\(req.fuel.allowPartialWindow == true ? 1 : 0) "
                    + "deadlineMs=\(max(0, Int(fastDeadline.timeIntervalSinceNow * 1_000)))"
            )
            let rankedOrder = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1.id, $0) })
            // A partial window only needs the next legal pump. Keep that
            // decision local: prefer a forward station in the departure pack
            // and the smallest useful air-distance, then let the next window
            // repeat the same decision from the new pump. The final waypoint
            // remains a direction/corridor filter in rankedProgressFuel; it
            // is no longer a requirement for proving this first hop.
            let departureRegion = GraphPackStore.primaryRegionId(
                containing: start.locationCoordinate
            )
            let partialRanked = ranked.sorted {
                let aSameRegion = departureRegion != nil
                    && GraphPackStore.primaryRegionId(
                        containing: CLLocationCoordinate2D(
                            latitude: $0.latitude, longitude: $0.longitude
                        )
                    ) == departureRegion
                let bSameRegion = departureRegion != nil
                    && GraphPackStore.primaryRegionId(
                        containing: CLLocationCoordinate2D(
                            latitude: $1.latitude, longitude: $1.longitude
                        )
                    ) == departureRegion
                if aSameRegion != bSameRegion { return aSameRegion }
                let aProgress = GeoMath.progressAlongAB(
                    from: start, to: end,
                    point: RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude)
                )
                let bProgress = GeoMath.progressAlongAB(
                    from: start, to: end,
                    point: RouteCoordinate(longitude: $1.longitude, latitude: $1.latitude)
                )
                let aAir = approximateReachability[$0.id] ?? .greatestFiniteMagnitude
                let bAir = approximateReachability[$1.id] ?? .greatestFiniteMagnitude
                // Take the next forward pump, rather than trying to jump to
                // the tank edge. The short hop is both the rider's stated
                // contract and the cheapest proof on a phone. `ranked` has
                // already filtered out behind-the-rider and destination-edge
                // candidates; air distance is therefore a safe lower-bound
                // ordering, with progress breaking near-ties.
                if abs(aAir - bAir) > 1_000 { return aAir < bAir }
                if abs(aProgress - bProgress) > 2_000 { return aProgress < bProgress }
                return (rankedOrder[$0.id] ?? ranked.count) < (rankedOrder[$1.id] ?? ranked.count)
            }
            let fastRanked: [POIFeature]
            if req.fuel.allowPartialWindow == true {
                // The bounded one-pump contract does not need urban-box
                // scoring: it chooses the nearest forward pump in the
                // departure pack and proves the road leg. Avoid loading and
                // sorting avoidance geometry on every phone fuel window.
                let comfort = partialRanked.filter {
                    (approximateReachability[$0.id] ?? firstCap) <= firstCap * 0.80
                }
                let comfortIDs = Set(comfort.map(\.id))
                fastRanked = comfort.isEmpty
                    ? partialRanked
                    : comfort + partialRanked.filter { !comfortIDs.contains($0.id) }
            } else {
                let fastAvoidanceBoxes = await packs.fuelAvoidanceBoxes(
                    from: start.locationCoordinate,
                    toward: end.locationCoordinate
                )
                let urbanRanked = ranked.sorted {
                    let aUrban = FuelItinerary.fuelStopRequiresUrbanEntry(
                        $0, start: start, destination: end, boxes: fastAvoidanceBoxes
                    )
                    let bUrban = FuelItinerary.fuelStopRequiresUrbanEntry(
                        $1, start: start, destination: end, boxes: fastAvoidanceBoxes
                    )
                    if aUrban != bUrban { return !aUrban }
                    return (rankedOrder[$0.id] ?? ranked.count) < (rankedOrder[$1.id] ?? ranked.count)
                }
                // The geographic reachability above is an air-distance lower
                // bound. A pump at the absolute tank edge leaves no room for
                // a Dirt detour, so try the conservative 80% band first and
                // retain the edge-band candidates as a correctness-preserving
                // fallback.
                let conservative = urbanRanked.filter {
                    guard let air = approximateReachability[$0.id] else { return false }
                    return air <= firstCap * 0.80
                }
                let conservativeIDs = Set(conservative.map(\.id))
                // Within the conservative band, prefer a mid-range pump. This
                // gives the continuation real fuel margin on Dirt detours
                // instead of selecting an early town pump or the absolute
                // tank edge.
                let targetAir = firstCap * 0.72
                func fastRangeScore(_ station: POIFeature) -> Double {
                    guard let air = approximateReachability[station.id] else { return .greatestFiniteMagnitude }
                    return abs(air - targetAir)
                }
                let orderedConservative = conservative.sorted {
                    let aScore = fastRangeScore($0)
                    let bScore = fastRangeScore($1)
                    if abs(aScore - bScore) > 1_000 { return aScore < bScore }
                    return (rankedOrder[$0.id] ?? ranked.count) < (rankedOrder[$1.id] ?? ranked.count)
                }
                fastRanked = orderedConservative + urbanRanked.filter { !conservativeIDs.contains($0.id) }
            }
            RoutingDebugLog.shared.event(
                "fuel fast ranked-ready count=\(fastRanked.count) "
                    + "deadlineMs=\(max(0, Int(fastDeadline.timeIntervalSinceNow * 1_000)))"
            )
            // Fuel POIs are commonly mapped at a forecourt or driveway rather
            // than on the graph edge itself. The normal rider-pin snap limit
            // is intentionally tight; a pump approach may use the V4 tap
            // radius so a legal nearby station is not rejected as
            // `cannotSnapEnd` before the next candidate can be tried.
            let fuelStationMatchLimit = min(
                TapRadius.v4CapMeters,
                max(
                    TapRadius.minMeters,
                    req.options?.matchLimitMeters ?? OnDeviceRouter.preferredMatchMeters,
                    2_000
                )
            )
            for candidate in fastRanked.prefix(3) {
                guard Date() < fastDeadline else { break }
                let candidateCoordinate = CLLocationCoordinate2D(
                    latitude: candidate.latitude,
                    longitude: candidate.longitude
                )
                // Do not give a nearby next pump the entire destination
                // window. A candidate-specific cap keeps the local proof
                // focused on reaching this station while allowing a generous
                // detour margin for Dirt and preserving the rider's hard
                // range ceiling.
                let candidateAirMeters = approximateReachability[candidate.id] ?? firstCap
                let candidateRouteCap = min(
                    firstCap,
                    max(candidateAirMeters * 3, candidateAirMeters + 20_000)
                )
                let candidateBegan = ProcessInfo.processInfo.systemUptime
                var firstResult = await packs.routeOnDeviceDetailed(
                    from: start.locationCoordinate,
                    to: candidateCoordinate,
                    profile: req.profile,
                    allowUnknown: req.accessPolicy.motorizedUnknown,
                    avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
                    priorEdgeIds: Set(req.options?.priorEdgeIds ?? []),
                    arrivalEdgeId: req.options?.arrivalEdgeId,
                    backtrackFactor: req.options?.backtrackFactor ?? 4,
                    sessionSeed: seed,
                    maxRouteMeters: candidateRouteCap,
                    regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
                    cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
                    avoidMotorways: req.options?.avoidMotorways == true,
                    preferBackRoads: req.options?.preferBackRoads == true,
                    matchLimitMeters: fuelStationMatchLimit,
                    fastSearch: true,
                    deadline: fastDeadline
                )
                // A pump is a safety waypoint, so the approach may use a
                // practical paved connector when a strict Dirt search cannot
                // legally reach the mapped forecourt. Keep the rider's profile
                // for the corridor and continuation; relax only this bounded
                // station approach, and only while the fast deadline remains.
                if case .failure = firstResult,
                   req.profile == .dirt,
                   Date() < fastDeadline {
                    let relaxed = await packs.routeOnDeviceDetailed(
                        from: start.locationCoordinate,
                        to: candidateCoordinate,
                        profile: .balanced,
                        allowUnknown: req.accessPolicy.motorizedUnknown,
                        avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
                        priorEdgeIds: Set(req.options?.priorEdgeIds ?? []),
                        arrivalEdgeId: req.options?.arrivalEdgeId,
                        backtrackFactor: req.options?.backtrackFactor ?? 4,
                        sessionSeed: seed,
                        maxRouteMeters: candidateRouteCap,
                        regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
                        cleanMetroMultiplier: nil,
                        avoidMotorways: false,
                        preferBackRoads: false,
                        matchLimitMeters: fuelStationMatchLimit,
                        fastSearch: true,
                        deadline: fastDeadline
                    )
                    if case .success = relaxed {
                        RoutingDebugLog.shared.event(
                            "fuel fast candidate=\(candidate.id) relaxed-profile=balanced"
                        )
                        firstResult = relaxed
                    }
                }
                switch firstResult {
                case .success(let firstRoute):
                    let endpointGap = Int(GeoMath.meters(
                        firstRoute.coordinates.last ?? start.locationCoordinate,
                        candidateCoordinate
                    ))
                    RoutingDebugLog.shared.event(
                        "fuel fast candidate=\(candidate.id) first=success meters=\(Int(firstRoute.distanceMeters)) "
                            + "airMeters=\(Int(approximateReachability[candidate.id] ?? -1)) "
                            + "region=\(GraphPackStore.primaryRegionId(containing: candidateCoordinate) ?? "-") "
                            + "endpointGap=\(endpointGap) "
                            + "searchMs=\(firstRoute.searchMeta.elapsedMs) pops=\(firstRoute.searchMeta.pops) timedOut=\(firstRoute.searchMeta.timedOut ? 1 : 0) "
                            + "backtrackMeters=\(Int(firstRoute.backtrackMeters)) dirtPct=\(firstRoute.reportedDirtPercent) points=\(firstRoute.coordinates.count) "
                            + "elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - candidateBegan) * 1000))"
                    )
                case .failure(let failure):
                    RoutingDebugLog.shared.event(
                        "fuel fast candidate=\(candidate.id) first=failure \(failure) "
                            + "airMeters=\(Int(approximateReachability[candidate.id] ?? -1)) "
                            + "region=\(GraphPackStore.primaryRegionId(containing: candidateCoordinate) ?? "-") "
                            + "elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - candidateBegan) * 1000))"
                    )
                }
                guard case .success(let firstRoute) = firstResult,
                      firstRoute.distanceMeters <= firstCap + 1,
                      (req.fuel.allowPartialWindow == true || Date() < fastDeadline)
                else { continue }
                guard let firstEndpoint = firstRoute.coordinates.last,
                      GeoMath.meters(firstEndpoint, candidateCoordinate)
                          <= HopSearchPolicy.fuelWaypointSnapMeters
                else {
                    // A mapped pump beyond the authored station snap radius is
                    // not a proven fuel approach. Keep looking rather than
                    // turning a long straight-line connector into a route leg.
                    continue
                }
                let stop = FuelChainStop(
                    id: candidate.id,
                    latitude: candidate.latitude,
                    longitude: candidate.longitude,
                    name: candidate.name,
                    brand: candidate.brand,
                    address: candidate.address,
                    graphMeters: firstRoute.distanceMeters
                )
                let firstResponse = RouteResponse(
                    onDevice: firstRoute,
                    priorEdgeIDs: Set(req.options?.priorEdgeIds ?? [])
                ).appendingFuelStopEndpoint(to: stop.coordinate)
                let firstMeters = firstResponse.distanceMeters ?? firstRoute.distanceMeters
                if req.fuel.allowPartialWindow == true {
                    RoutingDebugLog.shared.event(
                        "fuel fast candidate=\(candidate.id) partial-pump committed "
                            + "meters=\(Int(firstMeters)) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - candidateBegan) * 1000))"
                    )
                    let candidateReport = FuelStationCandidate(
                        id: candidate.id,
                        meters: firstMeters,
                        dirtPct: firstRoute.reportedDirtPercent,
                        departureId: "start",
                        latitude: candidate.latitude,
                        longitude: candidate.longitude,
                        name: candidate.displayName,
                        validForward: true,
                        remainingGraphMeters: nil,
                        canFinish: false,
                        rank: 1,
                        candidateSource: "fast-geographic-partial"
                    )
                    return FuelChainResponse(
                        status: "complete",
                        error: nil,
                        message: "Fuel window ends at the proven station; the next window will continue from there.",
                        regionIds: GraphPackStore.regionIds(containingAny: [
                            start.locationCoordinate, end.locationCoordinate
                        ]),
                        stops: [stop],
                        graphMeters: [firstMeters],
                        diagnostics: FuelChainDiagnostics(
                            strategy: "pack-fast-proven-pump",
                            states: 1,
                            dijkstraPops: nil,
                            matchedFuel: stations.count,
                            elapsedMs: nil,
                            candidateK: 1,
                            stationsReachableWithinRange: nil,
                            candidatesEvaluated: 1
                        ),
                        routes: [firstResponse],
                        stationCandidates: [candidateReport],
                        windowComplete: false
                    )
                }
                let continuationResult = await packs.routeOnDeviceDetailed(
                    from: candidateCoordinate,
                    to: end.locationCoordinate,
                    profile: req.profile,
                    allowUnknown: req.accessPolicy.motorizedUnknown,
                    avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
                    priorEdgeIds: Set((req.options?.priorEdgeIds ?? []) + firstRoute.edgeIds),
                    arrivalEdgeId: firstRoute.edgeIds.last ?? req.options?.arrivalEdgeId,
                    backtrackFactor: req.options?.backtrackFactor ?? 4,
                    sessionSeed: seed,
                    maxRouteMeters: destinationCap,
                    regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
                    cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
                    avoidMotorways: req.options?.avoidMotorways == true,
                    preferBackRoads: req.options?.preferBackRoads == true,
                    matchLimitMeters: req.options?.matchLimitMeters ?? OnDeviceRouter.preferredMatchMeters,
                    fastSearch: true,
                    deadline: fastDeadline
                )
                switch continuationResult {
                case .success(let continuation):
                    RoutingDebugLog.shared.event(
                        "fuel fast candidate=\(candidate.id) continuation=success meters=\(Int(continuation.distanceMeters)) "
                            + "elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - candidateBegan) * 1000))"
                    )
                case .failure(let failure):
                    RoutingDebugLog.shared.event(
                        "fuel fast candidate=\(candidate.id) continuation=failure \(failure) "
                            + "elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - candidateBegan) * 1000))"
                    )
                }
                if case .success(let continuation) = continuationResult,
                   continuation.distanceMeters <= destinationCap + 1,
                   Date() < fastDeadline {
                    let candidateReport = FuelStationCandidate(
                        id: candidate.id,
                        meters: firstMeters,
                        dirtPct: firstRoute.reportedDirtPercent,
                        departureId: "start",
                        latitude: candidate.latitude,
                        longitude: candidate.longitude,
                        name: candidate.displayName,
                        validForward: true,
                        remainingGraphMeters: continuation.distanceMeters,
                        canFinish: true,
                        rank: 1,
                        candidateSource: "fast-geographic-cohort"
                    )
                    return FuelChainResponse(
                        status: "complete",
                        error: nil,
                        message: nil,
                        regionIds: GraphPackStore.regionIds(containingAny: [
                            start.locationCoordinate, end.locationCoordinate
                        ]),
                        stops: [stop],
                        graphMeters: [firstMeters, continuation.distanceMeters],
                        diagnostics: FuelChainDiagnostics(
                            strategy: "pack-fast-proven-continuation",
                            states: 2,
                            dijkstraPops: nil,
                            matchedFuel: stations.count,
                            elapsedMs: nil,
                            candidateK: 1,
                            stationsReachableWithinRange: nil,
                            candidatesEvaluated: 1
                        ),
                        routes: [
                            firstResponse,
                            RouteResponse(onDevice: continuation, priorEdgeIDs: Set(firstRoute.edgeIds))
                        ],
                        stationCandidates: [candidateReport],
                        windowComplete: true
                    )
                }
            }
            if req.fuel.allowPartialWindow == true {
                RoutingDebugLog.shared.event(
                    "fuel fast gap no-proven-pump stations=\(stations.count) "
                        + "targets=\(targets.count) ranked=\(fastRanked.count)"
                )
                return FuelChainResponse(
                    status: "gap",
                    error: "no_proven_forward_fuel_pump",
                    message: "No forward fuel stop could be proven within the usable range.",
                    regionIds: GraphPackStore.regionIds(containingAny: [
                        start.locationCoordinate, end.locationCoordinate
                    ]),
                    stops: [],
                    graphMeters: [],
                    diagnostics: FuelChainDiagnostics(
                        strategy: "pack-fast-pump-gap",
                        states: 0,
                        dijkstraPops: nil,
                        matchedFuel: stations.count,
                        elapsedMs: nil,
                        candidateK: fastRanked.count,
                        stationsReachableWithinRange: nil,
                        candidatesEvaluated: min(3, fastRanked.count)
                    ),
                    stationCandidates: []
                )
            }
            return FuelChainResponse(
                status: "unknown",
                error: "fuel_fast_path_no_qualified_route",
                message: "No legal next fuel station could be reached within the on-device response budget.",
                regionIds: GraphPackStore.regionIds(containingAny: [
                    start.locationCoordinate, end.locationCoordinate
                ]),
                stops: [], graphMeters: [],
                diagnostics: FuelChainDiagnostics(
                    strategy: "pack-fast-budget",
                    states: 1,
                    dijkstraPops: nil,
                    matchedFuel: stations.count,
                    elapsedMs: nil
                ),
                windowComplete: false
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
        let sessionSeed = req.options?.sessionSeed
            ?? UInt64.random(in: 1...9_007_199_254_740_991)
        let probeLogging = req.fuel.riderLegId == "private-device-hybrid-probe"

        func logProbePhase(_ phase: String) {
            if probeLogging { print("[HybridProbePhase] profile=\(req.profile.rawValue) phase=\(phase)") }
        }

        func budgetExpired() -> Bool {
            guard let budgetDeadline else { return false }
            return Date() >= budgetDeadline
        }

        func budgetResponse(_ reason: String) -> FuelChainResponse {
            FuelChainResponse(
                status: "unknown",
                error: "fuel_window_budget_exceeded",
                message: "On-device fuel planning exceeded its bounded window budget.",
                regionIds: GraphPackStore.regionIds(containingAny: [
                    start.locationCoordinate, end.locationCoordinate
                ]),
                stops: Array(stops.prefix(returnedStopLimit)),
                graphMeters: Array(graphMeters.prefix(returnedStopLimit)),
                diagnostics: FuelChainDiagnostics(
                    strategy: "pack-forward-budget-\(reason)",
                    states: stops.count + 1,
                    dijkstraPops: nil,
                    matchedFuel: stations.count,
                    elapsedMs: nil
                ),
                stationCandidates: stationCandidates,
                windowComplete: false
            )
        }

        while stops.count <= maximumStops {
            try Task.checkCancellation()
            if budgetExpired() { return budgetResponse("before-search") }
            let firstCap = stops.isEmpty
                ? req.fuel.firstLegMaxMeters
                : req.fuel.usableRangeMeters
            let direct: Double?
            if crossesRegion {
                // A single active pack cannot prove a direct A→B hop when the
                // endpoints belong to different provinces. Skipping this
                // bounded search avoids traversing the entire departure pack
                // only to discover that the destination has no local snap.
                logProbePhase("shortest-skip-cross-region")
                direct = nil
            } else {
                logProbePhase("shortest-begin")
                direct = await packs.shortestGraphMeters(
                    from: current.locationCoordinate,
                    to: end.locationCoordinate,
                    maxMeters: firstCap,
                    profile: req.profile,
                    allowUnknown: req.accessPolicy.motorizedUnknown,
                    deadline: budgetDeadline
                )
                logProbePhase("shortest-end")
            }
            if budgetExpired() { return budgetResponse("after-reachability") }
            let mustPump = stops.count < req.fuel.minimumFuelStops
                || (stops.isEmpty && req.fuel.requireFuelStopBeforeEnd)
            let destinationLimit = req.fuel.destinationFuelUsedLimitMeters
            var directFallback: Double?
            // A direct route cannot satisfy this iteration while a mandatory
            // pump is outstanding. Skipping it prevents a full profile search
            // from consuming the same deadline needed to prove the pump leg.
            if !mustPump, let direct,
               destinationLimit == nil || direct <= (destinationLimit ?? .infinity) + 1 {
                logProbePhase("direct-begin")
                let routed = await packs.routeOnDeviceDetailed(
                    from: current.locationCoordinate,
                    to: end.locationCoordinate,
                    profile: req.profile,
                    allowUnknown: req.accessPolicy.motorizedUnknown,
                    avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
                    priorEdgeIds: carriedHistory,
                    arrivalEdgeId: carriedArrival,
                    backtrackFactor: req.options?.backtrackFactor ?? 4,
                    sessionSeed: sessionSeed,
                    maxRouteMeters: firstCap,
                    regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
                    cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
                    avoidMotorways: req.options?.avoidMotorways == true,
                    preferBackRoads: req.options?.preferBackRoads == true,
                    deadline: budgetDeadline
                )
                logProbePhase("direct-end")
                if budgetExpired() { return budgetResponse("after-direct-route") }
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

            logProbePhase("reachable-begin")
            let reachabilityTargets = FuelItinerary.boundedOnDeviceFuelTargets(
                fuels: stations,
                from: current,
                to: end,
                maxMeters: firstCap
            )
            let reachable = await packs.reachableFuelMeters(
                from: current.locationCoordinate,
                toward: end.locationCoordinate,
                pumps: reachabilityTargets,
                maxMeters: firstCap,
                profile: req.profile,
                allowUnknown: req.accessPolicy.motorizedUnknown,
                deadline: budgetDeadline
            )
            logProbePhase("reachable-end")
            logProbePhase("avoidance-begin")
            let fuelAvoidanceBoxes = await packs.fuelAvoidanceBoxes(
                from: current.locationCoordinate,
                toward: end.locationCoordinate
            )
            logProbePhase("avoidance-end")
            if budgetExpired() { return budgetResponse("after-avoidance") }
            let ranked = FuelItinerary.rankedProgressFuel(
                fuels: stations,
                from: current,
                to: end,
                reachableMeters: reachable,
                tankMeters: firstCap,
                usableRangeMeters: req.fuel.usableRangeMeters,
                sessionSeed: sessionSeed,
                excluding: visited
            )
            let departureID = stops.last?.id ?? "start"
            var evaluated: [FuelItinerary.ProfileFuelCandidate] = []
            var evaluatedRoutesByID: [String: OnDeviceRouter.Result] = [:]
            var continuationRoutesByID: [String: OnDeviceRouter.Result] = [:]
            // Match live: route-score every geographically bounded candidate.
            // Reachability keeps the rider safe; profile quality decides which
            // safe pump is worth riding to.
            let candidateLimit = req.fuel.windowTimeBudgetMs == nil ? 6 : 3
            for (rank, candidate) in ranked.prefix(candidateLimit).enumerated() {
                if budgetExpired() { return budgetResponse("before-candidate-\(rank)") }
                logProbePhase("candidate-\(rank)-begin")
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
                    sessionSeed: sessionSeed,
                    maxRouteMeters: firstCap,
                    regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
                    cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
                    avoidMotorways: req.options?.avoidMotorways == true,
                    preferBackRoads: req.options?.preferBackRoads == true,
                    deadline: budgetDeadline
                )
                logProbePhase("candidate-\(rank)-end")
                if budgetExpired() { return budgetResponse("after-candidate-\(rank)") }
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
                logProbePhase("continuation-\(rank)-begin")
                let continuationResult = await packs.routeOnDeviceDetailed(
                    from: candidateCoordinate,
                    to: end.locationCoordinate,
                    profile: req.profile,
                    allowUnknown: req.accessPolicy.motorizedUnknown,
                    avoidEdgeIds: req.options?.avoidEdgeIds ?? [],
                    priorEdgeIds: carriedHistory.union(firstRoute.edgeIds),
                    arrivalEdgeId: firstRoute.edgeIds.last ?? carriedArrival,
                    backtrackFactor: req.options?.backtrackFactor ?? 4,
                    sessionSeed: sessionSeed,
                    maxRouteMeters: destinationCap,
                    regionalHopMinimumMeters: req.options?.regionalHopMinimumMeters ?? [],
                    cleanMetroMultiplier: req.options?.cleanMetroMultiplier,
                    avoidMotorways: req.options?.avoidMotorways == true,
                    preferBackRoads: req.options?.preferBackRoads == true,
                    deadline: budgetDeadline
                )
                logProbePhase("continuation-\(rank)-end")
                if budgetExpired() { return budgetResponse("after-continuation-\(rank)") }
                let continuationRoute: OnDeviceRouter.Result?
                if case .success(let route) = continuationResult,
                   route.distanceMeters <= destinationCap + 1 {
                    continuationRoute = route
                    continuationRoutesByID[candidate.id] = route
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
                        pumps: FuelItinerary.boundedOnDeviceFuelTargets(
                            fuels: stations,
                            from: RouteCoordinate(
                                longitude: candidate.longitude,
                                latitude: candidate.latitude
                            ),
                            to: end,
                            maxMeters: req.fuel.usableRangeMeters
                        ),
                        maxMeters: req.fuel.usableRangeMeters,
                        profile: req.profile,
                        allowUnknown: req.accessPolicy.motorizedUnknown,
                        deadline: budgetDeadline
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
                    sessionSeed: sessionSeed,
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

                // On a bounded on-device window, the first candidate with a
                // proven continuation already satisfies the fuel safety gate.
                // Stop scoring more pumps before they consume the deadline;
                // the deterministic ranked order remains the profile tie-break.
                if req.fuel.windowTimeBudgetMs != nil,
                   continuationRoute != nil,
                   validForward,
                   stops.count + 1 >= req.fuel.minimumFuelStops {
                    break
                }
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

            // The candidate evaluation already proved this pump→destination
            // continuation under the same history and fuel cap. Reuse that
            // proof instead of starting a second search on the next loop.
            // This is valid only once the required minimum pump count is met.
            if req.fuel.windowTimeBudgetMs != nil,
               stops.count >= req.fuel.minimumFuelStops,
               choice.validForward,
               let continuation = continuationRoutesByID[station.id] {
                let first = evaluatedRoutesByID[station.id]
                let plannedRoutes: [RouteResponse]? = first.map {
                    [
                        RouteResponse(
                            onDevice: $0,
                            priorEdgeIDs: Set(req.options?.priorEdgeIds ?? [])
                        ),
                        RouteResponse(
                            onDevice: continuation,
                            priorEdgeIDs: Set(req.options?.priorEdgeIds ?? []).union($0.edgeIds)
                        )
                    ]
                }
                return FuelChainResponse(
                    status: "complete", error: nil, message: nil,
                    regionIds: GraphPackStore.regionIds(containingAny: [
                        start.locationCoordinate, end.locationCoordinate
                    ]),
                    stops: Array(stops.prefix(returnedStopLimit)),
                    graphMeters: Array((graphMeters + [continuation.distanceMeters]).prefix(returnedStopLimit + 1)),
                    diagnostics: FuelChainDiagnostics(
                        strategy: "pack-forward-proven-continuation", states: stops.count + 1,
                        dijkstraPops: nil, matchedFuel: stations.count, elapsedMs: nil
                    ),
                    routes: plannedRoutes,
                    stationCandidates: stationCandidates,
                    windowComplete: true
                )
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

    func packDownloadBytes(forRegionId regionID: String) -> Int64? {
        let id = regionID.lowercased()
        guard let row = regions.first(where: { $0.id == id }) else { return nil }
        return row.exactBytes ?? row.approxBytes
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
        preferInstalledPacks: Bool = true,
        onDeviceOnly: Bool = false
    ) {
        self.init(
            isOnline: { network.isOnline },
            installedPacks: packs,
            live: live,
            pack: pack,
            preferInstalledPacks: preferInstalledPacks,
            onDeviceOnly: onDeviceOnly
        )
    }

    init(
        isOnline: @escaping () -> Bool,
        installedPacks: any RoutingInstalledPackRegistry,
        live: any RoutingSource,
        pack: any RoutingSource,
        preferInstalledPacks: Bool = false,
        onDeviceOnly: Bool = false,
        report: @escaping @MainActor (String) -> Void = { RoutingDebugLog.shared.event($0) }
    ) {
        let useInstalled = preferInstalledPacks
        selector = { request in
            let locations = request.locations.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            let needed = GraphPackStore.regionIds(containingAny: locations)
            let provinces = GraphPackStore.endpointProvinceIds(containingAny: locations)
            let installed = needed.filter { installedPacks.isRoutingPackInstalled($0) }
            let packsCover = installedPacksCover(locations, registry: installedPacks)
            let singleRegion = provinces.count <= 1
            let chosen: any RoutingSource
            if useInstalled && (packsCover || onDeviceOnly) {
                chosen = pack
            } else {
                chosen = isOnline() ? live : pack
            }
            let selectedPath = chosen.name == pack.name
                ? needed.first.flatMap { installedPacks.installedRoutingGraphPath(regionID: $0) }
                : nil
            let selectionReason: String
            if onDeviceOnly {
                selectionReason = "on-device-required-pack"
            } else if packsCover && useInstalled {
                selectionReason = "installed-packs"
            } else {
                selectionReason = "online-or-fallback"
            }
            report(
                "policy packsCover=\(packsCover) singleRegion=\(singleRegion) " +
                    "provinces=[\(provinces.joined(separator: ","))] " +
                    "installed=[\(installed.joined(separator: ","))] " +
                    "selectedPath=\(selectedPath ?? "nil") " +
                    "manifest=\(installedPacks.routingManifestVersion) online=\(isOnline()) " +
                    "selected=\(chosen.name) " +
                    "selectionReason=\(selectionReason)"
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
        preferBackRoads: request.options?.preferBackRoads == true
    )
}

private func normalizedEdgeIDs(_ ids: [String]?) -> [String] {
    Array(Set(ids ?? [])).sorted()
}

private extension RouteResponse {
    /// Pack station coordinates often sit a few metres inside a forecourt,
    /// beyond the legal road projection. Keep the returned window geometrically
    /// continuous by explicitly carrying that short approach into the stop.
    /// The connector is labelled as a soft stitch so diagnostics can continue
    /// to report the approach as unverified until a customer-access edge is
    /// authored in the pack.
    func appendingFuelStopEndpoint(to endpoint: RouteCoordinate) -> RouteResponse {
        guard let geometry, let last = geometry.last else { return self }
        let gap = CLLocation(latitude: last.latitude, longitude: last.longitude)
            .distance(from: CLLocation(latitude: endpoint.latitude, longitude: endpoint.longitude))
        guard gap > 1 else { return self }
        let approach = RouteSegment(
            surfaceClass: "access",
            trackClass: "connector",
            accessClass: "motorized_permissive",
            distanceMeters: gap,
            geometry: [last, endpoint],
            coords: nil,
            edgeId: "soft-stitch-fuel",
            structureType: nil,
            structureLeaf: nil,
            layer: 0,
            crossingLabel: nil,
            waterCrossing: false,
            surfaceLeaf: "unpaved"
        )
        var joinedGeometry = geometry
        joinedGeometry.append(endpoint)
        var joinedSegments = segments ?? []
        joinedSegments.append(approach)
        return RouteResponse(
            status: status,
            error: error,
            message: message,
            distanceMeters: (distanceMeters ?? 0) + gap,
            estimatedMovingSeconds: estimatedMovingSeconds,
            estimatedElapsedSeconds: estimatedElapsedSeconds,
            geometry: joinedGeometry,
            segments: joinedSegments,
            stats: stats,
            maneuvers: maneuvers,
            warnings: warnings,
            dirtPercentValue: dirtPercentValue,
            pavedPercentValue: pavedPercentValue,
            backtrackMeters: backtrackMeters,
            backtrackPct: backtrackPct,
            backtrackReason: backtrackReason,
            restrictedMeters: restrictedMeters,
            restrictedReason: restrictedReason,
            debug: debug,
            serviceContract: serviceContract,
            serviceBuild: serviceBuild
        )
    }

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
