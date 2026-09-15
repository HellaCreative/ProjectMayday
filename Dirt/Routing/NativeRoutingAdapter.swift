import Foundation
import DirtRoutingEngine

nonisolated enum RouteSurfacePresentation {
    static func family(of leaf: String?) -> SurfaceFamily {
        SurfaceFamily(rawValue: ProfilePolicy.family(leaf ?? "").rawValue) ?? .unknown
    }
    static func riderPaintSurface(surfaceName: String,roadClassName: String) -> String {
        if surfaceName == "unknown", ["freeway","arterial","ramp","collector","local","service"].contains(roadClassName) { return "paved" }
        return surfaceName
    }
    static func selectedRoutePaintKey(surfaceName: String,roadClassName: String,accessName: String) -> String {
        accessName == "motorized_unknown" ? "unknown_access" : riderPaintSurface(surfaceName: surfaceName,roadClassName: roadClassName)
    }
    static func isAdventureSurface(_ name: String) -> Bool {
        ["gravel","access","resource","track","double_track","single","unpaved","dirt"].contains(name)
    }
}

nonisolated enum NativeRoutingAdapter {
    static let maximumMatchMeters = 2000.0
    static func request(_ req: RouteRequest) throws -> DirtRoutingEngine.RoutingRequest {
        guard req.locations.count == 2 else { throw RoutingError.invalidEndpoints }
        let a = req.locations[0], b = req.locations[1]
        var native = DirtRoutingEngine.RoutingRequest(start: .init(longitude: a.longitude,latitude: a.latitude),
            end: .init(longitude: b.longitude,latitude: b.latitude),style: RidingStyle(rawValue: req.profile.rawValue) ?? .balanced,
            allowUnknown: req.accessPolicy.motorizedUnknown,seed: req.options?.sessionSeed ?? 0)
        native.options.maximumMeters = req.options?.maxPathMeters ?? .infinity
        native.options.avoidEdges = Set(req.options?.avoidEdgeIds ?? [])
        native.options.priorEdges = Set(req.options?.priorEdgeIds ?? [])
        native.options.backtrackFactor = req.options?.backtrackFactor ?? 4
        native.access.startIsCustomer = req.options?.startEndpointKind == "customers"
        native.access.endIsCustomer = req.options?.endEndpointKind == "customers"
        native.mapZoom = req.options?.mapZoom
        native.matchRadiusMeters = req.options?.matchLimitMeters ?? NativeRoutingAdapter.maximumMatchMeters
        native.profile.avoidMajorHighways = req.options?.ridePreferences?.avoidHighways ?? true
        native.profile.preferBackRoads = req.profile == .cleanest
        native.profile.wander = req.options?.ridePreferences?.normalized.wander ?? 1
        native.options.cityWall = req.options?.ridePreferences?.avoidCities ?? true
        native.options.arrivalEdgeID = req.options?.arrivalEdgeId
        native.options.arrivalRestrictions = (req.options?.arrivalRestrictions ?? []).map {
            RestrictionProgress(pattern: $0.pattern, progress: $0.progress)
        }
        return native
    }
    static func message(_ failure: RoutingFailure) -> String {
        switch failure {
        case .missingPacks(let ids): return "Download the routing packs for \(ids.joined(separator: ", ").uppercased()) to plan this ride."
        case .invalidPack: return "An installed routing pack is incomplete or incompatible. Download its current complete version."
        case .invalidRequest(let detail): return detail
        case .unsupported(let detail): return detail
        case .noMatch: return "A rider point is not close enough to a legally usable mapped road. Move the point onto the road."
        case .noPath: return "The installed road network has no legal connection for these points and settings."
        case .resourceLimit: return "The route calculation reached its limit before it could finish. Your points are preserved."
        }
    }
    static func accessName(_ code: UInt8) -> String {
        switch code { case 0: "motorized_permissive"; case 1: "motorized_unknown"; case 3: "destination"; case 4: "customers"; default: "motorized_prohibited" }
    }
    static func response(_ route: ComputedRoute,style: RidingStyle? = nil,prior: Set<String> = []) -> RouteResponse {
        let quality = RouteQuality(route: route)
        let segments = route.segments.map { segment in
            RouteSegment(surfaceClass: segment.surface == .loose ? "dirt" : segment.surface.rawValue,
                trackClass: segment.roadClass,accessClass: accessName(segment.access),distanceMeters: segment.meters,
                geometry: segment.geometry.map { RouteCoordinate(longitude: $0.longitude,latitude: $0.latitude) },coords: nil,
                edgeId: segment.edgeID,structureType: segment.structure,structureLeaf: segment.structure,
                crossingLabel: segment.structure == "ferry" ? "Ferry crossing" : nil,
                waterCrossing: ["ferry","ford","stream","tidal","stepping_stones"].contains(segment.structure),surfaceLeaf: segment.surfaceLeaf)
        }
        let repeated = route.segments.filter { prior.contains($0.edgeID) }.reduce(0) { $0+$1.meters }
        let unknownAccess = route.segments.filter { $0.access == 1 }.reduce(0) { $0+$1.meters }
        var warnings: [RouteWarning] = []
        if let limit = route.limit {
            warnings.append(.init(code: "search_incomplete",message: "A connected route was found, but comparison of alternatives did not finish (\(limit))."))
        }
        if style == .dirt && quality.knownDirtPercent < 70 {
            warnings.append(.init(code: "low_dirt",message: "This route contains \(quality.knownDirtPercent)% known dirt and does not meet the Dirt riding target."))
        }
        return RouteResponse(status: "complete",error: nil,message: nil,distanceMeters: route.distanceMeters,
            estimatedMovingSeconds: nil,estimatedElapsedSeconds: nil,
            geometry: route.geometry.map { RouteCoordinate(longitude: $0.longitude,latitude: $0.latitude) },segments: segments,
            stats: .init(dirtPercent: Int(quality.knownDirtPercent.rounded()),
                         pavedPercent: quality.totalMeters > 0 ? Int((quality.pavedMeters/quality.totalMeters*100).rounded()) : 0,
                         unknownAccessPercent: route.distanceMeters > 0 ? Int((unknownAccess/route.distanceMeters*100).rounded()) : 0,
                         unknownSurfacePercent: Int(quality.unknownPercent.rounded()),surfaceFamilyMode: "leaf-v3"),
            maneuvers: route.maneuvers.map { .init(instruction: $0.instruction,type: $0.type,stableID: $0.stableID,
                kind: $0.kind,side: $0.side,degrees: $0.degrees,distanceMeters: 0,alongMeters: $0.alongMeters) },
            warnings: warnings.isEmpty ? nil : warnings,
            dirtPercentValue: nil,pavedPercentValue: nil,backtrackMeters: repeated,
            backtrackPct: route.distanceMeters > 0 ? repeated/route.distanceMeters*100 : 0,
            backtrackReason: repeated > 0 ? "shared_road" : nil,restrictedMeters: 0,restrictedReason: nil,
            arrivalEdgeId: route.segments.last?.edgeID,
            arrivalRestrictions: route.arrivalRestrictions.map { .init(pattern: $0.pattern, progress: $0.progress) })
    }
}

/// A dedicated executor keeps pack preparation/search away from app UI work.
/// Only local directories enter this boundary; it cannot fetch missing packs.
actor NativeRoutingSession {
    private var cachedKey: String?
    private var cachedGraph: IndexedGraph?
    private var cachedFuel: [DirtRoutingEngine.FuelStation] = []
    private let compassStore = RoadCompassStore()
    private func prepare(_ directories: [String:URL],budget: ComputationBudget) throws -> IndexedGraph {
        let regions = directories.keys.sorted()
        let key = try regions.map { id in
            let manifest = directories[id]!.appendingPathComponent("pack-manifest.v2.json")
            return id+":"+manifest.path+":"+(try Data(contentsOf: manifest)).base64EncodedString()
        }.joined(separator: "|")
        if key == cachedKey, let cachedGraph { return cachedGraph }
        let repository = try PackRepository(installedDirectories: directories)
        let installed = try regions.map { try repository.open($0,requireSeams: regions.count > 1,budget: budget) }
        guard let first = installed.first else { throw RoutingFailure.missingPacks(regions) }
        let graph: any RoadGraph = installed.count == 1 ? first.graph : try RegionalGraph(packs: installed,budget: budget)
        let indexed = try IndexedGraph(graph,budget: budget)
        var fuel: [String:DirtRoutingEngine.FuelStation] = [:]
        for item in installed {
            guard let file = PackedFuel.decodeFile(item.fuelData) else { throw RoutingFailure.invalidPack("fuel data") }
            for station in file.stations {
                let row = DirtRoutingEngine.FuelStation(id: station.id,coordinate: .init(longitude: station.lon,latitude: station.lat),
                    name: station.name,brand: station.brand,address: station.address)
                if let previous = fuel[row.id], previous.coordinate != row.coordinate { throw RoutingFailure.invalidPack("conflicting fuel identity") }
                fuel[row.id] = row
            }
        }
        cachedKey = key; cachedGraph = indexed; cachedFuel = fuel.values.sorted { $0.id < $1.id }
        return indexed
    }
    private func elapsedMs(from start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: .now).components
        return max(0, Int(Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15))
    }
    func route(_ request: DirtRoutingEngine.RoutingRequest,directories: [String:URL]) throws -> ComputedRoute {
        let started = ContinuousClock.now
        let budget = ComputationBudget(seconds: 60)
        let graph = try prepare(directories,budget: budget)
        let prepared = elapsedMs(from: started)
        let result = try RoutingEngine(pack: graph, compassStore: compassStore).route(request,budget: budget)
        let total = elapsedMs(from: started)
        let searchMs = total - prepared
        let usPerPop = result.poppedLabels > 0 ? Int(Double(searchMs) * 1000.0 / Double(result.poppedLabels)) : 0
        Task { @MainActor in
            RoutingDebugLog.shared.event(
                "pack route elapsedMs=\(total) prepareMs=\(prepared) searchMs=\(searchMs) " +
                "pops=\(result.poppedLabels) usPerPop=\(usPerPop) " +
                "meters=\(Int(result.distanceMeters.rounded())) limit=\(result.limit ?? "-") " +
                "candidates=[\(result.searchSummary ?? "-")]"
            )
        }
        return result
    }
    func fuel(_ request: DirtRoutingEngine.RoutingRequest,requirements: FuelRequirements,directories: [String:URL],seconds: Double) throws -> FuelPlan {
        let started = ContinuousClock.now
        let budget = ComputationBudget(seconds: seconds)
        let graph = try prepare(directories,budget: budget)
        let prepared = elapsedMs(from: started)
        let plan = try FuelPlanner(graph: graph,stations: cachedFuel,compassStore: compassStore)
            .plan(request,requirements: requirements,budget: budget)
        let total = elapsedMs(from: started)
        let hopMeters = plan.routes.map { Int($0.distanceMeters.rounded()) }
        let hopPops = plan.routes.map(\.poppedLabels)
        Task { @MainActor in
            RoutingDebugLog.shared.event(
                "pack fuel elapsedMs=\(total) prepareMs=\(prepared) complete=\(plan.complete ? 1 : 0) " +
                "stops=\(plan.stops.count) hops=\(plan.routes.count) " +
                "hopMeters=[\(hopMeters.map(String.init).joined(separator: ","))] " +
                "hopPops=[\(hopPops.map(String.init).joined(separator: ","))] " +
                "limit=\(plan.limit ?? "-")"
            )
        }
        return plan
    }
}

// Metadata bridge used solely by the existing pack UI.
extension GraphPack {
    nonisolated var regionId: String? { metadata.regionId }
    nonisolated var hasLeaves: Bool { true }
    nonisolated var version: Int { 4 }
}
