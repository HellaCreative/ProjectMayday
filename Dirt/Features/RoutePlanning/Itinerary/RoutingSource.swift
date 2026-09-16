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
    func planLoop(_ request: PlannedLoopRequest) async throws -> PlannedLoop
}

struct PlannedLoopRequest: Sendable {
    let start: RouteCoordinate
    let far: RouteCoordinate
    let targetMeters: Double
    let profile: RouteProfile
    let allowUnknown: Bool
    let wander: Double
    let avoidCities: Bool
    let avoidMotorways: Bool
    let preferBackRoads: Bool
    let seed: UInt64
}

struct PlannedLoop: Sendable {
    let far: RouteCoordinate
    let outbound: RouteResponse
    let inbound: RouteResponse
    let reriddenMeters: Double
    let returnMeters: Double
    var distanceMeters: Double { (outbound.distanceMeters ?? 0) + (inbound.distanceMeters ?? 0) }
}

extension RoutingSource {
    var supportsCombinedFuelPlanning: Bool { false }
    func planLoop(_ request: PlannedLoopRequest) async throws -> PlannedLoop {
        throw RoutingFailure.unsupported("Loop requires on-device packs.")
    }
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
        RoutingDebugLog.shared.event(
            "fuel chain ignored: routing does not consult fuel riderLeg=\(req.fuel.riderLegId)"
        )
        return FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: nil,
            stops: [], graphMeters: [], diagnostics: nil
        )
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        try await client.fuelStation(near: point, within: meters)
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
    func planLoop(_ request: PlannedLoopRequest) async throws -> PlannedLoop {
        var engine = LoopRequest(
            start: .init(longitude: request.start.longitude, latitude: request.start.latitude),
            far: .init(longitude: request.far.longitude, latitude: request.far.latitude),
            targetMeters: request.targetMeters,
            style: RidingStyle(rawValue: request.profile.rawValue) ?? .balanced,
            allowUnknown: request.allowUnknown, seed: request.seed)
        engine.profile.wander = request.wander
        engine.profile.avoidMajorHighways = request.avoidMotorways
        engine.profile.preferBackRoads = request.preferBackRoads
        engine.options.cityWall = request.avoidCities
        let directories = try packs.routingDirectories(for: [
            request.start.locationCoordinate, request.far.locationCoordinate
        ])
        do {
            let result = try await session.loop(engine, directories: directories)
            let style = engine.profile.style
            let outboundIDs = Set(result.outbound.segments.map(\.edgeID))
            let quality = RouteQuality(route: result.combined)
            return PlannedLoop(
                far: RouteCoordinate(longitude: result.far.longitude, latitude: result.far.latitude),
                outbound: NativeRoutingAdapter.response(result.outbound, style: style),
                inbound: NativeRoutingAdapter.response(result.inbound, style: style, prior: outboundIDs),
                reriddenMeters: quality.reriddenMeters,
                returnMeters: quality.returnMeters)
        } catch let failure as RoutingFailure {
            throw RoutingError.server(NativeRoutingAdapter.message(failure))
        } catch let failure as LoopFailure {
            throw RoutingError.server(NativeRoutingAdapter.message(failure))
        }
    }
    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        RoutingDebugLog.shared.event(
            "fuel chain ignored: routing does not consult fuel riderLeg=\(req.fuel.riderLegId)"
        )
        return FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: nil,
            stops: [], graphMeters: [], diagnostics: nil
        )
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
