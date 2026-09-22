import CoreLocation
import Foundation
import DirtRoutingEngine

/// A regional stage is provisional until completed; discarded removes every
/// preview belonging to the current chain. It never authorizes a partial ride.
enum RouteBuildProgress: Sendable {
    case started(regions: [String])
    case stage(index: Int, response: RouteResponse)
    case leg(index: Int, response: RouteResponse)
    case completed(response: RouteResponse)
    case discarded
}

@MainActor
protocol RoutingSource: AnyObject {
    var name: String { get }
    var supportsCombinedFuelPlanning: Bool { get }
    func route(_ req: RouteRequest) async throws -> RouteResponse
    func route(_ req: RouteRequest, onProgress: @escaping @MainActor (RouteBuildProgress) -> Void) async throws -> RouteResponse
    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse
    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop?
    func planLoop(_ request: PlannedLoopRequest) async throws -> PlannedLoop
    func planLoop(_ request: PlannedLoopRequest, onProgress: @escaping @MainActor (Int, RouteBuildProgress) -> Void) async throws -> PlannedLoop
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
    var avoidFerries: Bool = true
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
    func route(_ req: RouteRequest,
               onProgress: @escaping @MainActor (RouteBuildProgress) -> Void) async throws -> RouteResponse {
        let response = try await route(req)
        try Task.checkCancellation()
        onProgress(.completed(response: response))
        return response
    }
    func planLoop(_ request: PlannedLoopRequest,
                  onProgress: @escaping @MainActor (Int, RouteBuildProgress) -> Void) async throws -> PlannedLoop {
        try await planLoop(request)
    }
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
        var blockedStartEscapeToward: RouteCoordinate? = nil
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
    func route(_ req: RouteRequest,
               onProgress: @escaping @MainActor (RouteBuildProgress) -> Void) async throws -> RouteResponse {
        do {
            let directories = try packs.routingDirectories(for: req.locations.map {
                CLLocationCoordinate2D(latitude: $0.latitude,longitude: $0.longitude)
            })
            return try await NativeRouteProgressBridge.route(req, session: session,
                directories: directories, onProgress: onProgress)
        } catch let failure as RoutingFailure {
            throw RoutingError.server(NativeRoutingAdapter.message(failure))
        }
    }

    func planLoop(_ request: PlannedLoopRequest) async throws -> PlannedLoop {
        try await planLoop(request, onProgress: { _, _ in })
    }

    func planLoop(_ request: PlannedLoopRequest,
                  onProgress: @escaping @MainActor (Int, RouteBuildProgress) -> Void) async throws -> PlannedLoop {
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
        engine.access.avoidFerries = request.avoidFerries
        let directories = try packs.routingDirectories(for: [
            request.start.locationCoordinate, request.far.locationCoordinate
        ])
        do {
            let (events, continuation) = AsyncStream<LoopLegProgress>.makeStream()
            let loopRequest = engine
            async let calculation = session.loop(loopRequest, directories: directories, progress: continuation)
            var observedOutbound: ComputedRoute?
            for await event in events {
                try Task.checkCancellation()
                let priorIDs = Set(observedOutbound?.segments.map(\.edgeID) ?? [])
                onProgress(event.index, .started(regions: directories.keys.sorted()))
                var assembler = EditableRouteLegAssembler()
                for (index, leg) in try assembler.finish(event.route).enumerated() {
                    onProgress(event.index, .leg(index: index,
                        response: NativeRoutingAdapter.response(leg, style: engine.profile.style, prior: priorIDs)))
                }
                onProgress(event.index, .completed(response: NativeRoutingAdapter.response(event.route, style: engine.profile.style, prior: priorIDs)))
                if event.index == 0 { observedOutbound = event.route }
            }
            let result = try await calculation
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
        blockedStartEscapeToward: request.options?.blockedStartEscapeToward,
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

/// The production ordered bridge is also used by controlled local-pack tests.
@MainActor
enum NativeRouteProgressBridge {
    static func route(_ req: RouteRequest, session: NativeRoutingSession,
                      directories: [String: URL],
                      onProgress: @escaping @MainActor (RouteBuildProgress) -> Void) async throws -> RouteResponse {
        let request = try NativeRoutingAdapter.request(req)
        let prior = Set(req.options?.priorEdgeIds ?? [])
        let (events, continuation) = AsyncStream<StagedRouter.Progress>.makeStream()
        var assembler = EditableRouteLegAssembler()
        var legIndex = 0
        var completedResponse: RouteResponse?
        func emit(_ legs: [ComputedRoute]) {
            for leg in legs {
                onProgress(.leg(index: legIndex, response: NativeRoutingAdapter.response(
                    leg, style: request.profile.style, prior: prior)))
                legIndex += 1
            }
        }
        async let calculation = session.route(request, directories: directories, progress: continuation)
        do {
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .started(let regions):
                    assembler = EditableRouteLegAssembler(); legIndex = 0; completedResponse = nil
                    onProgress(.started(regions: regions))
                case .stage(let index, let route):
                    emit(try assembler.append(route))
                    onProgress(.stage(index: index, response: NativeRoutingAdapter.response(
                        route, style: request.profile.style, prior: prior)))
                case .completed(let route):
                    emit(try assembler.finish(route))
                    let response = NativeRoutingAdapter.response(route, style: request.profile.style, prior: prior)
                    completedResponse = response
                    onProgress(.completed(response: response))
                case .discarded:
                    assembler = EditableRouteLegAssembler(); legIndex = 0; completedResponse = nil
                    onProgress(.discarded)
                }
            }
            let result = try await calculation
            try Task.checkCancellation()
            return completedResponse ?? NativeRoutingAdapter.response(result, style: request.profile.style, prior: prior)
        } catch {
            onProgress(.discarded)
            throw error
        }
    }
}
