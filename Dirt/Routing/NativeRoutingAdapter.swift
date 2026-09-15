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

/// Current and peak physical footprint: the figure iOS uses for its memory limit.
nonisolated enum ProcessMemory {
    static func megabytes() -> (current: Int, peak: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, 0) }
        return (Int(info.phys_footprint / 1_048_576), Int(info.ledger_phys_footprint_peak / 1_048_576))
    }
}

/// A dedicated executor keeps pack preparation/search away from app UI work.
/// Only local directories enter this boundary; it cannot fetch missing packs.
actor NativeRoutingSession {
    private var cachedKey: String?
    private var cachedGraph: IndexedGraph?
    private var cachedFuel: [DirtRoutingEngine.FuelStation] = []
    private let compassStore = RoadCompassStore()
    /// Returns the prepared graph and, when this call built it, how long opening packs,
    /// joining regions, indexing and decoding fuel took.
    private func prepare(_ directories: [String:URL],budget: ComputationBudget) throws -> (graph: IndexedGraph, detail: String?) {
        let regions = directories.keys.sorted()
        let key = try regions.map { id in
            let manifest = directories[id]!.appendingPathComponent("pack-manifest.v2.json")
            return id+":"+manifest.path+":"+(try Data(contentsOf: manifest)).base64EncodedString()
        }.joined(separator: "|")
        if key == cachedKey, let cachedGraph { return (cachedGraph, nil) }
        let started = ContinuousClock.now
        let repository = try PackRepository(installedDirectories: directories)
        let installed = try regions.map { try repository.open($0,requireSeams: regions.count > 1,budget: budget) }
        let openedMs = elapsedMs(from: started)
        guard let first = installed.first else { throw RoutingFailure.missingPacks(regions) }
        let graph: any RoadGraph = installed.count == 1 ? first.graph : try RegionalGraph(packs: installed,budget: budget)
        let joinedMs = elapsedMs(from: started)
        let indexed = try IndexedGraph(graph,budget: budget)
        let indexedMs = elapsedMs(from: started)
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
        let detail = "open:\(openedMs),join:\(joinedMs-openedMs),index:\(indexedMs-joinedMs),fuel:\(elapsedMs(from: started)-indexedMs)"
        return (indexed, detail)
    }
    private func elapsedMs(from start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: .now).components
        return max(0, Int(Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15))
    }
    /// One diagnostic line per request, written for successes and failures alike.
    /// `searches`, `pops` and `usPerPop` cover every search the request ran (failed
    /// corridor widths, penalty reruns, recovery and endpoint retries included), not
    /// only the returned route, whose own count is `selectedPops`.
    private func log(_ label: String,started: ContinuousClock.Instant,prepared: Int,prepareDetail: String?,
                     counter: SearchCounter,outcome: String) {
        let total = elapsedMs(from: started)
        let searchMs = max(0, total - prepared)
        let pops = counter.pops
        let usPerPop = pops > 0 ? Int(Double(searchMs) * 1000.0 / Double(pops)) : 0
        let memory = ProcessMemory.megabytes()
        let line = "\(label) elapsedMs=\(total) prepareMs=\(prepared)" +
            (prepareDetail.map { " prepare=[\($0)]" } ?? "") +
            " searchMs=\(searchMs) searches=\(counter.searches) pops=\(pops) usPerPop=\(usPerPop)" +
            " peakLabels=\(counter.peakLabels) stages=[\(counter.stageSummary)]" +
            " footprintMB=\(memory.current) peakFootprintMB=\(memory.peak) \(outcome)"
        Task { @MainActor in RoutingDebugLog.shared.event(line) }
    }
    func route(_ request: DirtRoutingEngine.RoutingRequest,directories: [String:URL]) throws -> ComputedRoute {
        let started = ContinuousClock.now
        let budget = ComputationBudget(seconds: 60)
        let counter = SearchCounter()
        var request = request
        request.options.counter = counter
        var prepared = 0, prepareDetail: String?
        do {
            let preparation = try prepare(directories,budget: budget)
            prepared = elapsedMs(from: started); prepareDetail = preparation.detail
            let result = try RoutingEngine(pack: preparation.graph, compassStore: compassStore).route(request,budget: budget)
            log("pack route",started: started,prepared: prepared,prepareDetail: prepareDetail,counter: counter,
                outcome: "selectedPops=\(result.poppedLabels) meters=\(Int(result.distanceMeters.rounded())) " +
                    "limit=\(result.limit ?? "-") candidates=[\(result.searchSummary ?? "-")]")
            return result
        } catch {
            log("pack route failed",started: started,prepared: prepared,prepareDetail: prepareDetail,counter: counter,
                outcome: "error=\(error)")
            throw error
        }
    }
    func fuel(_ request: DirtRoutingEngine.RoutingRequest,requirements: FuelRequirements,directories: [String:URL],seconds: Double) throws -> FuelPlan {
        let started = ContinuousClock.now
        let budget = ComputationBudget(seconds: seconds)
        let counter = SearchCounter()
        var request = request
        request.options.counter = counter
        var prepared = 0, prepareDetail: String?
        do {
            let preparation = try prepare(directories,budget: budget)
            prepared = elapsedMs(from: started); prepareDetail = preparation.detail
            let plan = try FuelPlanner(graph: preparation.graph,stations: cachedFuel,compassStore: compassStore)
                .plan(request,requirements: requirements,budget: budget)
            let hopMeters = plan.routes.map { Int($0.distanceMeters.rounded()) }
            let hopPops = plan.routes.map(\.poppedLabels)
            log("pack fuel",started: started,prepared: prepared,prepareDetail: prepareDetail,counter: counter,
                outcome: "complete=\(plan.complete ? 1 : 0) stops=\(plan.stops.count) hops=\(plan.routes.count) " +
                    "hopMeters=[\(hopMeters.map(String.init).joined(separator: ","))] " +
                    "hopPops=[\(hopPops.map(String.init).joined(separator: ","))] " +
                    "limit=\(plan.limit ?? "-") " +
                    "style=\(plan.styleSummary ?? "-")")
            return plan
        } catch {
            log("pack fuel failed",started: started,prepared: prepared,prepareDetail: prepareDetail,counter: counter,
                outcome: "error=\(error)")
            throw error
        }
    }
}

// Metadata bridge used solely by the existing pack UI.
extension GraphPack {
    nonisolated var regionId: String? { metadata.regionId }
    nonisolated var hasLeaves: Bool { true }
    nonisolated var version: Int { 4 }
}
