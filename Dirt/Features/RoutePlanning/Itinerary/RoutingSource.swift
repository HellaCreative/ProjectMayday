import CoreLocation
import Foundation

@MainActor
protocol RoutingSource: AnyObject {
    var name: String { get }
    func route(_ req: RouteRequest) async throws -> RouteResponse
    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse
    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop?
}

@MainActor
final class RouteResponseCache {
    struct Key: Hashable, CustomStringConvertible {
        let from: RouteCoordinate
        let to: RouteCoordinate
        let profile: RouteProfile
        let allowUnknown: Bool
        let priorEdgeIDs: [String]
        let arrivalEdgeID: String?
        let backtrackFactor: Double
        let sourceName: String
        let packRevision: String

        var description: String {
            "\(from.latitude),\(from.longitude)>\(to.latitude),\(to.longitude)" +
                "|\(profile.rawValue)|unknown=\(allowUnknown ? 1 : 0)" +
                "|prior=\(priorEdgeIDs.joined(separator: ","))" +
                "|arrival=\(arrivalEdgeID ?? "nil")" +
                "|backtrack=\(backtrackFactor)" +
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
    private let client: RoutingClient
    private let cache: RouteResponseCache
    private let packRevision: () -> String

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
        let response = try await client.route(req)
        if req.options?.maxPathMeters == nil { cache.insert(response, for: key) }
        return response
    }

    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        try await client.fuelChain(req)
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        try await client.fuelStation(near: point, within: meters)
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
            priorEdgeIDs: normalizedEdgeIDs(req.options?.priorEdgeIds),
            arrivalEdgeID: req.options?.arrivalEdgeId,
            backtrackFactor: req.options?.backtrackFactor ?? 4,
            sourceName: name,
            packRevision: packs.lastManifestVersion
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
            maxRouteMeters: req.options?.maxPathMeters
        )
        guard case .success(let local) = result, local.coordinates.count > 1 else {
            throw RoutingError.server("No route is available on the installed pack.")
        }
        let response = RouteResponse(
            onDevice: local,
            priorEdgeIDs: Set(req.options?.priorEdgeIds ?? [])
        )
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
        let maximumStops = min(12, max(1, req.fuel.windowMaxStops ?? 12))

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
            if let direct, !mustPump,
               destinationLimit == nil || direct <= (destinationLimit ?? .infinity) + 1 {
                graphMeters.append(direct)
                return FuelChainResponse(
                    status: "complete", error: nil, message: nil,
                    regionIds: GraphPackStore.regionIds(containingAny: [
                        start.locationCoordinate, end.locationCoordinate
                    ]),
                    stops: stops, graphMeters: graphMeters,
                    diagnostics: FuelChainDiagnostics(
                        strategy: "pack-forward", states: stops.count + 1,
                        dijkstraPops: nil, matchedFuel: stations.count, elapsedMs: nil
                    )
                )
            }

            if stops.count >= maximumStops, req.fuel.allowPartialWindow == true {
                return FuelChainResponse(
                    status: "complete", error: nil, message: nil,
                    regionIds: GraphPackStore.regionIds(containingAny: [
                        start.locationCoordinate, end.locationCoordinate
                    ]),
                    stops: stops, graphMeters: graphMeters,
                    diagnostics: FuelChainDiagnostics(
                        strategy: "pack-forward-window", states: stops.count,
                        dijkstraPops: nil, matchedFuel: stations.count, elapsedMs: nil
                    ),
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
            guard let station = FuelItinerary.rankedProgressFuel(
                fuels: stations,
                from: current,
                to: end,
                reachableMeters: reachable,
                tankMeters: firstCap,
                sessionSeed: 0,
                excluding: visited
            ).first, let meters = reachable[station.id] else {
                throw RoutingError.server("No route-connected fuel chain fits the usable range.")
            }
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
        }
        throw RoutingError.server("No route-connected fuel chain fits the usable range.")
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        let pad = max(0.002, meters / 111_000)
        let candidates = packs.fuelStations(
            minLat: point.latitude - pad,
            maxLat: point.latitude + pad,
            minLon: point.longitude - pad,
            maxLon: point.longitude + pad
        )
        return candidates.compactMap { station -> (POIFeature, Double)? in
            let distance = CLLocation(
                latitude: point.latitude, longitude: point.longitude
            ).distance(from: CLLocation(latitude: station.latitude, longitude: station.longitude))
            return distance <= meters ? (station, distance) : nil
        }.min { $0.1 < $1.1 }.map { station, _ in
            FuelChainStop(
                id: station.id, latitude: station.latitude, longitude: station.longitude,
                name: station.name, brand: station.brand, address: station.address,
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

extension GraphPackStore: RoutingInstalledPackRegistry {
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
            let installed = needed.filter { installedPacks.isRoutingPackInstalled($0) }
            let packsCover = installedPacksCover(locations, registry: installedPacks)
            let singleRegion = needed.count <= 1
            report(
                "policy packsCover=\(packsCover) singleRegion=\(singleRegion) " +
                    "installed=[\(installed.joined(separator: ","))] " +
                    "path=\(needed.first.flatMap { installedPacks.installedRoutingGraphPath(regionID: $0) } ?? "nil") " +
                    "manifest=\(installedPacks.routingManifestVersion) online=\(isOnline())"
            )
            return isOnline() ? live : pack
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
        priorEdgeIDs: normalizedEdgeIDs(request.options?.priorEdgeIds),
        arrivalEdgeID: request.options?.arrivalEdgeId,
        backtrackFactor: request.options?.backtrackFactor ?? 4,
        sourceName: sourceName, packRevision: packRevision
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
                edgeId: leg.edgeId.isEmpty ? nil : leg.edgeId
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
                dirtPercent: local.dirtPercent,
                pavedPercent: local.pavedPercent,
                unknownAccessPercent: local.unknownAccessPercent
            ),
            maneuvers: nil, warnings: nil,
            dirtPercentValue: nil, pavedPercentValue: nil,
            backtrackMeters: repeatedMeters,
            backtrackPct: repeatedPct,
            backtrackReason: repeatedMeters > 0 ? "dead_end_or_only_connector" : nil,
            restrictedMeters: 0,
            restrictedReason: nil
        )
    }
}
