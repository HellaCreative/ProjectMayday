import CoreLocation
import Foundation
import DirtRoutingEngine

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
    let supportsCombinedFuelPlanning = true
    private let packs: GraphPackStore
    private let session = NativeRoutingSession()
    init(packs: GraphPackStore,cache: RouteResponseCache) { self.packs = packs }

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        do {
            let request = try NativeRoutingAdapter.request(req)
            let directories = try packs.routingDirectories(for: req.locations.map {
                CLLocationCoordinate2D(latitude: $0.latitude,longitude: $0.longitude)
            })
            let result = try await session.route(request,directories: directories)
            try Task.checkCancellation()
            return NativeRoutingAdapter.response(result,style: request.profile.style,prior: Set(req.options?.priorEdgeIds ?? []))
        } catch let failure as RoutingFailure { throw RoutingError.server(NativeRoutingAdapter.message(failure)) }
    }
    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        guard req.locations.count == 2 else { throw RoutingError.invalidEndpoints }
        let roadRequest = RouteRequest(profile: req.profile,locations: req.locations,allowUnknown: req.accessPolicy.motorizedUnknown,
            avoidEdgeIds: req.options?.avoidEdgeIds ?? [],priorEdgeIds: req.options?.priorEdgeIds ?? [],
            arrivalEdgeId: req.options?.arrivalEdgeId,backtrackFactor: req.options?.backtrackFactor,
            sessionSeed: req.options?.sessionSeed ?? 0,maxPathMeters: req.options?.maxPathMeters,
            mapZoom: req.options?.mapZoom,matchLimitMeters: req.options?.matchLimitMeters,
            startEndpointKind: req.options?.startEndpointKind,endEndpointKind: req.options?.endEndpointKind)
        var request = try NativeRoutingAdapter.request(roadRequest)
        // Preserve the same rider policy for the road foundation and fuel hops.
        if let preferences = req.options?.ridePreferences?.normalized {
            request.profile.wander = preferences.wander
            request.profile.avoidMajorHighways = preferences.avoidHighways
            request.options.cityWall = preferences.avoidCities
        }
        var fuel = FuelRequirements(usableRangeMeters: req.fuel.usableRangeMeters,firstLegMaxMeters: req.fuel.firstLegMaxMeters)
        fuel.minimumStops = max(req.fuel.minimumFuelStops,req.fuel.requireFuelStopBeforeEnd ? 1 : 0)
        fuel.maximumStops = req.fuel.windowMaxStops
        fuel.excludedStationIDs = Set(req.fuel.excludedStationIds ?? [])
        fuel.requiredFirstStationID = req.fuel.requiredFirstStationId
        fuel.destinationUsedLimitMeters = req.fuel.destinationFuelUsedLimitMeters
        fuel.ensureDestinationEscape = req.fuel.ensureDestinationFuelEscape == true
        fuel.probeFirstStation = req.fuel.probeFirstReachableStation == true || req.fuel.forwardFeeler == true
        fuel.allowPartialResult = req.fuel.allowPartialWindow == true
        fuel.preferredStationIDs = req.fuel.preferredStationIds ?? []
        request.options.arrivalEdgeID = req.options?.arrivalEdgeId
        request.options.arrivalRestrictions = (req.options?.arrivalRestrictions ?? []).map {
            RestrictionProgress(pattern: $0.pattern, progress: $0.progress)
        }
        do {
            let directories = try packs.routingDirectories(for: req.locations.map {
                CLLocationCoordinate2D(latitude: $0.latitude,longitude: $0.longitude)
            })
            let plan = try await session.fuel(request,requirements: fuel,directories: directories,
                                             seconds: Double(req.fuel.windowTimeBudgetMs ?? 60_000)/1000)
            try Task.checkCancellation()
            let stops = plan.stops.enumerated().map { i,station in
                FuelChainStop(id: station.id,latitude: station.coordinate.latitude,longitude: station.coordinate.longitude,
                    name: station.name,brand: station.brand,address: station.address,
                    graphMeters: i < plan.routes.count ? plan.routes[i].distanceMeters : nil)
            }
            return FuelChainResponse(status: plan.complete ? "complete"
                    : (!plan.stops.isEmpty && plan.limit == nil ? "window" : "gap"),
                error: plan.complete || (!plan.stops.isEmpty && plan.limit == nil) ? nil : "fuel_not_proven",
                message: plan.limit,regionIds: directories.keys.sorted(),
                stops: stops,graphMeters: plan.routes.map(\.distanceMeters),diagnostics: nil,
                routes: plan.routes.map { NativeRoutingAdapter.response($0,style: request.profile.style) },
                foundationRoute: plan.foundation.map { NativeRoutingAdapter.response($0,style: request.profile.style) },
                firstReachableStationMeters: plan.firstReachableStationMeters,destinationEscapeMeters: plan.destinationEscapeMeters,
                windowComplete: plan.complete)
        } catch let failure as RoutingFailure {
            return FuelChainResponse(status: "unknown",error: "fuel_not_proven",message: NativeRoutingAdapter.message(failure),
                                     regionIds: nil,stops: [],graphMeters: [],diagnostics: nil)
        }
    }
    func fuelStation(near point: RouteCoordinate,within meters: Double) async throws -> FuelChainStop? {
        let pad = max(0.002,meters/111_000)
        let candidates = packs.fuelStations(minLat: point.latitude-pad,maxLat: point.latitude+pad,
                                           minLon: point.longitude-pad,maxLon: point.longitude+pad)
        let origin = DirtRoutingEngine.Coordinate(longitude: point.longitude,latitude: point.latitude)
        let nearest = candidates.map { station in
            (station,origin.distance(to: .init(longitude: station.longitude,latitude: station.latitude)))
        }.filter { $0.1 <= meters }.min { $0.1 < $1.1 }
        guard let station = nearest?.0 else { return nil }
        return .init(id: station.id,latitude: station.latitude,longitude: station.longitude,
                     name: station.name,brand: station.brand,address: station.address,graphMeters: 0)
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
        hasCompleteNativePack(regionID)
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
        selector = { _ in
            report("routing source=pack; network routing disabled")
            return pack
        }
    }

    static func fixed(_ source: any RoutingSource) -> RoutingSourcePolicy {
        RoutingSourcePolicy { _ in source }
    }

    func select(for request: RouteRequest) -> any RoutingSource {
        selector(request)
    }
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
