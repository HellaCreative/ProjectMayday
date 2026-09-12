import CoreLocation
import Foundation

/// Active private hybrid fuel preparation for this isolated Dev candidate.
/// The legacy matcher remains in the method as a rollback path, while this
/// branch exercises bounded caching and cooperative fuel matching directly.
/// This cache stores only completed fuel snap metadata and never road topology.
nonisolated enum NativeFuelPreparation {
    static let enabled = true
    /// A fuel window can contain hundreds of stations. Keep all snap metadata
    /// for a regional pack so Clean/Dirt/Balanced and the next hop do not
    /// repeat geometry projection, while still bounding the cache when a
    /// device visits many packs in one process.
    static let cacheLimit = 4096
}

/// Zoom-aware tap radius. Screen distance, not a second road network.
///
/// metersPerPoint ≈ 156543.03392 * cos(lat) / 2^zoom  (Web Mercator, 1 CSS point)
/// A 28-point finger (~7 mm) at that resolution is the intended tap.
///
/// Safe upper bound: 2000 m. That covers the Yarmouth harbour coarse-zoom
/// miss (~1.7 km to the connected town road) without province-wide fishing.
/// V3 stays capped at 750 m (frozen).
nonisolated enum TapRadius {
    static let minMeters: Double = 80
    static let defaultMeters: Double = 550
    static let v3CapMeters: Double = 750
    static let v4CapMeters: Double = 2_000
    static let fingerPoints: Double = 28
    static let mercatorMetersPerPointAtZoom0: Double = 156_543.03392

    static func capMeters(graphBinaryVersion: Int) -> Double {
        graphBinaryVersion >= 4 ? v4CapMeters : v3CapMeters
    }

    static func meters(
        zoom: Double? = nil,
        latitude: Double,
        requestedMeters: Double? = nil,
        graphBinaryVersion: Int,
        defaultMeters: Double = TapRadius.defaultMeters
    ) -> Double {
        let cap = capMeters(graphBinaryVersion: graphBinaryVersion)
        if let requested = requestedMeters, requested.isFinite, requested > 0 {
            return min(cap, max(minMeters, requested))
        }
        if let zoom, zoom.isFinite, latitude.isFinite {
            let metersPerPoint = mercatorMetersPerPointAtZoom0
                * Darwin.cos(latitude * .pi / 180)
                / Darwin.pow(2, zoom)
            return min(cap, max(minMeters, fingerPoints * metersPerPoint))
        }
        let base = defaultMeters.isFinite && defaultMeters > 0 ? defaultMeters : Self.defaultMeters
        return min(cap, max(minMeters, base))
    }
}

/// On-device Dijkstra over a loaded `graph.v2` pack.
///
/// Costing mirrors pack-fabric `profile-costs` surface weights.
/// Snap is nearest **edge** (geometry polyline when available, else node chord).
/// Mid-edge snaps enter the directed CSR only along legal travel.
/// same-edge taps return the along-edge span, and soft-stitch stubs paint
/// tap/GPS→road projection within `preferredMatchMeters` (camp / driveway approach).
/// Junction repairs mirror live `router.js`: permissive tip joins when Allow is OFF
/// (OSM+NSTDB near-misses), and unknown-island → through-giant stitches when Allow
/// is ON. Geographic loop pruning runs after reconstruction when legs have geometry.
/// Opted out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` so search can run on
/// `Task.detached` without freezing toast paint / map gestures.
nonisolated struct OnDeviceRouter {
    /// Cooperative stop used by bounded on-device fuel windows. The regular
    /// road planner leaves this false; pack fuel planning supplies a deadline
    /// so a target-aware flood cannot run past the rider-facing budget.
    var executionCancelled: @Sendable () -> Bool = { false }
    /// Diagnostic tuning hook for pack-only benchmarks. Production keeps the
    /// policy value; tests can sweep the bounded envelope without changing
    /// the graph or route-selection rules.
    var fastDirtCorridorMetersOverride: Double?

    struct Leg: Sendable {
        var coordinates: [CLLocationCoordinate2D]
        var distanceMeters: Double
        var surfaceName: String
        var edgeId: String
        /// `motorized_*` access class; soft-stitches use permissive.
        var accessName: String = "motorized_permissive"
        /// Packed OSM road class (freeway…track). Used so untagged highways
        /// paint as paved, not dirt.
        var roadClassName: String = "unknown"
        /// Graph-v3 surface leaf (nil on v2 / soft-stitch). Stats only in E1.
        var surfaceLeaf: String? = nil
        /// Packed structure type name (e.g. ferry / ford / tunnel).
        var structureType: String? = nil
        /// Graph-v3 structure leaf (boardwalk, culvert, stepping_stones, …).
        var structureLeaf: String? = nil
        /// OSM layer (overpass > 0, underpass < 0).
        var layer: Int = 0
        /// Rider-facing label for ferries and structure crossings.
        var crossingLabel: String? = nil
        /// True for fords / low-water crossings (adventure/safety signal).
        var waterCrossing: Bool = false
        /// Packed graph identity retained for real decision-point navigation cues.
        var edgeIndex: Int? = nil
        var fromNode: Int? = nil
        var toNode: Int? = nil

        /// Rider-facing surface after OSM highway class wins over untagged unknown.
        var paintSurfaceName: String {
            OnDeviceProfileCosts.riderPaintSurface(
                surfaceName: surfaceName,
                roadClassName: roadClassName
            )
        }
    }

    struct Result: Sendable {
        var coordinates: [CLLocationCoordinate2D]
        var distanceMeters: Double
        var edgeIds: [String]
        var legs: [Leg]
        /// Coarse adventure Dirt% — used for path selection / ranking (unchanged E1).
        var dirtPercent: Int
        var pavedPercent: Int
        var unknownAccessPercent: Int
        /// Honest leaf-based Dirt% when pack has leaves; else mirrors dirtPercent.
        var reportedDirtPercent: Int
        var reportedPavedPercent: Int
        var unknownSurfacePercent: Int
        /// True when every real graph edge can report the authoritative v3
        /// surface leaf, including an honest nil/untagged value.
        var hasSurfaceLeaves: Bool = false
        var maneuvers: [RouteManeuver] = []
        var backtrackMeters: Double = 0
        var backtrackPct: Double = 0
        var backtrackReason: String? = nil
        var debugNote: String = ""
        var searchMeta: SearchMeta = SearchMeta()
        var snapDiagnostics: RouteSnapDiagnostics? = nil
        var allowUnknownLogged: Bool? = nil
        var tapRadiusMeters: Double? = nil
        var mapZoom: Double? = nil
    }

    struct SearchMeta: Sendable, Equatable {
        var timedOut: Bool = false
        var pass2Outcome: String = ""
        var extraUsedMeters: Double? = nil
        var extraBudgetMeters: Double? = nil
        var shortestMeters: Double? = nil
        var pops: Int = 0
        var elapsedMs: Int = 0
        var rideObjective: String? = nil
        var corridorMeters: Double? = nil
        var maxCrossTrackMeters: Double? = nil
        var corridorWidened: Bool = false
        /// True only when Clean found no wall-respecting route and succeeded
        /// after the urban-core wall was relaxed as a last resort.
        var urbanCoreFallbackUsed: Bool = false
        /// True when Clean could not find an all-paved wall-respecting route
        /// and used tagged unpaved fabric while keeping the wall intact.
        var cleanUnpavedFallbackUsed: Bool = false
        /// True when the selected route still crosses a mapped smaller
        /// settlement after applying the strong avoidance score.
        var settlementFallbackUsed: Bool = false
        var minimumEarnedDirtExcursionMeters: Double? = nil
        var shortDirtRepairPasses: Int = 0
        var shortDirtPenaltyEdgeCount: Int = 0
    }

    enum Failure: Error, Equatable, Sendable {
        case cannotSnapStart
        case cannotSnapEnd
        case identicalEnds
        case noPath
        /// A bounded search stopped before proving no path exists.
        case searchLimit(String)
    }

    /// Max distance from tap to an edge chord (visual “on the road”).
    static let maxSnapMeters: Double = 750
    /// Off-road approach: GPS / camp / pin within this of a pack edge soft-stitches
    /// onto the road and routes. Beyond this → name which end is too far.
    static let preferredMatchMeters: Double = 550
    /// Taps closer than this are treated as the same place.
    static let identicalEndsMeters: Double = 40
    /// Mid-edge soft-stitch: ignore stubs shorter than this.
    static let softStitchMinMeters: Double = 2
    /// Treat projection as “at endpoint” within this along-edge distance.
    static let endpointAlongMeters: Double = 8
    /// When the nearest start edge is a disconnected spur, try the next-closest
    /// eligible edges (within soft-approach) that can reach B’s component.
    static let maxStartSnapCandidates: Int = 16
    /// Server `router.js` permissive junction near-miss repair (Allow OFF).
    /// OSM + NSTDB tips often sit 0–40 m apart without shared node ids.
    /// Must match live `JOIN_M` — OSM white-road tip heal (Allow off). Not purple.
    static let permissiveJoinMeters: Double = 150
    /// Server unknown-island → through-giant soft-stitch (Allow ON).
    static let unknownIslandStitchMeters: Double = 100
    /// Last-resort premium on junction stitches (server softStitch ×12).
    static let junctionStitchCostPremium: Double = 12
    static let maxPermissiveStitches: Int = 4000

    let pack: GraphV2Pack
    /// Balanced ratio-seeking: scale paved km cost. Dirt/Clean stay 1.
    var pavedBias: Double = 1
    /// Planning-session seed for controlled variety. New process → new seed.
    var sessionSeed: UInt64 = 0
    /// MapLibre zoom for V4 tap radius. Nil falls back to 550 m, capped at 2000 m.
    var mapZoom: Double? = nil
    /// Optional explicit snap radius, still capped by graph version.
    var matchLimitMeters: Double? = nil
    /// Bounded first response used by the on-device fuel planner. It keeps one
    /// dirt corridor search and skips the expensive comparison ladder; the
    /// returned route still goes through the same legal snap and turn checks.
    var fastSearch: Bool = false

    /// Build the pack's edge index during the location/pack warmup task so a
    /// rider's first fuel hop does not pay the full spatial-index construction
    /// cost on the routing critical path.
    static func prewarmSpatialIndex(for pack: GraphV2Pack) {
        _ = PackEdgeSpatialIndex.shared.grid(for: pack)
    }

    /// New packs carry OSM-derived local cores. Static boxes remain a temporary
    /// compatibility fallback for older installed packs.
    private var packUrbanCores: [UrbanCore.Box] {
        pack.urbanCores.isEmpty ? UrbanCore.boxes : pack.urbanCores
    }

    private var packSettlements: [UrbanCore.Box] { pack.settlements }

    private func settlementBoxes(for profile: RouteProfile) -> [UrbanCore.Box] {
        UrbanCore.settlementBoxes(
            embedded: pack.settlements,
            regionId: pack.regionId,
            profile: profile
        )
    }

    /// Meters to the nearest **routable** pack edge within `maxSnapMeters`.
    /// Matches snap policy: unknown tracks are ignored unless `allowUnknown`.
    func distanceToNearestRoad(
        from point: CLLocationCoordinate2D,
        allowUnknown: Bool = false,
        profile: RouteProfile = .balanced
    ) -> Double? {
        nearestEdgeSnap(to: point, allowUnknown: allowUnknown, profile: profile)?.distanceMeters
    }

    func route(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: Set<String> = [],
        priorEdgeIds: Set<String> = [],
        arrivalEdgeId: String? = nil,
        backtrackFactor: Double = 4,
        sessionSeed: UInt64? = nil,
        maxRouteMeters: Double? = nil,
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false
    ) -> Result? {
        switch routeDetailed(
            from: from,
            to: to,
            profile: profile,
            allowUnknown: allowUnknown,
            avoidEdgeIds: avoidEdgeIds,
            priorEdgeIds: priorEdgeIds,
            arrivalEdgeId: arrivalEdgeId,
            backtrackFactor: backtrackFactor,
            sessionSeed: sessionSeed,
            maxRouteMeters: maxRouteMeters,
            cleanMetroMultiplier: cleanMetroMultiplier,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads
        ) {
        case .success(let result): return result
        case .failure: return nil
        }
    }

    /// Phase E2 lockstep: Clean route with JS-provided snap edges (identical path gate).
    func routeCleanLockstep(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        startEdgeIndex: Int,
        endEdgeIndex: Int,
        startProjected: CLLocationCoordinate2D,
        endProjected: CLLocationCoordinate2D,
        startAlongM: Double,
        endAlongM: Double,
        sessionSeed: UInt64 = 1
    ) -> Result? {
        guard pack.hasLeaves else { return nil }
        guard startEdgeIndex >= 0, startEdgeIndex < pack.undirectedEdgeCount,
              endEdgeIndex >= 0, endEdgeIndex < pack.undirectedEdgeCount else { return nil }
        let startFrom = pack.edgeFrom?[startEdgeIndex] ?? 0
        let startTo = pack.edgeTo?[startEdgeIndex] ?? 0
        let endFrom = pack.edgeFrom?[endEdgeIndex] ?? 0
        let endTo = pack.edgeTo?[endEdgeIndex] ?? 0
        let startSnap = EdgeSnap(
            edgeIndex: startEdgeIndex,
            nodeA: Int(startFrom),
            nodeB: Int(startTo),
            distanceMeters: 0,
            projected: startProjected,
            distanceAlongM: startAlongM,
            segmentIndex: 0,
            tangentDeg: 0
        )
        let endSnap = EdgeSnap(
            edgeIndex: endEdgeIndex,
            nodeA: Int(endFrom),
            nodeB: Int(endTo),
            distanceMeters: 0,
            projected: endProjected,
            distanceAlongM: endAlongM,
            segmentIndex: 0,
            tangentDeg: 0
        )
        var ctx = HopSearchContext.forProfile(.cleanest, seed: sessionSeed)
        ctx.pavedOnly = true
        ctx.cityWall = true
        ctx.variety = false
        ctx.settlementFallback = true
        ctx.avoidMotorways = true
        ctx.preferBackRoads = false
        switch routeWithSnaps(
            from: from,
            to: to,
            startSnap: startSnap,
            endSnap: endSnap,
            profile: .cleanest,
            allowUnknown: false,
            avoidEdgeIds: [],
            ctx: ctx,
            coincidentSiblings: coincidentSiblingLists()
        ) {
        case .success(let result): return result
        case .failure: return nil
        }
    }

    func routeDetailed(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: Set<String> = [],
        priorEdgeIds: Set<String> = [],
        arrivalEdgeId: String? = nil,
        backtrackFactor: Double = 4,
        sessionSeed: UInt64? = nil,
        maxRouteMeters: Double? = nil,
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false
    ) -> Swift.Result<Result, Failure> {
        guard !executionCancelled() else { return .failure(.searchLimit("cancelled")) }
        let pavedWall = routeDetailedOnce(
            from: from, to: to, profile: profile,
            allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds,
            sessionSeed: sessionSeed ?? self.sessionSeed,
            maxRouteMeters: maxRouteMeters,
            priorEdgeIds: priorEdgeIds,
            arrivalEdgeId: arrivalEdgeId,
            backtrackFactor: backtrackFactor,
            cityWall: true,
            pavedOnly: profile == .cleanest,
            urbanCoreFallback: false,
            settlementWall: false,
            settlementFallback: true,
            cleanMetroMultiplier: cleanMetroMultiplier,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads
        )
        guard profile == .cleanest else {
            guard case .failure(.noPath) = pavedWall else { return pavedWall }
            let relaxed = routeDetailedOnce(
                from: from, to: to, profile: profile,
                allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds,
                sessionSeed: sessionSeed ?? self.sessionSeed,
                maxRouteMeters: maxRouteMeters,
                priorEdgeIds: priorEdgeIds,
                arrivalEdgeId: arrivalEdgeId,
                backtrackFactor: backtrackFactor,
                cityWall: true,
                pavedOnly: false,
                urbanCoreFallback: false,
                settlementWall: false,
                settlementFallback: true,
                cleanMetroMultiplier: cleanMetroMultiplier,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads
            )
            guard case .success(var route) = relaxed else { return relaxed }
            route.searchMeta.settlementFallbackUsed = true
            route.debugNote += route.debugNote.isEmpty
                ? "settlementFallback=lastResort"
                : " settlementFallback=lastResort"
            return .success(route)
        }
        switch pavedWall {
        case .success: return pavedWall
        case .failure(.noPath): break
        case .failure: return pavedWall
        }

        // Clean preferences are costs, not permanent graph deletion. First
        // admit tagged unpaved fabric while keeping the urban-core wall.
        let unpavedWall = routeDetailedOnce(
            from: from, to: to, profile: profile,
            allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds,
            sessionSeed: sessionSeed ?? self.sessionSeed,
            maxRouteMeters: maxRouteMeters,
            priorEdgeIds: priorEdgeIds,
            arrivalEdgeId: arrivalEdgeId,
            backtrackFactor: backtrackFactor,
            cityWall: true,
            pavedOnly: false,
            urbanCoreFallback: false,
            settlementWall: false,
            settlementFallback: true,
            cleanMetroMultiplier: cleanMetroMultiplier,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads
        )
        switch unpavedWall {
        case .success(var route):
            route.searchMeta.cleanUnpavedFallbackUsed = true
            let note = "cleanUnpavedFallback=lastResort"
            route.debugNote = route.debugNote.isEmpty ? note : route.debugNote + " " + note
            return .success(route)
        case .failure(.noPath): break
        case .failure: return unpavedWall
        }

        // A city may be unavoidable. Prefer its paved crossing before allowing
        // the combined urban + unpaved last resort.
        let pavedUrbanFallback = routeDetailedOnce(
            from: from, to: to, profile: profile,
            allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds,
            sessionSeed: sessionSeed ?? self.sessionSeed,
            maxRouteMeters: maxRouteMeters,
            priorEdgeIds: priorEdgeIds,
            arrivalEdgeId: arrivalEdgeId,
            backtrackFactor: backtrackFactor,
            cityWall: false,
            pavedOnly: true,
            urbanCoreFallback: true,
            settlementWall: false,
            settlementFallback: true,
            cleanMetroMultiplier: cleanMetroMultiplier,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads
        )
        switch pavedUrbanFallback {
        case .success(var route):
            route.searchMeta.urbanCoreFallbackUsed = true
            let note = "urbanCoreFallback=lastResort"
            route.debugNote = route.debugNote.isEmpty ? note : route.debugNote + " " + note
            return .success(route)
        case .failure(.noPath): break
        case .failure: return pavedUrbanFallback
        }

        let unpavedUrbanFallback = routeDetailedOnce(
            from: from, to: to, profile: profile,
            allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds,
            sessionSeed: sessionSeed ?? self.sessionSeed,
            maxRouteMeters: maxRouteMeters,
            priorEdgeIds: priorEdgeIds,
            arrivalEdgeId: arrivalEdgeId,
            backtrackFactor: backtrackFactor,
            cityWall: false,
            pavedOnly: false,
            urbanCoreFallback: true,
            settlementWall: false,
            settlementFallback: true,
            cleanMetroMultiplier: cleanMetroMultiplier,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads
        )
        guard case .success(var route) = unpavedUrbanFallback else {
            return unpavedUrbanFallback
        }
        route.searchMeta.urbanCoreFallbackUsed = true
        route.searchMeta.cleanUnpavedFallbackUsed = true
        let note = "urbanCoreFallback=lastResort cleanUnpavedFallback=lastResort"
        route.debugNote = route.debugNote.isEmpty ? note : route.debugNote + " " + note
        return .success(route)
    }

    /// Range-limited shortest-meters map from `from`, for fuel itinerary reach.
    func exploreNodeMeters(
        from: CLLocationCoordinate2D,
        toward: CLLocationCoordinate2D,
        maxMeters: Double,
        profile: RouteProfile,
        allowUnknown: Bool,
        cityWall: Bool
    ) -> [Double]? {
        exploreNodeMeters(
            from: from,
            toward: toward,
            maxMeters: maxMeters,
            profile: profile,
            allowUnknown: allowUnknown,
            cityWall: cityWall,
            targetSnaps: nil
        )
    }

    /// Target-aware form used by fuel reachability. It preserves the distances
    /// this routine would produce with a complete flood, but stops once every
    /// legal pump projection has been settled. A pump with no legal projection
    /// is already proven unreachable and does not keep the flood alive.
    private func exploreNodeMeters(
        from: CLLocationCoordinate2D,
        toward: CLLocationCoordinate2D,
        maxMeters: Double,
        profile: RouteProfile,
        allowUnknown: Bool,
        cityWall: Bool,
        targetSnaps: [[EdgeSnap]]?
    ) -> [Double]? {
        _ = cityWall
        _ = toward
        let snaps = nearestEdgeSnaps(
            to: from, allowUnknown: allowUnknown, profile: profile,
            maxMeters: Self.preferredMatchMeters
        )
        guard !snaps.isEmpty else {
            return nil
        }
        let n = pack.nodeCount
        guard n > 0 else { return nil }
        var dist = [Double](repeating: .infinity, count: n)
        var prevEdge = [Int](repeating: -1, count: n)
        var heap = MinHeap()

        // Each option is an endpoint of a snapped pump edge. Once that node is
        // popped, its shortest distance is final and the corresponding pump
        // projection has an exact best-path candidate. We wait for every
        // option, rather than the first one, so the returned pump distance is
        // still the same minimum that a complete flood would produce here.
        var targetOptionsByNode: [Int: Int] = [:]
        if let targetSnaps {
            for pumpSnaps in targetSnaps {
                for snap in pumpSnaps {
                    guard snap.edgeIndex >= 0, snap.edgeIndex < pack.undirectedEdgeCount else { continue }
                    if pack.hasDirectedArc(from: snap.nodeA, to: snap.nodeB, edge: snap.edgeIndex),
                       snap.nodeA >= 0, snap.nodeA < n {
                        targetOptionsByNode[snap.nodeA, default: 0] += 1
                    }
                    if pack.hasDirectedArc(from: snap.nodeB, to: snap.nodeA, edge: snap.edgeIndex),
                       snap.nodeB >= 0, snap.nodeB < n {
                        targetOptionsByNode[snap.nodeB, default: 0] += 1
                    }
                }
            }
        }
        var pendingTargetOptions = targetOptionsByNode.values.reduce(0, +)
        if targetSnaps != nil, pendingTargetOptions == 0 {
            return dist
        }
        // Seed every nearby eligible edge, not only the geometric nearest.
        // Fuel forecourts and GPS fixes often sit beside a disconnected service
        // spur while a through-road is only a few metres farther away.
        for snap in snaps {
            if executionCancelled() { return nil }
            guard snap.edgeIndex >= 0, snap.edgeIndex < pack.undirectedEdgeCount else { continue }
            let edgeM = Double(pack.edgeMeters[snap.edgeIndex])
            let access = max(0, snap.distanceMeters)
            let mA = access + max(0, snap.distanceAlongM)
            let mB = access + max(0, edgeM - snap.distanceAlongM)
            if pack.hasDirectedArc(from: snap.nodeB, to: snap.nodeA, edge: snap.edgeIndex),
               snap.nodeA >= 0, snap.nodeA < n, mA <= maxMeters, mA < dist[snap.nodeA] {
                dist[snap.nodeA] = mA
                heap.push(node: snap.nodeA, cost: mA)
            }
            if pack.hasDirectedArc(from: snap.nodeA, to: snap.nodeB, edge: snap.edgeIndex),
               snap.nodeB >= 0, snap.nodeB < n, mB <= maxMeters, mB < dist[snap.nodeB] {
                dist[snap.nodeB] = mB
                heap.push(node: snap.nodeB, cost: mB)
            }
        }
        let policyUnknown = allowUnknown && profile != .cleanest
        while let cur = heap.pop() {
            if Task.isCancelled || executionCancelled() { return nil }
            if cur.cost != dist[cur.node] { continue }
            if cur.cost > maxMeters { break }
            if let settled = targetOptionsByNode[cur.node] {
                pendingTargetOptions -= settled
                if pendingTargetOptions == 0, targetSnaps != nil {
                    break
                }
            }
            let arcStart = Int(pack.nodeOffsets[cur.node])
            let arcEnd = Int(pack.nodeOffsets[cur.node + 1])
            guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
            for i in arcStart..<arcEnd {
                let toNode = Int(pack.edgeTargets[i])
                let ei = Int(pack.edgeUndirectedIndex[i])
                guard ei >= 0, ei < pack.undirectedEdgeCount, toNode >= 0, toNode < n else { continue }
                if prevEdge[cur.node] == ei { continue }
                if pack.v4HopIllegal(
                    ei: ei, from: cur.node, to: toNode,
                    startEi: -1, endEi: -1, incomingEi: prevEdge[cur.node]
                ) { continue }
                if !traversalAccessAllowed(ei: ei, from: cur.node, to: toNode, allowUnknown: policyUnknown, profile: profile) { continue }
                let newCost = cur.cost + Double(pack.edgeMeters[ei])
                if newCost > maxMeters { continue }
                if newCost < dist[toNode] {
                    dist[toNode] = newCost
                    prevEdge[toNode] = ei
                    heap.push(node: toNode, cost: newCost)
                }
            }
        }
        return dist
    }

    func graphMeters(
        to point: CLLocationCoordinate2D,
        dist: [Double],
        profile: RouteProfile,
        allowUnknown: Bool
    ) -> Double? {
        var best = Double.infinity
        let snaps = fuelSnaps(to: point, allowUnknown: allowUnknown, profile: profile)
        for snap in snaps {
            if executionCancelled() { return nil }
            guard snap.edgeIndex >= 0, snap.edgeIndex < pack.undirectedEdgeCount else { continue }
            let edgeM = Double(pack.edgeMeters[snap.edgeIndex])
            let access = max(0, snap.distanceMeters)
            if pack.hasDirectedArc(from: snap.nodeA, to: snap.nodeB, edge: snap.edgeIndex),
               snap.nodeA >= 0, snap.nodeA < dist.count, dist[snap.nodeA].isFinite {
                best = min(best, dist[snap.nodeA] + access + max(0, snap.distanceAlongM))
            }
            if pack.hasDirectedArc(from: snap.nodeB, to: snap.nodeA, edge: snap.edgeIndex),
               snap.nodeB >= 0, snap.nodeB < dist.count, dist[snap.nodeB].isFinite {
                best = min(best, dist[snap.nodeB] + access + max(0, edgeM - snap.distanceAlongM))
            }
        }
        guard best.isFinite else { return nil }
        return best
    }

    func reachableGraphMeters(
        from: CLLocationCoordinate2D,
        toward: CLLocationCoordinate2D,
        pumps: [POIFeature],
        maxMeters: Double,
        profile: RouteProfile,
        allowUnknown: Bool
    ) -> [String: Double] {
        guard !pumps.isEmpty else { return [:] }
        let targetSnaps = pumps.map { pump -> [EdgeSnap] in
            if executionCancelled() { return [] }
            let point = CLLocationCoordinate2D(latitude: pump.latitude, longitude: pump.longitude)
            // Road distance cannot be shorter than the straight-line distance;
            // skip impossible pumps before doing any geometry projection.
            guard meters(from, point) <= maxMeters else { return [] }
            return fuelSnaps(to: point, allowUnknown: allowUnknown, profile: profile)
        }
        let wall = true
        guard let dist = exploreNodeMeters(
            from: from, toward: toward, maxMeters: maxMeters, profile: profile,
            allowUnknown: allowUnknown, cityWall: wall, targetSnaps: targetSnaps
        ) else { return [:] }
        var out: [String: Double] = [:]
        for (pump, snaps) in zip(pumps, targetSnaps) {
            if Task.isCancelled || executionCancelled() { return [:] }
            var best = Double.infinity
            for snap in snaps {
                if executionCancelled() { return [:] }
                guard snap.edgeIndex >= 0, snap.edgeIndex < pack.undirectedEdgeCount else { continue }
                let edgeM = Double(pack.edgeMeters[snap.edgeIndex])
                let access = max(0, snap.distanceMeters)
                if pack.hasDirectedArc(from: snap.nodeA, to: snap.nodeB, edge: snap.edgeIndex),
                   snap.nodeA >= 0, snap.nodeA < dist.count, dist[snap.nodeA].isFinite {
                    best = min(best, dist[snap.nodeA] + access + max(0, snap.distanceAlongM))
                }
                if pack.hasDirectedArc(from: snap.nodeB, to: snap.nodeA, edge: snap.edgeIndex),
                   snap.nodeB >= 0, snap.nodeB < dist.count, dist[snap.nodeB].isFinite {
                    best = min(best, dist[snap.nodeB] + access + max(0, edgeM - snap.distanceAlongM))
                }
            }
            if best.isFinite,
               best <= maxMeters {
                out[pump.id] = best
            }
        }
        return out
    }

    func shortestGraphMeters(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        maxMeters: Double,
        profile: RouteProfile,
        allowUnknown: Bool
    ) -> Double? {
        let wall = true
        // The old form flooded every eligible node inside the range and only
        // snapped the destination after the flood completed. Fuel planning
        // calls this as a feasibility probe, so a 180 km cap could spend the
        // entire window exploring roads that cannot improve the destination
        // answer. Make the destination a settled target: the flood still
        // returns the exact minimum for every legal destination snap, but it
        // stops as soon as those snaps are finalized.
        let destinationSnaps = fuelSnaps(
            to: to,
            allowUnknown: allowUnknown,
            profile: profile
        )
        guard !destinationSnaps.isEmpty else { return nil }
        guard let dist = exploreNodeMeters(
            from: from, toward: to, maxMeters: maxMeters, profile: profile,
            allowUnknown: allowUnknown, cityWall: wall,
            targetSnaps: [destinationSnaps]
        ) else { return nil }
        return graphMeters(to: to, dist: dist, profile: profile, allowUnknown: allowUnknown)
    }

    private func routeDetailedOnce(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: Set<String>,
        sessionSeed: UInt64,
        maxRouteMeters: Double?,
        priorEdgeIds: Set<String>,
        arrivalEdgeId: String?,
        backtrackFactor: Double,
        cityWall: Bool,
        pavedOnly: Bool,
        urbanCoreFallback: Bool,
        settlementWall: Bool,
        settlementFallback: Bool,
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false
    ) -> Swift.Result<Result, Failure> {
        // Snap only onto edges the profile can traverse.
        // Otherwise Banjo Mike–style camps lock onto NSTDB TRACK (motorized_unknown),
        // then Dijkstra with Allow off reports "no route on the eligible graph"
        // while the basemap still draws a continuous white road.
        let v4 = pack.version >= 4 && pack.legalTopology
        let tapMeters = TapRadius.meters(
            zoom: mapZoom,
            latitude: to.latitude,
            requestedMeters: matchLimitMeters,
            graphBinaryVersion: Int(pack.version)
        )
        let snapCap = v4 ? tapMeters : Self.preferredMatchMeters
        var startRejects: [String] = []
        var endRejects: [String] = []
        let startRaw = nearestEdgeSnaps(
            to: from, allowUnknown: allowUnknown, profile: profile,
            maxMeters: snapCap,
            headingDeg: nil,
            intentBearingDeg: bearingDeg(from: from, to: to),
            rejections: &startRejects
        ).filter { $0.distanceMeters <= snapCap }
        let endRaw = nearestEdgeSnaps(
            to: to, allowUnknown: allowUnknown, profile: profile,
            maxMeters: snapCap,
            headingDeg: nil,
            intentBearingDeg: bearingDeg(from: to, to: from),
            rejections: &endRejects
        ).filter { $0.distanceMeters <= snapCap }
        guard !startRaw.isEmpty else { return .failure(.cannotSnapStart) }
        guard !endRaw.isEmpty else { return .failure(.cannotSnapEnd) }

        let tapSeparation = meters(from, to)
        if tapSeparation < Self.identicalEndsMeters {
            return .failure(.identicalEnds)
        }
        let coincidentSiblings = coincidentSiblingLists()

        let adventureStarts: [EdgeSnap]
        let adventureEnds: [EdgeSnap]
        var v4Pairs: [(EdgeSnap, EdgeSnap)] = []
        if v4 {
            let connected = selectConnectedSnapPairs(
                starts: startRaw,
                ends: endRaw,
                allowUnknown: allowUnknown
            )
            // The fast phone path gets a small, deterministic snap-pair set.
            // Full planning retains every legal pair; fast fuel qualification
            // must not spend its whole response budget retrying equivalent
            // endpoint projections.
            v4Pairs = fastSearch ? Array(connected.pairs.prefix(1)) : connected.pairs
            startRejects.append(contentsOf: connected.rejectionReasons)
            endRejects.append(contentsOf: connected.rejectionReasons)
            guard let first = v4Pairs.first else { return .failure(.cannotSnapEnd) }
            adventureStarts = [first.0]
            adventureEnds = [first.1]
        } else {
            // Prefer through-roads (deg ≥ 2) at BOTH ends. House GPS and basemap-snapped
            // B often lock onto NSTDB / OSM dead-end tips that never join the fabric.
            // Adventure profiles: among through candidates, prefer track/resource over
            // freeway snaps so Dirt/Balanced actually enter the new OSM capillary.
            // Dense purple meshes can crowd yellow paved connectors out of the top of
            // that list — diversify keeps a paved through-road in the attempt set.
            adventureStarts = diversifySnapCandidates(
                preferred: throughPreferredSnaps(startRaw, profile: profile, role: .start),
                distanceOrdered: startRaw
            )
            adventureEnds = diversifySnapCandidates(
                preferred: throughPreferredSnaps(endRaw, profile: profile, role: .end),
                distanceOrdered: endRaw
            )
        }

        var lastFailure: Failure = .noPath
        func attachSnap(_ result: Result, startSnap: EdgeSnap, endSnap: EdgeSnap) -> Result {
            var out = result
            out.allowUnknownLogged = allowUnknown
            out.tapRadiusMeters = snapCap
            out.mapZoom = mapZoom
            out.snapDiagnostics = RouteSnapDiagnostics(
                start: snapEndpoint(
                    raw: from,
                    snap: startSnap,
                    candidateCount: startRaw.count,
                    rejectionReasons: Array(Set(startRejects))
                ),
                end: snapEndpoint(
                    raw: to,
                    snap: endSnap,
                    candidateCount: endRaw.count,
                    rejectionReasons: Array(Set(endRejects))
                )
            )
            return out
        }
        func attempt(
            starts: [EdgeSnap],
            ends: [EdgeSnap],
            ctx: HopSearchContext
        ) -> Swift.Result<Result, Failure>? {
            let pairs = v4 && !v4Pairs.isEmpty
                ? v4Pairs
                : snapAttemptPairs(starts: starts, ends: ends)
            for (startSnap, endSnap) in pairs {
                switch routeWithSnaps(
                    from: from,
                    to: to,
                    startSnap: startSnap,
                    endSnap: endSnap,
                    profile: profile,
                    allowUnknown: allowUnknown,
                    avoidEdgeIds: avoidEdgeIds,
                    ctx: ctx,
                    coincidentSiblings: coincidentSiblings
                ) {
                case .success(let result):
                    return .success(attachSnap(result, startSnap: startSnap, endSnap: endSnap))
                case .failure(let reason):
                    lastFailure = reason
                    if reason != .noPath { return .failure(reason) }
                }
            }
            return nil
        }

        func runProfile(_ ctx: HopSearchContext) -> Swift.Result<Result, Failure> {
            if let hit = attempt(starts: adventureStarts, ends: adventureEnds, ctx: ctx) {
                return hit
            }
            if !v4, profile == .dirt || profile == .balanced {
                let bridgeStarts = diversifySnapCandidates(
                    preferred: throughPreferredSnaps(startRaw, profile: .balanced, role: .start),
                    distanceOrdered: startRaw
                )
                let bridgeEnds = diversifySnapCandidates(
                    preferred: throughPreferredSnaps(endRaw, profile: .cleanest, role: .end),
                    distanceOrdered: endRaw
                )
                if let hit = attempt(starts: bridgeStarts, ends: bridgeEnds, ctx: ctx) {
                    return hit
                }
            }
            return .failure(lastFailure)
        }

        var ctx = HopSearchContext.forProfile(profile, seed: sessionSeed)
        ctx.priorEdgeIds = priorEdgeIds
        ctx.arrivalEdgeId = arrivalEdgeId
        ctx.backtrackFactor = max(1, backtrackFactor)
        ctx.cityWall = cityWall
        ctx.pavedOnly = pavedOnly
        ctx.urbanCoreFallback = urbanCoreFallback
        // Major urban cores are walls. Ordinary mapped towns are a finite
        // avoidance cost so they do not sever otherwise valid rural routes.
        ctx.settlementWall = false
        ctx.settlementFallback = profile != .cleanest ? true : settlementFallback
        ctx.fastSearch = fastSearch
        ctx.cleanMetroMultiplier = cleanMetroMultiplier
        let e4 = RoadTierStats.e4Flags(
            for: profile,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads
        )
        ctx.avoidMotorways = e4.avoidMotorways
        ctx.preferBackRoads = e4.preferBackRoads

        if profile == .dirt {
            // Fuel windows route to the next nearby pump, not the final
            // waypoint. A compact fast corridor prevents a 30 km hop from
            // exploring the whole 60 km adventure fan while retaining the
            // wider corridor for ordinary route planning.
            // The first fast Dirt envelope must be wide enough to retain a
            // genuine off-pavement detour. A 20–30 km line corridor routinely
            // discarded the only connected path to Yarmouth and then paid for
            // an unbounded retry. The measured 40 km envelope completes in
            // about half the time of the 60 km envelope with the same route
            // character; ordinary planning keeps its wider 60 km policy.
            let policyBase = fastSearch
                ? min(HopSearchPolicy.dirtCorridorMeters, 40_000)
                : HopSearchPolicy.dirtCorridorMeters
            let base = fastDirtCorridorMetersOverride ?? policyBase
            let comparisonWidths = fastSearch ? [base] : [base * 2, base]
            let connectivityWidths: [Double?] = fastSearch ? [nil] : [base * 3, base * 4, nil]
            var candidates: [(route: Result, width: Double, objective: String)] = []
            var lastBoundedFailure: Failure = .noPath

            func searchDirt(
                width: Double?,
                costMode: HopSearchPolicy.CostMode = .pavement
            ) -> Swift.Result<Result, Failure> {
                var hunt = ctx
                hunt.costMode = costMode
                // A fresh request seed is an intentional route variation for
                // ordinary planning. A fuel hop is a single bounded legal-leg
                // proof; keeping one label per node prevents the resource
                // fan from consuming the whole station-hop budget. The next
                // route window still receives a fresh seed.
                hunt.variety = !fastSearch && sessionSeed != 0
                hunt.corridorMeters = width
                hunt.hardCorridor = width != nil
                hunt.boundedSearch = true
                hunt.timeCapSeconds = HopSearchPolicy.dirtCandidateTimeCapSeconds
                hunt.popCap = HopSearchPolicy.dirtCandidatePopCap
                hunt.maxPathMeters = maxRouteMeters
                lastFailure = .noPath
                let initial: Result
                switch runProfile(hunt) {
                case .success(let route): initial = route
                case .failure(let failure): return .failure(failure)
                }
                var route = initial
                var penaltyEdgeIds = hunt.shortDirtPenaltyEdgeIds
                var repairPasses = 0
                for _ in 0..<(fastSearch ? 0 : HopSearchPolicy.maximumShortDirtRepairPasses) {
                    let found = Self.shortDirtExcursionEdgeIDs(in: route.legs)
                    let additions = found.subtracting(penaltyEdgeIds)
                    if additions.isEmpty { break }
                    penaltyEdgeIds.formUnion(additions)
                    hunt.shortDirtPenaltyEdgeIds = penaltyEdgeIds
                    guard case .success(let next) = runProfile(hunt) else { break }
                    route = next
                    repairPasses += 1
                }
                route.searchMeta.minimumEarnedDirtExcursionMeters =
                    HopSearchPolicy.minimumEarnedDirtExcursionMeters
                route.searchMeta.shortDirtRepairPasses = repairPasses
                route.searchMeta.shortDirtPenaltyEdgeCount = penaltyEdgeIds.count
                return .success(route)
            }

            for width in comparisonWidths {
                switch searchDirt(width: width) {
                case .success(let route):
                    candidates.append((route, width, "pavement"))
                case .failure(let failure):
                    lastBoundedFailure = failure
                }
            }
            if candidates.isEmpty {
                for width in connectivityWidths {
                    switch searchDirt(width: width) {
                    case .success(let route):
                        candidates.append((route, width ?? 0, "pavement"))
                    case .failure(let failure):
                        lastBoundedFailure = failure
                        continue
                    }
                    break
                }
            }
            // Minimizing absolute pavement normally produces excellent DIRT
            // routes and preserves the established product behaviour. On a
            // weak result, compare one bounded resource-labelled route so a
            // shorter route with less dirt cannot beat a genuinely dirtier
            // ride merely because it contains fewer paved kilometres.
            let primaryBestDirt = candidates.map(\.route.dirtPercent).max() ?? 0
            if !fastSearch && primaryBestDirt < 70 {
                switch searchDirt(width: base, costMode: .balancedResource) {
                case .success(let route):
                    candidates.append((route, base, "resource"))
                case .failure(let failure):
                    lastBoundedFailure = failure
                }
            }
            guard let selected = chooseDirtEnvelopeCandidate(candidates) else {
                return .failure(lastBoundedFailure)
            }
            var route = selected.route
            route.searchMeta.rideObjective = "earned-dirt-detour"
            route.searchMeta.corridorMeters = selected.width > 0 ? selected.width : nil
            route.searchMeta.corridorWidened = selected.width > base
            route.searchMeta.maxCrossTrackMeters = HopSearchPolicy.maxCrossTrackMeters(
                coordinates: route.coordinates, start: from, end: to
            )
            let candidateSummary = candidates.map {
                "\($0.objective)@\(Int($0.width / 1000))km:\($0.route.dirtPercent)%"
            }.joined(separator: ",")
            let note = "objective=earned-dirt-detour corridor=\(Int(selected.width))m candidates=[\(candidateSummary)]"
            route.debugNote = route.debugNote.isEmpty ? note : route.debugNote + " " + note
            return .success(route)
        }

        if profile == .balanced {
            let base = fastSearch
                ? min(HopSearchPolicy.balancedCorridorMeters, 12_000)
                : HopSearchPolicy.balancedCorridorMeters
            let multipliers: [Double] = fastSearch ? [1] : [1, 2, 3, 4, 6, 8]
            var lastEnvelopeFailure: Failure = .noPath
            for width in multipliers.map({ base * $0 }) + [0] {
                var envelope = ctx
                // The first fuel hop is a local legal-leg proof. Resource
                // labels are valuable for a full Balanced itinerary but add
                // a large state space to this bounded phone search; the
                // profile cost still preserves Balanced surface weighting.
                envelope.costMode = fastSearch ? .profile : .balancedResource
                envelope.variety = false
                envelope.corridorMeters = width > 0 ? width : nil
                envelope.hardCorridor = width > 0
                envelope.boundedSearch = true
                envelope.timeCapSeconds = fastSearch ? 2.0 : HopSearchPolicy.pass2TimeCapSeconds
                envelope.popCap = fastSearch
                    ? HopSearchPolicy.pass2PopCap
                    : HopSearchPolicy.pass2PopCap * 10
                envelope.maxPathMeters = maxRouteMeters
                lastFailure = .noPath
                switch runProfile(envelope) {
                case .success(var route):
                    route.searchMeta.rideObjective = "surface-balance"
                    route.searchMeta.corridorMeters = width > 0 ? width : nil
                    route.searchMeta.corridorWidened = width > base
                    route.searchMeta.maxCrossTrackMeters = HopSearchPolicy.maxCrossTrackMeters(
                        coordinates: route.coordinates, start: from, end: to
                    )
                    let note = "objective=\(route.searchMeta.rideObjective ?? "-") corridor=\(Int(width))m"
                    route.debugNote = route.debugNote.isEmpty ? note : route.debugNote + " " + note
                    return .success(route)
                case .failure(let failure):
                    lastEnvelopeFailure = failure
                }
            }
            return .failure(lastEnvelopeFailure)
        }

        // Clean law: one paved fabric search — no corridor ladder, no regression wall.
        if profile == .cleanest {
            var envelope = ctx
            envelope.costMode = .profile
            envelope.variety = false
            envelope.pavedOnly = ctx.pavedOnly
            envelope.corridorMeters = nil
            envelope.hardCorridor = false
            envelope.boundedSearch = true
            envelope.settlementWall = false
            envelope.settlementFallback = false
            envelope.timeCapSeconds = fastSearch
                ? 2.0
                : (ctx.pavedOnly ? 12.0 : HopSearchPolicy.pass2TimeCapSeconds)
            envelope.popCap = HopSearchPolicy.pass2PopCap
            envelope.maxPathMeters = maxRouteMeters
            switch runProfile(envelope) {
            case .success(var route):
                route.searchMeta.rideObjective = "practical-pavement"
                route.searchMeta.corridorMeters = nil
                route.searchMeta.corridorWidened = false
                route.searchMeta.maxCrossTrackMeters = HopSearchPolicy.maxCrossTrackMeters(
                    coordinates: route.coordinates, start: from, end: to
                )
                let note = "objective=practical-pavement pavedOnly=\(ctx.pavedOnly ? 1 : 0)"
                route.debugNote = route.debugNote.isEmpty ? note : route.debugNote + " " + note
                return .success(route)
            case .failure(let failure):
                return .failure(failure)
            }
        }

        if let policyExtra = HopSearchPolicy.corridorMeters(for: profile) {
            var shortCtx = ctx
            shortCtx.costMode = .distance
            shortCtx.variety = false
            shortCtx.maxPathMeters = nil
            let shortest = runProfile(shortCtx)
            guard case .success(let short) = shortest else {
                return annotateCorridor(shortest, from: from, to: to, profile: profile, shortestMeters: nil)
            }
            let extra = min(
                policyExtra,
                maxRouteMeters.map { $0 - short.distanceMeters } ?? policyExtra
            )
            guard extra >= 0 else { return .failure(.noPath) }
            var hunt = ctx
            hunt.shortestMeters = short.distanceMeters
            hunt.maxPathMeters = short.distanceMeters + extra
            switch profile {
            case .dirt:
                // Dirt explicitly minimizes pavement inside shortest + 50 km.
                // Weighted Dijkstra spent the budget without maximizing dirt
                // and could return less dirt than Balanced on the same graph.
                hunt.costMode = .balancedResource
                hunt.variety = false
            case .balanced:
                hunt.costMode = .balancedResource
                hunt.variety = false
            case .cleanest:
                break
            }
            let huntStarted = CFAbsoluteTimeGetCurrent()
            let huntResult = runProfile(hunt)
            switch huntResult {
            case .success(var hit):
                hit.searchMeta.extraBudgetMeters = extra
                let ms = Int((CFAbsoluteTimeGetCurrent() - huntStarted) * 1000)
                print(
                    "[DirtRoute] pass2 outcome=\(hit.searchMeta.pass2Outcome.isEmpty ? "completed" : hit.searchMeta.pass2Outcome)"
                        + " timedOut=\(hit.searchMeta.timedOut ? 1 : 0)"
                        + " pops=\(hit.searchMeta.pops) ms=\(ms)"
                        + " extraUsed=\(Int(max(0, hit.distanceMeters - short.distanceMeters)))m"
                        + " dirt%=\(hit.dirtPercent)"
                )
                return annotateCorridor(
                    .success(hit), from: from, to: to, profile: profile,
                    shortestMeters: short.distanceMeters
                )
            case .failure(let reason):
                let ms = Int((CFAbsoluteTimeGetCurrent() - huntStarted) * 1000)
                let outcome: String
                let timedOut: Bool
                if case .searchLimit(let limit) = reason {
                    outcome = limit
                    timedOut = true
                } else {
                    outcome = "noPath"
                    timedOut = false
                }
                print(
                    "[DirtRoute] pass2 outcome=\(outcome) timedOut=\(timedOut ? 1 : 0) reason=\(reason) ms=\(ms) — surfacing shortest"
                )
                var fallback = short
                fallback.searchMeta.timedOut = timedOut
                fallback.searchMeta.pass2Outcome = outcome
                fallback.searchMeta.elapsedMs = ms
                fallback.searchMeta.shortestMeters = short.distanceMeters
                fallback.searchMeta.extraBudgetMeters = extra
                fallback.searchMeta.extraUsedMeters = 0
                return annotateCorridor(
                    .success(fallback), from: from, to: to, profile: profile,
                    shortestMeters: short.distanceMeters
                )
            }
        }

        if let maxRouteMeters {
            ctx.maxPathMeters = maxRouteMeters
            ctx.variety = false
        }

        return annotateCorridor(runProfile(ctx), from: from, to: to, profile: profile, shortestMeters: nil)
    }

    private func annotateCorridor(
        _ result: Swift.Result<Result, Failure>,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        shortestMeters: Double?
    ) -> Swift.Result<Result, Failure> {
        guard case .success(var route) = result else { return result }
        let extraCap = route.searchMeta.extraBudgetMeters
            ?? HopSearchPolicy.corridorMeters(for: profile)
        if let short = shortestMeters, let cap = extraCap {
            let used = max(0, route.distanceMeters - short)
            route.searchMeta.shortestMeters = short
            route.searchMeta.extraUsedMeters = used
            route.searchMeta.extraBudgetMeters = cap
            let outcome = route.searchMeta.pass2Outcome.isEmpty ? "completed" : route.searchMeta.pass2Outcome
            let note = String(
                format: "shortest=%.0fm extraUsed=%.0fm extraCap=%.0fm dirt%%=%d pass2=%@ timedOut=%d pops=%d",
                short, used, cap, route.dirtPercent,
                outcome as NSString, route.searchMeta.timedOut ? 1 : 0, route.searchMeta.pops
            )
            route.debugNote = route.debugNote.isEmpty ? note : route.debugNote + " " + note
        } else {
            let maxXT = HopSearchPolicy.maxCrossTrackMeters(
                coordinates: route.coordinates, start: from, end: to
            )
            let note = "maxXT=\(Int(maxXT))m cap=none"
            route.debugNote = route.debugNote.isEmpty ? note : route.debugNote + " " + note
        }
        return .success(route)
    }

    /// Dirt works back from 100%. When percentages are effectively tied, use
    /// less pavement and then less cross-track wandering. Total route length is
    /// intentionally not an objective.
    private func chooseDirtEnvelopeCandidate(
        _ candidates: [(route: Result, width: Double, objective: String)]
    ) -> (route: Result, width: Double, objective: String)? {
        let summaries = candidates.map { candidate in
            let shape = HopSearchPolicy.routeShape(
                coordinates: candidate.route.coordinates,
                start: candidate.route.coordinates.first ?? .init(),
                end: candidate.route.coordinates.last ?? .init()
            )
            return (candidate: candidate, shape: shape)
        }
        let coherent = summaries.filter {
            $0.shape.backwardMeters <= max(5_000, $0.shape.routeMeters * 0.08)
        }
        let bestDirt = summaries.map(\.candidate.route.dirtPercent).max() ?? 0
        let bestCoherentDirt = coherent.map(\.candidate.route.dirtPercent).max() ?? Int.min
        let pool = !coherent.isEmpty && bestDirt - bestCoherentDirt < 10
            ? coherent
            : summaries
        return pool.min { lhs, rhs in
            let a = lhs.candidate
            let b = rhs.candidate
            let dirtDelta = a.route.dirtPercent - b.route.dirtPercent
            if abs(dirtDelta) > 2 { return dirtDelta > 0 }
            let pavedA = a.route.distanceMeters * Double(100 - a.route.dirtPercent) / 100
            let pavedB = b.route.distanceMeters * Double(100 - b.route.dirtPercent) / 100
            if abs(pavedA - pavedB) > 2_000 { return pavedA < pavedB }
            func crossTrack(_ route: Result) -> Double {
                guard let start = route.coordinates.first,
                      let end = route.coordinates.last else { return 0 }
                return HopSearchPolicy.maxCrossTrackMeters(
                    coordinates: route.coordinates, start: start, end: end
                )
            }
            let crossA = crossTrack(a.route)
            let crossB = crossTrack(b.route)
            if abs(crossA - crossB) > 1_000 { return crossA < crossB }
            if a.route.dirtPercent != b.route.dirtPercent {
                return a.route.dirtPercent > b.route.dirtPercent
            }
            return a.width < b.width
        }?.candidate
    }

    static func shortDirtExcursionEdgeIDs(
        in legs: [Leg],
        minimumMeters: Double = HopSearchPolicy.minimumEarnedDirtExcursionMeters
    ) -> Set<String> {
        guard legs.count >= 3 else { return [] }
        func isPavedBoundary(_ leg: Leg) -> Bool {
            leg.structureType != "ferry" && leg.surfaceName == "paved"
        }
        func isKnownUnpaved(_ surface: String) -> Bool {
            ["gravel", "access", "resource", "track", "double_track", "single", "unpaved", "dirt"]
                .contains(surface)
        }

        var result: Set<String> = []
        var index = 0
        while index < legs.count {
            if isPavedBoundary(legs[index]) || legs[index].structureType == "ferry" {
                index += 1
                continue
            }
            let start = index
            var knownUnpavedMeters = 0.0
            var edgeIDs: [String] = []
            while index < legs.count,
                  !isPavedBoundary(legs[index]),
                  legs[index].structureType != "ferry" {
                let leg = legs[index]
                if isKnownUnpaved(leg.surfaceName) {
                    knownUnpavedMeters += max(0, leg.distanceMeters)
                }
                if !leg.edgeId.isEmpty,
                   !leg.edgeId.hasPrefix("soft-stitch-"),
                   !leg.edgeId.hasPrefix("perm-stitch-") {
                    edgeIDs.append(leg.edgeId)
                }
                index += 1
            }
            let boundedByPavement = start > 0 && index < legs.count
                && isPavedBoundary(legs[start - 1])
                && isPavedBoundary(legs[index])
            if boundedByPavement && knownUnpavedMeters < minimumMeters {
                result.formUnion(edgeIDs)
            }
        }
        return result
    }

    private enum SnapRole {
        case start
        case end
    }

    /// Keep adventure ordering, but always reserve a paved through-road (and a
    /// generic through-road) so basemap yellow/white connectors remain routable
    /// when purple tendril tips form a denser-but-disconnected local mesh.
    private func diversifySnapCandidates(
        preferred: [EdgeSnap],
        distanceOrdered: [EdgeSnap]
    ) -> [EdgeSnap] {
        var out = preferred
        var seen = Set(preferred.map(\.edgeIndex))

        func append(_ snap: EdgeSnap) {
            guard snap.edgeIndex >= 0, seen.insert(snap.edgeIndex).inserted else { return }
            out.append(snap)
        }

        func isThrough(_ snap: EdgeSnap) -> Bool {
            max(degree(snap.nodeA), degree(snap.nodeB)) >= 2
        }

        func isPaved(_ snap: EdgeSnap) -> Bool {
            guard snap.edgeIndex >= 0, snap.edgeIndex < pack.undirectedEdgeCount else { return false }
            return GraphV2Pack.unpackSurface(pack.edgeAttrs[snap.edgeIndex]) == 0
        }

        if let paved = distanceOrdered.first(where: { isThrough($0) && isPaved($0) }) {
            append(paved)
        }
        if let through = distanceOrdered.first(where: { isThrough($0) }) {
            append(through)
        }
        for snap in distanceOrdered where isThrough(snap) {
            append(snap)
            if out.count >= Self.maxStartSnapCandidates { break }
        }
        return Array(out.prefix(Self.maxStartSnapCandidates))
    }

    /// Through-network edges first (max endpoint degree ≥ 2), then by snap score.
    /// Start snaps (non-cleanest): mild adventure surface/class bias so pins do
    /// not start on pavement when a track is almost as close (server parity).
    /// End snaps stay distance-first — dirt bias at B caused spur U-turns.
    private func throughPreferredSnaps(
        _ candidates: [EdgeSnap],
        profile: RouteProfile,
        role: SnapRole
    ) -> [EdgeSnap] {
        candidates.sorted { a, b in
            let da = max(degree(a.nodeA), degree(a.nodeB))
            let db = max(degree(b.nodeA), degree(b.nodeB))
            let throughA = da >= 2
            let throughB = db >= 2
            if throughA != throughB { return throughA && !throughB }
            let sa = snapScore(a, profile: profile, role: role)
            let sb = snapScore(b, profile: profile, role: role)
            if abs(sa - sb) > 0.5 { return sa < sb }
            return a.distanceMeters < b.distanceMeters
        }
    }

    /// Tie-break only — never steal a snap that is substantially closer.
    /// Dirt/Balanced ends: distance-first (no paved preference). Preferring paved
    /// at B yanked pins onto black/orange highway spines when zoomed out, while
    /// the same pin carefully dropped on blue track (zoomed in) used the mesh.
    private func snapScore(
        _ snap: EdgeSnap,
        profile: RouteProfile,
        role: SnapRole
    ) -> Double {
        var score = snap.distanceMeters
        guard snap.edgeIndex >= 0, snap.edgeIndex < pack.undirectedEdgeCount else { return score }
        let attr = pack.edgeAttrs[snap.edgeIndex]
        let surface = GraphV2Pack.unpackSurface(attr)
        let roadClass = GraphV2Pack.unpackRoadClass(attr)
        let surfaceName = OnDeviceProfileCosts.surfaceName(code: surface)
        let roadName = GraphV2Pack.roadClassName(roadClass)

        if OnDeviceProfileCosts.isMajorHighway(roadName, profile: profile),
           snap.distanceMeters < OnDeviceProfileCosts.majorHighwayPinMeters {
            return snap.distanceMeters
        }

        switch (profile, role) {
        case (.cleanest, _):
            break // endpoint eligibility is access-only; Clean costs the routed path
        case (_, .start) where profile != .cleanest:
            if surfaceName != "paved" { score -= 22 }
            if OnDeviceProfileCosts.isAdventureRoadClass(roadClass) { score -= 12 }
            if roadName == "freeway" || roadName == "arterial" || roadName == "ramp" {
                score += 35
            }
        case (.dirt, .end), (.balanced, .end):
            // Mild adventure tie-break only — never beat a clearly closer paved edge
            // (avoids dirt-spur U-turns past the pin). ~18 m of slack.
            if surfaceName != "paved" { score -= 18 }
            if OnDeviceProfileCosts.isAdventureRoadClass(roadClass) { score -= 10 }
            if roadName == "freeway" || roadName == "arterial" || roadName == "ramp" {
                score += 28
            }
        default:
            break
        }
        return score
    }

    /// Bounded (start, end) snap pairs: best through×through first, then alternate
    /// starts, then alternate ends — avoids province-wide BFS and caps Dijkstra count.
    private func snapAttemptPairs(
        starts: [EdgeSnap],
        ends: [EdgeSnap]
    ) -> [(EdgeSnap, EdgeSnap)] {
        let startList = Array(starts.prefix(Self.maxStartSnapCandidates))
        let endList = Array(ends.prefix(8))
        guard let s0 = startList.first, let e0 = endList.first else { return [] }

        var pairs: [(EdgeSnap, EdgeSnap)] = [(s0, e0)]
        var seen = Set<String>()
        seen.insert("\(s0.edgeIndex):\(e0.edgeIndex)")

        func append(_ s: EdgeSnap, _ e: EdgeSnap) {
            let key = "\(s.edgeIndex):\(e.edgeIndex)"
            guard seen.insert(key).inserted else { return }
            pairs.append((s, e))
        }

        for s in startList.dropFirst() {
            append(s, e0)
            if pairs.count >= 12 { return pairs }
        }
        for e in endList.dropFirst() {
            append(s0, e)
            if pairs.count >= 12 { return pairs }
        }
        // A few cross pairs when both ends have through alternatives.
        for s in startList.dropFirst().prefix(3) {
            for e in endList.dropFirst().prefix(3) {
                append(s, e)
                if pairs.count >= 16 { return pairs }
            }
        }
        return pairs
    }

    private func routeWithSnaps(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        startSnap: EdgeSnap,
        endSnap: EdgeSnap,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: Set<String>,
        ctx: HopSearchContext,
        coincidentSiblings: [[Int]?]
    ) -> Swift.Result<Result, Failure> {
        // Same snapped edge: paint the along-edge span (find-path-v2 vBetween).
        if startSnap.edgeIndex >= 0,
           startSnap.edgeIndex == endSnap.edgeIndex,
           abs(startSnap.distanceAlongM - endSnap.distanceAlongM) > 1 {
            // Snapped A/B edge is always traversable under Clean law.
            if edgeBlockedByPavedOnly(
                startSnap.edgeIndex, ctx: ctx,
                allowSnapEdges: startSnap.edgeIndex, endEi: endSnap.edgeIndex
            ) {
                return .failure(.noPath)
            }
            if let same = sameEdgeResult(from: from, to: to, startSnap: startSnap, endSnap: endSnap) {
                if let cap = ctx.maxPathMeters, same.distanceMeters > cap {
                    return .failure(.noPath)
                }
                return .success(same)
            }
        }

        if startSnap.edgeIndex >= 0, endSnap.edgeIndex >= 0,
           pack.edgeFrom != nil, pack.edgeTo != nil {
            return routeViaVirtualEndpoints(
                from: from,
                to: to,
                startSnap: startSnap,
                endSnap: endSnap,
                profile: profile,
                allowUnknown: allowUnknown,
                avoidEdgeIds: avoidEdgeIds,
                ctx: ctx,
                coincidentSiblings: coincidentSiblings
            )
        }
        return routeViaPreferredNodes(
            from: from,
            to: to,
            startSnap: startSnap,
            endSnap: endSnap,
            profile: profile,
            allowUnknown: allowUnknown,
            avoidEdgeIds: avoidEdgeIds,
            ctx: ctx
        )
    }

    // MARK: - Same-edge shortcut

    private func sameEdgeResult(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        startSnap: EdgeSnap,
        endSnap: EdgeSnap
    ) -> Result? {
        let ei = startSnap.edgeIndex
        let alongForward = startSnap.distanceAlongM <= endSnap.distanceAlongM
        let legal = alongForward
            ? pack.hasDirectedArc(from: startSnap.nodeA, to: startSnap.nodeB, edge: ei)
            : pack.hasDirectedArc(from: startSnap.nodeB, to: startSnap.nodeA, edge: ei)
        guard legal else { return nil }
        let poly = edgeGeometry(ei) ?? [
            coordinate(forNode: startSnap.nodeA),
            coordinate(forNode: startSnap.nodeB)
        ]
        guard poly.count >= 2 else { return nil }

        let between = coordsBetweenMatches(
            poly,
            start: startSnap,
            end: endSnap
        )
        guard between.count >= 2 else { return nil }
        let alongM = lineMeters(between)
        guard alongM > 1 else { return nil }

        let surface = OnDeviceProfileCosts.surfaceName(
            code: GraphV2Pack.unpackSurface(pack.edgeAttrs[ei])
        )
        let id = pack.edgeId(ei)

        var legs: [Leg] = []
        if let stub = softStitchStub(tap: from, snap: startSnap, idSuffix: "start") {
            legs.append(stub)
        }
        legs.append(Leg(
            coordinates: between,
            distanceMeters: alongM,
            surfaceName: surface,
            edgeId: id,
            accessName: accessNameForEdge(ei),
            roadClassName: roadClassNameForEdge(ei),
            surfaceLeaf: pack.hasLeaves ? pack.surfaceLeaf(ei) : nil,
            structureType: structureTypeForEdge(ei),
            structureLeaf: structureLeafForEdge(ei),
            layer: layerForEdge(ei),
            crossingLabel: crossingLabelForEdge(ei),
            waterCrossing: waterCrossingForEdge(ei)
        ))
        if let stub = softStitchStub(tap: to, snap: endSnap, idSuffix: "end") {
            legs.append(stub)
        }

        return finalize(legs: legs, nodeFallback: between, profile: .cleanest)
    }

    // MARK: - Virtual endpoint Dijkstra (find-path-v2 parity)

    private struct VirtEdge {
        var a: Int
        var b: Int
        var meters: Double
        var coords: [CLLocationCoordinate2D]
        var ei: Int
        var accessLeg: Bool
        /// Synthetic junction stitch (perm / unknown-island) — not a pack edge index.
        var junctionStitch: Bool = false
        var stitchEdgeId: String = ""
        var stitchSurface: String = "access"
    }

    private struct JunctionStitch {
        var a: Int
        var b: Int
        var meters: Double
        var edgeId: String
    }

    private func routeViaVirtualEndpoints(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        startSnap: EdgeSnap,
        endSnap: EdgeSnap,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: Set<String>,
        ctx: HopSearchContext,
        coincidentSiblings: [[Int]?]
    ) -> Swift.Result<Result, Failure> {
        let n = pack.nodeCount
        let startVirt = n
        let endVirt = n + 1
        let total = n + 2
        let policyUnknown = allowUnknown && profile != .cleanest
        let startEi = startSnap.edgeIndex
        let endEi = endSnap.edgeIndex
        let startPoly = edgeGeometry(startEi) ?? [
            coordinate(forNode: startSnap.nodeA),
            coordinate(forNode: startSnap.nodeB)
        ]
        let endPoly = startEi == endEi
            ? startPoly
            : (edgeGeometry(endEi) ?? [
                coordinate(forNode: endSnap.nodeA),
                coordinate(forNode: endSnap.nodeB)
            ])

        let edgeMetersStart = Double(pack.edgeMeters[startEi])
        let edgeMetersEnd = Double(pack.edgeMeters[endEi])
        let endLL = endSnap.projected
        let abMeters = meters(startSnap.projected, endLL)
        let startOnMajorHighway = snapIsMajorHighwayPin(startSnap, profile: profile)
        let endOnMajorHighway = snapIsMajorHighwayPin(endSnap, profile: profile)

        func awayExtra(fromNode: Int, toNode: Int) -> Double {
            func ll(_ node: Int) -> CLLocationCoordinate2D? {
                if node == startVirt { return startSnap.projected }
                if node == endVirt { return endSnap.projected }
                if node >= 0, node < n { return coordinate(forNode: node) }
                return nil
            }
            guard let a = ll(fromNode), let b = ll(toNode) else { return 0 }
            return OnDeviceProfileCosts.approachAwayExtra(
                profile: profile,
                dFromMeters: meters(a, endLL),
                dToMeters: meters(b, endLL),
                abMeters: abMeters,
                regionId: pack.regionId
            )
        }

        var virt: [VirtEdge] = []
        func addVirt(
            _ a: Int,
            _ b: Int,
            meters: Double,
            coords: [CLLocationCoordinate2D],
            ei: Int,
            accessLeg: Bool,
            junctionStitch: Bool = false,
            stitchEdgeId: String = "",
            stitchSurface: String = "access"
        ) -> Int {
            let id = virt.count
            virt.append(VirtEdge(
                a: a, b: b, meters: max(0, meters), coords: coords, ei: ei, accessLeg: accessLeg,
                junctionStitch: junctionStitch, stitchEdgeId: stitchEdgeId, stitchSurface: stitchSurface
            ))
            return id
        }

        let toSA = coordsFromAToMatch(startPoly, snap: startSnap)
        let toSB = coordsFromMatchToB(startPoly, snap: startSnap)
        let mSA = max(0, startSnap.distanceAlongM)
        let mSB = max(0, edgeMetersStart - mSA)
        let vStartA = addVirt(
            startVirt, startSnap.nodeA,
            meters: mSA, coords: Array(toSA.reversed()), ei: startEi, accessLeg: true
        )
        let vStartB = addVirt(
            startVirt, startSnap.nodeB,
            meters: mSB, coords: toSB, ei: startEi, accessLeg: true
        )

        let toEA = coordsFromAToMatch(endPoly, snap: endSnap)
        let toEB = coordsFromMatchToB(endPoly, snap: endSnap)
        let mEA = max(0, endSnap.distanceAlongM)
        let mEB = max(0, edgeMetersEnd - mEA)
        let vEndA = addVirt(
            endVirt, endSnap.nodeA,
            meters: mEA, coords: Array(toEA.reversed()), ei: endEi, accessLeg: true
        )
        let vEndB = addVirt(
            endVirt, endSnap.nodeB,
            meters: mEB, coords: toEB, ei: endEi, accessLeg: true
        )

        var vBetween = -1
        if startEi == endEi {
            let between = coordsBetweenMatches(startPoly, start: startSnap, end: endSnap)
            if between.count >= 2 {
                vBetween = addVirt(
                    startVirt, endVirt,
                    meters: lineMeters(between), coords: between, ei: startEi, accessLeg: false
                )
            }
        }

        var virtAdj: [Int: [(to: Int, id: Int, forward: Bool)]] = [:]
        var virtAdjRev: [Int: [(to: Int, id: Int, forward: Bool)]] = [:]
        func linkVirtArc(_ id: Int, from: Int, to: Int, forward: Bool) {
            guard from >= 0, to >= 0 else { return }
            virtAdj[from, default: []].append((to: to, id: id, forward: forward))
            virtAdjRev[to, default: []].append((to: from, id: id, forward: !forward))
        }
        func linkVirt(_ id: Int) {
            let v = virt[id]
            linkVirtArc(id, from: v.a, to: v.b, forward: true)
            linkVirtArc(id, from: v.b, to: v.a, forward: false)
        }
        if pack.hasDirectedArc(from: startSnap.nodeB, to: startSnap.nodeA, edge: startEi) {
            linkVirtArc(vStartA, from: startVirt, to: startSnap.nodeA, forward: true)
        }
        if pack.hasDirectedArc(from: startSnap.nodeA, to: startSnap.nodeB, edge: startEi) {
            linkVirtArc(vStartB, from: startVirt, to: startSnap.nodeB, forward: true)
        }
        if pack.hasDirectedArc(from: endSnap.nodeA, to: endSnap.nodeB, edge: endEi) {
            linkVirtArc(vEndA, from: endSnap.nodeA, to: endVirt, forward: false)
        }
        if pack.hasDirectedArc(from: endSnap.nodeB, to: endSnap.nodeA, edge: endEi) {
            linkVirtArc(vEndB, from: endSnap.nodeB, to: endVirt, forward: false)
        }
        if vBetween >= 0 {
            let alongForward = startSnap.distanceAlongM <= endSnap.distanceAlongM
            let betweenLegal = alongForward
                ? pack.hasDirectedArc(from: startSnap.nodeA, to: startSnap.nodeB, edge: startEi)
                : pack.hasDirectedArc(from: startSnap.nodeB, to: startSnap.nodeA, edge: startEi)
            if betweenLegal {
                linkVirtArc(vBetween, from: startVirt, to: endVirt, forward: true)
            }
        }

        // Join near-miss fabric tips so Allow OFF works
        // on NS OSM+NSTDB packs (Farm Road / driveway → public road).
        // find-path-v2 has no perm-/unknown-island stitches — Clean+leaves must
        // omit them so JS↔Swift paths stay identical (Phase E2).
        let stitches: [JunctionStitch] =
            (profile == .cleanest && pack.hasLeaves) || pack.version >= 4
            ? []
            : junctionStitches(
                near: from,
                and: to,
                profile: profile,
                allowUnknown: allowUnknown,
                avoidEdgeIds: avoidEdgeIds
            )
        for stitch in stitches {
            let coords = [coordinate(forNode: stitch.a), coordinate(forNode: stitch.b)]
            let id = addVirt(
                stitch.a, stitch.b,
                meters: stitch.meters,
                coords: coords,
                ei: -1,
                accessLeg: true,
                junctionStitch: true,
                stitchEdgeId: stitch.edgeId,
                stitchSurface: "access"
            )
            linkVirt(id)
        }

        var slackToDest: [Double]? = nil
        // Fast fuel hops already enforce the candidate-specific cap in the
        // forward search. The reverse flood is a valuable pruning bound for
        // full route planning, but duplicating that graph walk on every phone
        // station hop adds latency without changing the legal result.
        if !fastSearch, let cap = ctx.maxPathMeters, cap.isFinite, cap < .greatestFiniteMagnitude / 4 {
            slackToDest = fillShortestMeters(
                from: endVirt,
                capMeters: cap,
                nodeCount: n,
                total: total,
                virt: virt,
                virtAdj: virtAdjRev,
                from: from,
                to: to,
                ctx: ctx,
                profile: profile,
                policyUnknown: policyUnknown,
                avoidEdgeIds: avoidEdgeIds,
                coincidentSiblings: coincidentSiblings
            )
        }

        if ctx.costMode == .balancedResource {
            return searchVirtualBalanced(
                from: from,
                to: to,
                startSnap: startSnap,
                endSnap: endSnap,
                startVirt: startVirt,
                endVirt: endVirt,
                nodeCount: n,
                virt: virt,
                virtAdj: virtAdj,
                profile: profile,
                policyUnknown: policyUnknown,
                avoidEdgeIds: avoidEdgeIds,
                ctx: ctx,
                slackToDest: slackToDest,
                coincidentSiblings: coincidentSiblings
            )
        }

        var dist = [Double](repeating: .infinity, count: total)
        var prev = [Int](repeating: -1, count: total)
        var prevKind = [UInt8](repeating: 0, count: total) // 0 graph, 1 virt
        var prevData = [Int](repeating: -1, count: total)
        var prevForward = [Bool](repeating: true, count: total)
        var pathMeters = [Double](repeating: .infinity, count: total)
        var slots = [UInt8](repeating: 0, count: total)
        var heap = MinHeap()

        // Preserve the arrival road tier across virtual snap stubs and
        // duplicate-node stitches. The toll belongs at the real transition,
        // not on every trunk/motorway edge.
        func predecessorGraphEdgeIndex(at node: Int) -> Int? {
            var cursor = node
            for _ in 0..<8 where cursor >= 0 && prev[cursor] >= 0 {
                if prevKind[cursor] == 0 { return prevData[cursor] }
                if prevKind[cursor] == 1 {
                    let id = prevData[cursor]
                    guard id >= 0, id < virt.count, virt[id].ei >= 0 else { return nil }
                    return virt[id].ei
                }
                guard prevKind[cursor] == 2 else { return nil }
                cursor = prev[cursor]
            }
            return nil
        }

        dist[startVirt] = 0
        pathMeters[startVirt] = 0
        heap.push(node: startVirt, cost: 0)

        let applyAway = ctx.costMode == .profile || ctx.costMode == .pavement
        // Clean uses toward-B gravity only — no chord XT.
        let applySoftCorridor = applyAway
            && profile != .cleanest
            && (ctx.costMode == .pavement || ctx.corridorMeters == nil)
        let isHunt = ctx.maxPathMeters != nil || ctx.boundedSearch
        var pops = 0
        var abort = "completed"
        let huntStart = CFAbsoluteTimeGetCurrent()
        let popCap = isHunt
            ? (ctx.popCap ?? HopSearchPolicy.pass2PopCap)
            : min(8_000_000, total * (HopSearchPolicy.varietySlots + 2) * 8)
        let deadline: Double? = isHunt
            ? huntStart + (ctx.timeCapSeconds ?? HopSearchPolicy.pass2TimeCapSeconds)
            : nil

        while let cur = heap.pop() {
            if Task.isCancelled || executionCancelled() { return .failure(.searchLimit("cancelled")) }
            if cur.cost != dist[cur.node] { continue }
            pops += 1
            if pops > popCap { abort = "popCap"; break }
            if let deadline, (pops & 255) == 0, CFAbsoluteTimeGetCurrent() > deadline {
                abort = "timeCap"
                break
            }
            if cur.node == endVirt { break }

            if cur.node < n {
                let arcStart = Int(pack.nodeOffsets[cur.node])
                let arcEnd = Int(pack.nodeOffsets[cur.node + 1])
                guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }

                for i in arcStart..<arcEnd {
                    if (i & 63) == 0, Task.isCancelled || executionCancelled() {
                        return .failure(.searchLimit("cancelled"))
                    }
                    let toNode = Int(pack.edgeTargets[i])
                    let ei = Int(pack.edgeUndirectedIndex[i])
                    guard ei >= 0, ei < pack.undirectedEdgeCount else { continue }
                    // find-path-v2: only suppress immediate U-turn on a prior *real*
                    // edge. Clean+leaves must not treat a mid-edge virt stub of `ei`
                    // as blocking the real traversal of `ei` (JS parity / E2 lockstep).
                    if ctx.noBacktrack {
                        if profile == .cleanest, pack.hasLeaves {
                            if prevKind[cur.node] == 0, prevData[cur.node] == ei { continue }
                        } else if isBacktrack(
                            prevKind: prevKind[cur.node], prevData: prevData[cur.node],
                            ei: ei, virt: virt
                        ) {
                            continue
                        }
                    }
                    if pack.v4HopIllegal(
                        ei: ei, from: cur.node, to: toNode,
                        startEi: startEi, endEi: endEi,
                        incomingEi: incomingUndirected(
                            prevKind: prevKind[cur.node],
                            prevData: prevData[cur.node],
                            virt: virt
                        )
                    ) { continue }
                    let attr = pack.edgeAttrs[ei]
                    let access = GraphV2Pack.unpackAccess(attr)
                    if !traversalAccessAllowed(ei: ei, from: cur.node, to: toNode, allowUnknown: policyUnknown, profile: profile) { continue }
                    if edgeBlockedByPavedOnly(ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }

                    let toLL = coordinate(forNode: toNode)
                    if hopBlocked(toLL, edgeFrom: coordinate(forNode: cur.node), from: from, to: to, ctx: ctx) {
                        continue
                    }

                    let edgeM = Double(pack.edgeMeters[ei])
                    let newMeters = pathMeters[cur.node] + edgeM
                    if exceedsLengthSlack(
                        newMeters: newMeters, toNode: toNode,
                        slackToDest: slackToDest, cap: ctx.maxPathMeters
                    ) { continue }

                    let surface = GraphV2Pack.unpackSurface(attr)
                    let roadClass = GraphV2Pack.unpackRoadClass(attr)
                    let confidence = GraphV2Pack.unpackConfidence(attr)
                    var step = hopCostStep(
                        meters: edgeM,
                        edgeIndex: ei,
                        surface: surface,
                        roadClass: roadClass,
                        access: access,
                        confidence: confidence,
                        profile: profile,
                        ctx: ctx,
                        toLL: toLL,
                        endLL: endLL,
                        abMeters: abMeters,
                        startSnap: startSnap,
                        startOnMajorHighway: startOnMajorHighway,
                        endOnMajorHighway: endOnMajorHighway,
                        policyUnknown: policyUnknown
                    )
                    step *= UrbanCore.fallbackMultiplier(
                        point: toLL,
                        start: from,
                        end: to,
                        boxes: packUrbanCores,
                        edgeFrom: coordinate(forNode: cur.node),
                        penalty: UrbanCore.resolveCleanMetroPenalty(
                            profile: profile,
                            override: ctx.cleanMetroMultiplier,
                            avoidMajorHighways: ctx.avoidMotorways
                        )
                    )
                    if ctx.settlementFallback {
                        step *= UrbanCore.settlementFallbackMultiplier(
                            point: toLL, start: from, end: to, boxes: settlementBoxes(for: profile),
                            penalty: UrbanCore.resolveSettlementPenalty(
                                profile: profile,
                                override: ctx.cleanMetroMultiplier,
                                avoidMajorHighways: ctx.avoidMotorways
                            )
                        )
                    }
                    if applyAway {
                        let away = awayExtra(fromNode: cur.node, toNode: toNode)
                        step += ctx.costMode == .pavement ? away * 10 : away
                        if applySoftCorridor {
                            step += OnDeviceProfileCosts.corridorCrossTrackExtra(
                                profile: profile,
                                point: toLL,
                                lineFrom: startSnap.projected,
                                lineTo: endLL,
                                edgeMeters: edgeM
                            )
                        }
                    }
                    step = backtrackPenalized(step, edgeID: eid, ctx: ctx)
                    let isFerry = GraphV2Pack.isFerryStructure(GraphV2Pack.unpackStructure(attr))
                    if !isFerry, profile == .cleanest, pack.hasLeaves, ctx.avoidMotorways,
                       let fromEI = predecessorGraphEdgeIndex(at: cur.node) {
                        step += RoadTierStats.e4MajorHighwayEntryCost(
                            fromTier: pack.roadTier(fromEI),
                            toTier: pack.roadTier(ei),
                            enabled: true,
                            metersFromStart: meters(toLL, startSnap.projected),
                            metersToDestination: meters(toLL, endLL),
                            startOnHighway: startOnMajorHighway,
                            endOnHighway: endOnMajorHighway
                        )
                    }
                    let cost = cur.cost + step
                    let newDirt = edgeIsDirt(ei)
                    let oldDirt = prevKind[toNode] == 0 ? edgeIsDirt(prevData[toNode]) : false
                    var action = HopSearchPolicy.considerRelax(
                        newCost: cost,
                        oldCost: dist[toNode],
                        newEi: ei,
                        oldEi: prevData[toNode],
                        node: toNode,
                        newIsDirt: newDirt,
                        oldIsDirt: oldDirt,
                        seed: ctx.sessionSeed,
                        variety: ctx.variety,
                        slotsUsed: Int(slots[toNode])
                    )
                    if action == .stealPred, HopSearchPolicy.createsCycle(prev: prev, from: cur.node, through: toNode) {
                        action = .reject
                    }
                    if HopSearchPolicy.apply(action, slots: &slots, at: toNode) {
                        prev[toNode] = cur.node
                        prevKind[toNode] = 0
                        prevData[toNode] = ei
                        if let fromArr = pack.edgeFrom {
                            prevForward[toNode] = Int(fromArr[ei]) == cur.node
                        } else {
                            prevForward[toNode] = true
                        }
                        if HopSearchPolicy.shouldPush(action) {
                            dist[toNode] = cost
                            pathMeters[toNode] = newMeters
                            heap.push(node: toNode, cost: cost)
                        }
                    }
                }
            }

            if cur.node < n, let sibs = coincidentSiblings[cur.node] {
                for toNode in sibs {
                    let cost = cur.cost
                    let newMeters = pathMeters[cur.node]
                    var action = HopSearchPolicy.considerRelax(
                        newCost: cost,
                        oldCost: dist[toNode],
                        newEi: -1,
                        oldEi: prevData[toNode],
                        node: toNode,
                        newIsDirt: false,
                        oldIsDirt: false,
                        seed: ctx.sessionSeed,
                        variety: false,
                        slotsUsed: Int(slots[toNode])
                    )
                    if action == .stealPred, HopSearchPolicy.createsCycle(prev: prev, from: cur.node, through: toNode) {
                        action = .reject
                    }
                    if HopSearchPolicy.apply(action, slots: &slots, at: toNode) {
                        prev[toNode] = cur.node
                        prevKind[toNode] = 2
                        prevData[toNode] = -1
                        prevForward[toNode] = true
                        if HopSearchPolicy.shouldPush(action) {
                            dist[toNode] = cost
                            pathMeters[toNode] = newMeters
                            heap.push(node: toNode, cost: cost)
                        }
                    }
                }
            }

            if let vlist = virtAdj[cur.node] {
                for item in vlist {
                    let v = virt[item.id]
                    if ctx.pavedOnly {
                        if v.junctionStitch { continue }
                        if v.ei >= 0,
                           edgeBlockedByPavedOnly(v.ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi) {
                            continue
                        }
                    }
                    // find-path-v2 does not U-turn-suppress virt expansions.
                    // Dirt/Balanced keep pre-E2 virt backtrack; Clean+leaves match JS.
                    if ctx.noBacktrack, v.ei >= 0,
                       !(profile == .cleanest && pack.hasLeaves),
                       isBacktrack(prevKind: prevKind[cur.node], prevData: prevData[cur.node], ei: v.ei, virt: virt) {
                        continue
                    }
                    let toLL: CLLocationCoordinate2D
                    if item.to == startVirt {
                        toLL = startSnap.projected
                    } else if item.to == endVirt {
                        toLL = endSnap.projected
                    } else if item.to < n {
                        toLL = coordinate(forNode: item.to)
                    } else {
                        toLL = endSnap.projected
                    }
                    let edgeFrom = cur.node < n
                        ? coordinate(forNode: cur.node)
                        : (cur.node == startVirt ? startSnap.projected : endSnap.projected)
                    if hopBlocked(toLL, edgeFrom: edgeFrom, from: from, to: to, ctx: ctx) {
                        continue
                    }
                    let newMeters = pathMeters[cur.node] + v.meters
                    if exceedsLengthSlack(
                        newMeters: newMeters, toNode: item.to,
                        slackToDest: slackToDest, cap: ctx.maxPathMeters
                    ) { continue }
                    var step = v.meters / 1000.0
                    if v.junctionStitch { step *= Self.junctionStitchCostPremium }
                    step *= UrbanCore.fallbackMultiplier(
                        point: toLL,
                        start: from,
                        end: to,
                        boxes: packUrbanCores,
                        edgeFrom: edgeFrom,
                        penalty: UrbanCore.resolveCleanMetroPenalty(
                            profile: profile,
                            override: ctx.cleanMetroMultiplier,
                            avoidMajorHighways: ctx.avoidMotorways
                        )
                    )
                    if ctx.settlementFallback {
                        step *= UrbanCore.settlementFallbackMultiplier(
                            point: toLL, start: from, end: to, boxes: settlementBoxes(for: profile),
                            penalty: UrbanCore.resolveSettlementPenalty(
                                profile: profile,
                                override: ctx.cleanMetroMultiplier,
                                avoidMajorHighways: ctx.avoidMotorways
                            )
                        )
                    }
                    if applyAway {
                        let away = awayExtra(fromNode: cur.node, toNode: item.to)
                        step += ctx.costMode == .pavement ? away * 10 : away
                        if applySoftCorridor {
                            step += OnDeviceProfileCosts.corridorCrossTrackExtra(
                                profile: profile,
                                point: toLL,
                                lineFrom: startSnap.projected,
                                lineTo: endLL,
                                edgeMeters: v.meters
                            )
                        }
                    }
                    let virtualEdgeID = v.junctionStitch
                        ? v.stitchEdgeId
                        : (v.ei >= 0 ? pack.edgeId(v.ei) : "")
                    step = backtrackPenalized(step, edgeID: virtualEdgeID, ctx: ctx)
                    let cost = cur.cost + step
                    var action = HopSearchPolicy.considerRelax(
                        newCost: cost,
                        oldCost: dist[item.to],
                        newEi: v.ei,
                        oldEi: prevData[item.to],
                        node: item.to,
                        newIsDirt: false,
                        oldIsDirt: false,
                        seed: ctx.sessionSeed,
                        variety: ctx.variety,
                        slotsUsed: Int(slots[item.to])
                    )
                    if action == .stealPred, HopSearchPolicy.createsCycle(prev: prev, from: cur.node, through: item.to) {
                        action = .reject
                    }
                    if HopSearchPolicy.apply(action, slots: &slots, at: item.to) {
                        prev[item.to] = cur.node
                        prevKind[item.to] = 1
                        prevData[item.to] = item.id
                        prevForward[item.to] = item.forward
                        if HopSearchPolicy.shouldPush(action) {
                            dist[item.to] = cost
                            pathMeters[item.to] = newMeters
                            heap.push(node: item.to, cost: cost)
                        }
                    }
                }
            }
        }

        guard dist[endVirt].isFinite else {
            return .failure(abort == "completed" ? .noPath : .searchLimit(abort))
        }

        var legs: [Leg] = []
        var node = endVirt
        var hops = 0
        while node != startVirt {
            hops += 1
            if hops > total + 4 { return .failure(.noPath) }
            let parent = prev[node]
            guard parent >= 0 else { return .failure(.noPath) }
            if prevKind[node] == 1 {
                let v = virt[prevData[node]]
                let forward = prevForward[node]
                let coords = forward ? v.coords : Array(v.coords.reversed())
                let surface: String
                let id: String
                if v.junctionStitch {
                    surface = v.stitchSurface
                    id = v.stitchEdgeId
                } else {
                    surface = OnDeviceProfileCosts.surfaceName(
                        code: GraphV2Pack.unpackSurface(pack.edgeAttrs[v.ei])
                    )
                    id = pack.edgeId(v.ei)
                }
                if coords.count >= 2, v.meters > 0.5 {
                    legs.append(Leg(
                        coordinates: coords,
                        distanceMeters: v.meters,
                        surfaceName: surface,
                        edgeId: id,
                        accessName: v.junctionStitch ? "motorized_permissive" : accessNameForEdge(v.ei),
                        roadClassName: v.junctionStitch ? "unknown" : roadClassNameForEdge(v.ei),
                        surfaceLeaf: v.junctionStitch || !pack.hasLeaves ? nil : pack.surfaceLeaf(v.ei),
                        structureType: v.junctionStitch ? nil : structureTypeForEdge(v.ei),
                        structureLeaf: v.junctionStitch ? nil : structureLeafForEdge(v.ei),
                        layer: v.junctionStitch ? 0 : layerForEdge(v.ei),
                        crossingLabel: v.junctionStitch ? nil : crossingLabelForEdge(v.ei),
                        waterCrossing: v.junctionStitch ? false : waterCrossingForEdge(v.ei)
                    ))
                }
            } else if prevKind[node] == 2 {
                // Coincident duplicate-node stitch — no geometry.
            } else {
                let ei = prevData[node]
                let aNode = parent
                let bNode = node
                let a = coordinate(forNode: aNode)
                let b = coordinate(forNode: bNode)
                let m = Double(pack.edgeMeters[ei])
                let surface = OnDeviceProfileCosts.surfaceName(
                    code: GraphV2Pack.unpackSurface(pack.edgeAttrs[ei])
                )
                let id = pack.edgeId(ei)
                let shape = edgePolyline(ei: ei, fromNode: aNode, toNode: bNode, fallback: [a, b])
                legs.append(Leg(
                    coordinates: shape,
                    distanceMeters: m,
                    surfaceName: surface,
                    edgeId: id,
                    accessName: accessNameForEdge(ei),
                    roadClassName: roadClassNameForEdge(ei),
                    surfaceLeaf: pack.hasLeaves ? pack.surfaceLeaf(ei) : nil,
                    structureType: structureTypeForEdge(ei),
                    structureLeaf: structureLeafForEdge(ei),
                    layer: layerForEdge(ei),
                    crossingLabel: crossingLabelForEdge(ei),
                    waterCrossing: waterCrossingForEdge(ei),
                    edgeIndex: ei,
                    fromNode: aNode,
                    toNode: bNode
                ))
            }
            node = parent
        }
        legs.reverse()

        // Soft-stitch tap→projection stubs (connector / access surface).
        if let stub = softStitchStub(tap: from, snap: startSnap, idSuffix: "start") {
            legs.insert(stub, at: 0)
        }
        if let stub = softStitchStub(tap: to, snap: endSnap, idSuffix: "end") {
            legs.append(stub)
        }

        let fallback = [startSnap.projected, endSnap.projected]
        return .success(stampHunt(
            finalize(
                legs: legs,
                nodeFallback: fallback,
                profile: profile,
                allowUnknown: policyUnknown,
                fastFuelPrune: ctx.fastSearch
            ),
            pops: pops, abort: abort, started: huntStart, isHunt: isHunt
        ))
    }

    private func searchVirtualBalanced(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        startSnap: EdgeSnap,
        endSnap: EdgeSnap,
        startVirt: Int,
        endVirt: Int,
        nodeCount n: Int,
        virt: [VirtEdge],
        virtAdj: [Int: [(to: Int, id: Int, forward: Bool)]],
        profile: RouteProfile,
        policyUnknown: Bool,
        avoidEdgeIds: Set<String>,
        ctx: HopSearchContext,
        slackToDest: [Double]?,
        coincidentSiblings: [[Int]?]
    ) -> Swift.Result<Result, Failure> {
        let startEi = startSnap.edgeIndex
        let endEi = endSnap.edgeIndex
        let endLL = endSnap.projected
        let abMeters = meters(startSnap.projected, endLL)
        let startOnMajorHighway = snapIsMajorHighwayPin(startSnap, profile: profile)
        let endOnMajorHighway = snapIsMajorHighwayPin(endSnap, profile: profile)
        let B = HopSearchPolicy.balancedBuckets
        let totalNodes = n + 2
        let labels = totalNodes * B
        func lab(_ node: Int, _ bucket: Int) -> Int { node * B + bucket }
        func nid(_ label: Int) -> Int { label / B }

        var dist = [Double](repeating: .infinity, count: labels)
        var pathMeters = [Double](repeating: .infinity, count: labels)
        var dirtAt = [Double](repeating: 0, count: labels)
        var prev = [Int](repeating: -1, count: labels)
        var prevKind = [UInt8](repeating: 0, count: labels)
        var prevData = [Int](repeating: -1, count: labels)
        var prevForward = [Bool](repeating: true, count: labels)
        var slots = [UInt8](repeating: 0, count: labels)
        var heap = MinHeap()
        let startLab = lab(startVirt, 0)
        dist[startLab] = 0
        pathMeters[startLab] = 0
        heap.push(node: startLab, cost: 0)

        let cap = ctx.maxPathMeters ?? .infinity
        var pops = 0
        var abort = "completed"
        let isHunt = ctx.maxPathMeters != nil || ctx.boundedSearch
        let huntStart = CFAbsoluteTimeGetCurrent()
        let popCap = isHunt ? (ctx.popCap ?? HopSearchPolicy.pass2PopCap) : 8_000_000
        let deadline: Double? = isHunt
            ? huntStart + (ctx.timeCapSeconds ?? HopSearchPolicy.pass2TimeCapSeconds)
            : nil

        while let cur = heap.pop() {
            if Task.isCancelled || executionCancelled() { return .failure(.searchLimit("cancelled")) }
            pops += 1
            if pops > popCap { abort = "popCap"; break }
            if let deadline, (pops & 255) == 0, CFAbsoluteTimeGetCurrent() > deadline {
                abort = "timeCap"
                break
            }
            if cur.cost != dist[cur.node] { continue }
            let metersSoFar = pathMeters[cur.node]
            if metersSoFar > cap { continue }
            let node = nid(cur.node)
            let dirtSoFar = dirtAt[cur.node]

            if node < n {
                let arcStart = Int(pack.nodeOffsets[node])
                let arcEnd = Int(pack.nodeOffsets[node + 1])
                guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
                for i in arcStart..<arcEnd {
                    if (i & 63) == 0, Task.isCancelled || executionCancelled() {
                        return .failure(.searchLimit("cancelled"))
                    }
                    let toNode = Int(pack.edgeTargets[i])
                    let ei = Int(pack.edgeUndirectedIndex[i])
                    guard ei >= 0, ei < pack.undirectedEdgeCount else { continue }
                    if ctx.noBacktrack,
                       isBacktrack(prevKind: prevKind[cur.node], prevData: prevData[cur.node], ei: ei, virt: virt) {
                        continue
                    }
                    if pack.v4HopIllegal(
                        ei: ei, from: node, to: toNode,
                        startEi: startEi, endEi: endEi,
                        incomingEi: incomingUndirected(
                            prevKind: prevKind[cur.node],
                            prevData: prevData[cur.node],
                            virt: virt
                        )
                    ) { continue }
                    let attr = pack.edgeAttrs[ei]
                    let access = GraphV2Pack.unpackAccess(attr)
                    if !traversalAccessAllowed(ei: ei, from: cur.node, to: toNode, allowUnknown: policyUnknown, profile: profile) { continue }
                    if edgeBlockedByPavedOnly(ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
                    let toLL = coordinate(forNode: toNode)
                    if hopBlocked(toLL, edgeFrom: coordinate(forNode: node), from: from, to: to, ctx: ctx) { continue }
                    let edgeM = Double(pack.edgeMeters[ei])
                    let newMeters = metersSoFar + edgeM
                    if exceedsLengthSlack(
                        newMeters: newMeters, toNode: toNode,
                        slackToDest: slackToDest, cap: cap
                    ) { continue }
                    let shortDirtPenalized = profile == .dirt
                        && ctx.shortDirtPenaltyEdgeIds.contains(eid)
                    let addDirt = GraphV2Pack.isFerryStructure(GraphV2Pack.unpackStructure(attr))
                        || shortDirtPenalized
                        ? 0
                        : (edgeIsDirt(ei) ? edgeM : 0)
                    let newDirt = dirtSoFar + addDirt
                    let b = HopSearchPolicy.dirtBucket(dirtMeters: newDirt, pathMeters: newMeters)
                    let toLab = lab(toNode, b)
                    let settlementMult = ctx.settlementFallback
                        ? UrbanCore.settlementFallbackMultiplier(
                            point: toLL, start: from, end: to, boxes: settlementBoxes(for: profile),
                            penalty: UrbanCore.resolveSettlementPenalty(
                                profile: profile,
                                override: ctx.cleanMetroMultiplier,
                                avoidMajorHighways: ctx.avoidMotorways
                            )
                        )
                        : 1
                    let urbanMult = UrbanCore.fallbackMultiplier(
                        point: toLL,
                        start: from,
                        end: to,
                        boxes: packUrbanCores,
                        edgeFrom: coordinate(forNode: node),
                        penalty: UrbanCore.resolveCleanMetroPenalty(
                            profile: profile,
                            override: ctx.cleanMetroMultiplier,
                            avoidMajorHighways: ctx.avoidMotorways
                        )
                    )
                    let isFerry = GraphV2Pack.isFerryStructure(GraphV2Pack.unpackStructure(attr))
                    var step = hopCostStep(
                        meters: edgeM,
                        edgeIndex: ei,
                        surface: GraphV2Pack.unpackSurface(attr),
                        roadClass: GraphV2Pack.unpackRoadClass(attr),
                        access: access,
                        confidence: GraphV2Pack.unpackConfidence(attr),
                        profile: profile,
                        ctx: ctx,
                        toLL: toLL,
                        endLL: endLL,
                        abMeters: abMeters,
                        startSnap: startSnap,
                        startOnMajorHighway: startOnMajorHighway,
                        endOnMajorHighway: endOnMajorHighway,
                        policyUnknown: policyUnknown
                    )
                    if shortDirtPenalized {
                        step *= HopSearchPolicy.dirtRidePavedPerKm
                    }
                    if !isFerry {
                        step *= settlementMult * urbanMult
                    }
                    let newScore = cur.cost + backtrackPenalized(
                        step,
                        edgeID: pack.edgeId(ei),
                        ctx: ctx
                    )
                    var action = HopSearchPolicy.considerRelax(
                        newCost: newScore,
                        oldCost: dist[toLab],
                        newEi: ei,
                        oldEi: prevData[toLab],
                        node: toNode,
                        newIsDirt: addDirt > 0,
                        oldIsDirt: dirtAt[toLab] > (pathMeters[toLab].isFinite ? pathMeters[toLab] * 0.4 : 0),
                        seed: ctx.sessionSeed,
                        variety: ctx.variety,
                        slotsUsed: Int(slots[toLab])
                    )
                    if action == .stealPred, HopSearchPolicy.createsCycle(prev: prev, from: cur.node, through: toLab) {
                        action = .reject
                    }
                    if HopSearchPolicy.apply(action, slots: &slots, at: toLab) {
                        prev[toLab] = cur.node
                        prevKind[toLab] = 0
                        prevData[toLab] = ei
                        prevForward[toLab] = true
                        if HopSearchPolicy.shouldPush(action) {
                            dist[toLab] = newScore
                            pathMeters[toLab] = newMeters
                            dirtAt[toLab] = newDirt
                            heap.push(node: toLab, cost: newScore)
                        }
                    }
                }
                if let siblings = coincidentSiblings[node] {
                    for toNode in siblings {
                        let bucket = HopSearchPolicy.dirtBucket(
                            dirtMeters: dirtSoFar,
                            pathMeters: metersSoFar
                        )
                        let toLab = lab(toNode, bucket)
                        if cur.cost < dist[toLab] {
                            dist[toLab] = cur.cost
                            pathMeters[toLab] = metersSoFar
                            dirtAt[toLab] = dirtSoFar
                            prev[toLab] = cur.node
                            prevKind[toLab] = 2
                            prevData[toLab] = -1
                            prevForward[toLab] = true
                            heap.push(node: toLab, cost: cur.cost)
                        }
                    }
                }
            }

            if let vlist = virtAdj[node] {
                for item in vlist {
                    let v = virt[item.id]
                    if ctx.pavedOnly {
                        if v.junctionStitch { continue }
                        if v.ei >= 0,
                           edgeBlockedByPavedOnly(v.ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi) {
                            continue
                        }
                    }
                    let newMeters = metersSoFar + v.meters
                    if exceedsLengthSlack(
                        newMeters: newMeters, toNode: item.to,
                        slackToDest: slackToDest, cap: cap
                    ) { continue }
                    let edgeFrom = node < n
                        ? coordinate(forNode: node)
                        : (node == startVirt ? startSnap.projected : endSnap.projected)
                    if ctx.cityWall, item.to < n {
                        let blockedLL = coordinate(forNode: item.to)
                        if hopBlocked(blockedLL, edgeFrom: edgeFrom, from: from, to: to, ctx: ctx) { continue }
                    }
                    let b = HopSearchPolicy.dirtBucket(dirtMeters: dirtSoFar, pathMeters: newMeters)
                    let toLab = lab(item.to, b)
                    let toLL = item.to < n ? coordinate(forNode: item.to) : endSnap.projected
                    let settlementMult = ctx.settlementFallback
                        ? UrbanCore.settlementFallbackMultiplier(
                            point: toLL, start: from, end: to, boxes: settlementBoxes(for: profile),
                            penalty: UrbanCore.resolveSettlementPenalty(
                                profile: profile,
                                override: ctx.cleanMetroMultiplier,
                                avoidMajorHighways: ctx.avoidMotorways
                            )
                        )
                        : 1
                    let urbanMult = UrbanCore.fallbackMultiplier(
                        point: toLL,
                        start: from,
                        end: to,
                        boxes: packUrbanCores,
                        edgeFrom: edgeFrom,
                        penalty: UrbanCore.resolveCleanMetroPenalty(
                            profile: profile,
                            override: ctx.cleanMetroMultiplier,
                            avoidMajorHighways: ctx.avoidMotorways
                        )
                    )
                    let virtualEdgeID = v.junctionStitch
                        ? v.stitchEdgeId
                        : (v.ei >= 0 ? pack.edgeId(v.ei) : "")
                    let shortDirtPenalized = profile == .dirt
                        && ctx.shortDirtPenaltyEdgeIds.contains(virtualEdgeID)
                    let virtualStep = v.meters * settlementMult * urbanMult
                        * (shortDirtPenalized ? HopSearchPolicy.dirtRidePavedPerKm : 1)
                    let newScore = cur.cost + backtrackPenalized(
                        virtualStep,
                        edgeID: virtualEdgeID,
                        ctx: ctx
                    )
                    if newScore < dist[toLab] {
                        dist[toLab] = newScore
                        pathMeters[toLab] = newMeters
                        dirtAt[toLab] = dirtSoFar
                        prev[toLab] = cur.node
                        prevKind[toLab] = 1
                        prevData[toLab] = item.id
                        prevForward[toLab] = item.forward
                        heap.push(node: toLab, cost: newScore)
                    }
                }
            }
        }

        var labelsAtEnd: [(lab: Int, len: Double, dirt: Double, score: Double)] = []
        for b in 0..<B {
            let endLab = lab(endVirt, b)
            let len = pathMeters[endLab]
            guard len.isFinite, len > 0 else { continue }
            labelsAtEnd.append((endLab, len, dirtAt[endLab], dist[endLab]))
        }
        let inBand = profile == .balanced ? labelsAtEnd.filter {
            let ratio = $0.len > 0 ? $0.dirt / $0.len : 0
            return ratio >= HopSearchPolicy.balancedDirtLo && ratio <= HopSearchPolicy.balancedDirtHi
        } : []
        let candidatePool = profile == .balanced && !inBand.isEmpty ? inBand : labelsAtEnd
        let bestLab = candidatePool.min { a, b in
            let ratioA = a.len > 0 ? a.dirt / a.len : 0
            let ratioB = b.len > 0 ? b.dirt / b.len : 0
            if profile == .dirt, abs(ratioA - ratioB) > 0.005 {
                return ratioA > ratioB
            }
            let targetA = abs(ratioA - 0.5)
            let targetB = abs(ratioB - 0.5)
            if profile == .balanced, abs(targetA - targetB) > 0.005 { return targetA < targetB }
            if profile == .dirt {
                let pavedA = a.len - a.dirt
                let pavedB = b.len - b.dirt
                if abs(pavedA - pavedB) > 50 { return pavedA < pavedB }
            }
            if abs(a.score - b.score) > 50 { return a.score < b.score }
            return a.len < b.len
        }?.lab
        guard let bestLab,
              dist[bestLab].isFinite else {
            return .failure(abort == "completed" ? .noPath : .searchLimit(abort))
        }

        var legs: [Leg] = []
        var label = bestLab
        var hops = 0
        while nid(label) != startVirt {
            hops += 1
            if hops > labels + 4 { return .failure(.noPath) }
            let parent = prev[label]
            guard parent >= 0 else { return .failure(.noPath) }
            if prevKind[label] == 1 {
                let v = virt[prevData[label]]
                let forward = prevForward[label]
                let coords = forward ? v.coords : Array(v.coords.reversed())
                let surface: String
                let id: String
                if v.junctionStitch {
                    surface = v.stitchSurface
                    id = v.stitchEdgeId
                } else {
                    surface = OnDeviceProfileCosts.surfaceName(
                        code: GraphV2Pack.unpackSurface(pack.edgeAttrs[v.ei])
                    )
                    id = pack.edgeId(v.ei)
                }
                if coords.count >= 2, v.meters > 0.5 {
                    legs.append(Leg(
                        coordinates: coords,
                        distanceMeters: v.meters,
                        surfaceName: surface,
                        edgeId: id,
                        accessName: v.junctionStitch ? "motorized_permissive" : accessNameForEdge(v.ei),
                        roadClassName: v.junctionStitch ? "unknown" : roadClassNameForEdge(v.ei),
                        surfaceLeaf: v.junctionStitch || !pack.hasLeaves ? nil : pack.surfaceLeaf(v.ei),
                        structureType: v.junctionStitch ? nil : structureTypeForEdge(v.ei),
                        structureLeaf: v.junctionStitch ? nil : structureLeafForEdge(v.ei),
                        layer: v.junctionStitch ? 0 : layerForEdge(v.ei),
                        crossingLabel: v.junctionStitch ? nil : crossingLabelForEdge(v.ei),
                        waterCrossing: v.junctionStitch ? false : waterCrossingForEdge(v.ei)
                    ))
                }
            } else if prevKind[label] == 2 {
                // Coincident duplicate-node stitch — no geometry.
            } else {
                let ei = prevData[label]
                let aNode = nid(parent)
                let bNode = nid(label)
                guard aNode < n, bNode < n, ei >= 0 else {
                    label = parent
                    continue
                }
                let a = coordinate(forNode: aNode)
                let b = coordinate(forNode: bNode)
                let m = Double(pack.edgeMeters[ei])
                let surface = OnDeviceProfileCosts.surfaceName(
                    code: GraphV2Pack.unpackSurface(pack.edgeAttrs[ei])
                )
                let id = pack.edgeId(ei)
                let shape = edgePolyline(ei: ei, fromNode: aNode, toNode: bNode, fallback: [a, b])
                legs.append(Leg(
                    coordinates: shape,
                    distanceMeters: m,
                    surfaceName: surface,
                    edgeId: id,
                    accessName: accessNameForEdge(ei),
                    roadClassName: roadClassNameForEdge(ei),
                    surfaceLeaf: pack.hasLeaves ? pack.surfaceLeaf(ei) : nil,
                    structureType: structureTypeForEdge(ei),
                    structureLeaf: structureLeafForEdge(ei),
                    layer: layerForEdge(ei),
                    crossingLabel: crossingLabelForEdge(ei),
                    waterCrossing: waterCrossingForEdge(ei),
                    edgeIndex: ei,
                    fromNode: aNode,
                    toNode: bNode
                ))
            }
            label = parent
        }
        legs.reverse()
        if let stub = softStitchStub(tap: from, snap: startSnap, idSuffix: "start") {
            legs.insert(stub, at: 0)
        }
        if let stub = softStitchStub(tap: to, snap: endSnap, idSuffix: "end") {
            legs.append(stub)
        }
        return .success(stampHunt(
            finalize(
                legs: legs,
                nodeFallback: [startSnap.projected, endSnap.projected],
                profile: profile,
                allowUnknown: policyUnknown,
                fastFuelPrune: ctx.fastSearch
            ),
            pops: pops, abort: abort, started: huntStart, isHunt: isHunt
        ))
    }

    /// Reverse shortest-path distances from `origin` (usually dest). Pass 2 only
    /// expands nodes that can still finish under the extra-km cap — without this
    /// the profile-cost heap explores the whole L+extra ball (~8M pops, ~2 min).
    private func fillShortestMeters(
        from origin: Int,
        capMeters: Double,
        nodeCount n: Int,
        total: Int,
        virt: [VirtEdge],
        virtAdj: [Int: [(to: Int, id: Int, forward: Bool)]],
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        ctx: HopSearchContext,
        profile: RouteProfile,
        policyUnknown: Bool,
        avoidEdgeIds: Set<String>,
        coincidentSiblings: [[Int]?]
    ) -> [Double] {
        var dist = [Double](repeating: .infinity, count: total)
        var heap = MinHeap()
        // CSR stores directed arcs. A lower bound from node -> destination must
        // traverse the transpose graph; walking destination's outgoing arcs
        // incorrectly prunes legal paths across one-way roads.
        let arcCount = pack.edgeTargets.count
        var incomingCounts = [Int](repeating: 0, count: n)
        for targetRaw in pack.edgeTargets {
            let target = Int(targetRaw)
            if target >= 0, target < n { incomingCounts[target] += 1 }
        }
        var incomingOffsets = [Int](repeating: 0, count: n + 1)
        for node in 0..<n { incomingOffsets[node + 1] = incomingOffsets[node] + incomingCounts[node] }
        var incomingSources = [Int32](repeating: 0, count: arcCount)
        var incomingEdges = [Int32](repeating: 0, count: arcCount)
        var cursors = incomingOffsets
        for source in 0..<n {
            let arcStart = Int(pack.nodeOffsets[source])
            let arcEnd = Int(pack.nodeOffsets[source + 1])
            guard arcStart >= 0, arcEnd <= arcCount else { continue }
            for i in arcStart..<arcEnd {
                let target = Int(pack.edgeTargets[i])
                guard target >= 0, target < n else { continue }
                let slot = cursors[target]
                incomingSources[slot] = Int32(source)
                incomingEdges[slot] = pack.edgeUndirectedIndex[i]
                cursors[target] += 1
            }
        }
        dist[origin] = 0
        heap.push(node: origin, cost: 0)
        while let cur = heap.pop() {
            if Task.isCancelled { return [] }
            if cur.cost != dist[cur.node] { continue }
            if cur.cost > capMeters { continue }
            if cur.node < n {
                let arcStart = incomingOffsets[cur.node]
                let arcEnd = incomingOffsets[cur.node + 1]
                for i in arcStart..<arcEnd {
                    let toNode = Int(incomingSources[i])
                    let ei = Int(incomingEdges[i])
                    guard ei >= 0, ei < pack.undirectedEdgeCount else { continue }
                    let attr = pack.edgeAttrs[ei]
                    let access = GraphV2Pack.unpackAccess(attr)
                    if !traversalAccessAllowed(ei: ei, from: toNode, to: cur.node, allowUnknown: policyUnknown, profile: profile) { continue }
                    if edgeBlockedByPavedOnly(ei, ctx: ctx) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
                    let toLL = coordinate(forNode: toNode)
                    if hopBlocked(toLL, edgeFrom: coordinate(forNode: cur.node), from: from, to: to, ctx: ctx) { continue }
                    let edgeM = Double(pack.edgeMeters[ei])
                    let cand = cur.cost + edgeM
                    if cand > capMeters { continue }
                    if cand < dist[toNode] {
                        dist[toNode] = cand
                        heap.push(node: toNode, cost: cand)
                    }
                }
                if let siblings = coincidentSiblings[cur.node] {
                    for toNode in siblings where cur.cost < dist[toNode] {
                        dist[toNode] = cur.cost
                        heap.push(node: toNode, cost: cur.cost)
                    }
                }
            }
            if let vlist = virtAdj[cur.node] {
                for item in vlist {
                    let v = virt[item.id]
                    if ctx.pavedOnly {
                        if v.junctionStitch || (v.ei >= 0 && edgeBlockedForCleanPavement(v.ei)) { continue }
                    }
                    let edgeFrom = cur.node < n
                        ? coordinate(forNode: cur.node)
                        : (cur.node == origin ? to : from)
                    if hopBlocked(
                        item.to < n ? coordinate(forNode: item.to) : (item.to == origin ? to : from),
                        edgeFrom: edgeFrom, from: from, to: to, ctx: ctx
                    ) { continue }
                    let cand = cur.cost + v.meters
                    if cand > capMeters { continue }
                    if cand < dist[item.to] {
                        dist[item.to] = cand
                        heap.push(node: item.to, cost: cand)
                    }
                }
            }
        }
        return dist
    }

    private func exceedsLengthSlack(
        newMeters: Double,
        toNode: Int,
        slackToDest: [Double]?,
        cap: Double?
    ) -> Bool {
        if let cap, newMeters > cap { return true }
        guard let slack = slackToDest, let cap, toNode >= 0, toNode < slack.count else {
            return false
        }
        let rem = slack[toNode]
        if !rem.isFinite { return true }
        return newMeters + rem > cap + 1
    }

    private func stampHunt(
        _ result: Result,
        pops: Int,
        abort: String,
        started: CFAbsoluteTime,
        isHunt: Bool
    ) -> Result {
        guard isHunt else { return result }
        var out = result
        out.searchMeta.pops = pops
        out.searchMeta.pass2Outcome = abort
        out.searchMeta.timedOut = abort == "timeCap" || abort == "popCap"
        out.searchMeta.elapsedMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        return out
    }

    /// Live `router.js` fabric repairs: permissive tip joins (Allow OFF) and
    /// unknown-island → through-giant stitches (Allow ON). Corridor-scoped.
    private func junctionStitches(
        near start: CLLocationCoordinate2D,
        and end: CLLocationCoordinate2D,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: Set<String>
    ) -> [JunctionStitch] {
        let policyUnknown = allowUnknown && profile != .cleanest
        if policyUnknown {
            return unknownIslandStitches(
                near: start, and: end, profile: profile, avoidEdgeIds: avoidEdgeIds
            )
        }
        return permissiveJunctionStitches(
            near: start, and: end, profile: profile, avoidEdgeIds: avoidEdgeIds
        )
    }

    /// Allow OFF: join permissive dead-end tips to nearest eligible node ≤ 40 m.
    private func permissiveJunctionStitches(
        near start: CLLocationCoordinate2D,
        and end: CLLocationCoordinate2D,
        profile: RouteProfile,
        avoidEdgeIds: Set<String>
    ) -> [JunctionStitch] {
        let joinM = Self.permissiveJoinMeters
        let ab = meters(start, end)
        let padDeg = max(0.04, (ab / 111_320.0) * 0.35)
        let minLon = min(start.longitude, end.longitude) - padDeg
        let maxLon = max(start.longitude, end.longitude) + padDeg
        let minLat = min(start.latitude, end.latitude) - padDeg
        let maxLat = max(start.latitude, end.latitude) + padDeg
        let cell = 0.0005
        // JOIN_M 150 m needs ~3-ring; ±1 only covered ~110 m.
        let cellRing = max(1, Int(ceil(joinM / 55.0)) + 1)

        let n = pack.nodeCount
        guard let fromArr = pack.edgeFrom, let toArr = pack.edgeTo else { return [] }

        var degree = [Int](repeating: 0, count: n)
        for ei in 0..<pack.undirectedEdgeCount {
            let access = GraphV2Pack.unpackAccess(pack.edgeAttrs[ei])
            guard accessAllowed(access, allowUnknown: false, profile: profile) else { continue }
            let eid = pack.edgeId(ei)
            if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
            let a = Int(fromArr[ei])
            let b = Int(toArr[ei])
            guard a >= 0, b >= 0, a < n, b < n else { continue }
            degree[a] += 1
            degree[b] += 1
        }

        var grid: [String: [Int]] = [:]
        var eligibleSeen = Set<Int>()
        var tips: [Int] = []
        var undirectedAdj = [Set<Int>](repeating: [], count: n)
        for ei in 0..<pack.undirectedEdgeCount {
            let a = Int(fromArr[ei])
            let b = Int(toArr[ei])
            guard a >= 0, b >= 0, a < n, b < n else { continue }
            undirectedAdj[a].insert(b)
            undirectedAdj[b].insert(a)
        }

        func gridKey(_ lon: Double, _ lat: Double) -> String {
            "\(Int(floor(lon / cell))):\(Int(floor(lat / cell)))"
        }

        for ei in 0..<pack.undirectedEdgeCount {
            let access = GraphV2Pack.unpackAccess(pack.edgeAttrs[ei])
            guard accessAllowed(access, allowUnknown: false, profile: profile) else { continue }
            let eid = pack.edgeId(ei)
            if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
            for nodeId in [Int(fromArr[ei]), Int(toArr[ei])] {
                guard nodeId >= 0, nodeId < n, !eligibleSeen.contains(nodeId) else { continue }
                let ll = coordinate(forNode: nodeId)
                guard ll.longitude >= minLon, ll.longitude <= maxLon,
                      ll.latitude >= minLat, ll.latitude <= maxLat else { continue }
                eligibleSeen.insert(nodeId)
                let key = gridKey(ll.longitude, ll.latitude)
                grid[key, default: []].append(nodeId)
                if degree[nodeId] == 1 { tips.append(nodeId) }
            }
        }

        tips.sort { a, b in
            let la = coordinate(forNode: a)
            let lb = coordinate(forNode: b)
            let da = min(meters(la, start), meters(la, end))
            let db = min(meters(lb, start), meters(lb, end))
            return da < db
        }

        var out: [JunctionStitch] = []
        var seen = Set<String>()
        for tip in tips {
            if out.count >= Self.maxPermissiveStitches { break }
            let ll = coordinate(forNode: tip)
            let direct = undirectedAdj[tip]
            let cx = Int(floor(ll.longitude / cell))
            let cy = Int(floor(ll.latitude / cell))
            var best: Int?
            var bestD = joinM + 1
            for dx in -cellRing...cellRing {
                for dy in -cellRing...cellRing {
                    let key = "\(cx + dx):\(cy + dy)"
                    for cand in grid[key] ?? [] {
                        if cand == tip || direct.contains(cand) { continue }
                        let d = meters(ll, coordinate(forNode: cand))
                        if d < bestD {
                            bestD = d
                            best = cand
                        }
                    }
                }
            }
            guard let best, bestD <= joinM else { continue }
            let a = min(tip, best)
            let b = max(tip, best)
            let key = "\(a):\(b)"
            guard seen.insert(key).inserted else { continue }
            out.append(JunctionStitch(
                a: tip,
                b: best,
                meters: max(1, bestD),
                edgeId: "perm-stitch-\(key)"
            ))
        }
        return out
    }

    /// Allow ON: stitch motorized_unknown island nodes to through-giant (deg ≥ 2) ≤ 100 m.
    private func unknownIslandStitches(
        near start: CLLocationCoordinate2D,
        and end: CLLocationCoordinate2D,
        profile: RouteProfile,
        avoidEdgeIds: Set<String>
    ) -> [JunctionStitch] {
        let stitchM = Self.unknownIslandStitchMeters
        let ab = meters(start, end)
        let padDeg = max(0.04, (ab / 111_320.0) * 0.35)
        let minLon = min(start.longitude, end.longitude) - padDeg
        let maxLon = max(start.longitude, end.longitude) + padDeg
        let minLat = min(start.latitude, end.latitude) - padDeg
        let maxLat = max(start.latitude, end.latitude) + padDeg
        let cell = 0.0005

        let n = pack.nodeCount
        guard let fromArr = pack.edgeFrom, let toArr = pack.edgeTo else { return [] }

        var degree = [Int](repeating: 0, count: n)
        for ei in 0..<pack.undirectedEdgeCount {
            let access = GraphV2Pack.unpackAccess(pack.edgeAttrs[ei])
            guard accessAllowed(access, allowUnknown: true, profile: profile) else { continue }
            let eid = pack.edgeId(ei)
            if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
            let a = Int(fromArr[ei])
            let b = Int(toArr[ei])
            guard a >= 0, b >= 0, a < n, b < n else { continue }
            degree[a] += 1
            degree[b] += 1
        }

        var giantGrid: [String: [Int]] = [:]
        var islandNodes = Set<Int>()

        func gridKey(_ lon: Double, _ lat: Double) -> String {
            "\(Int(floor(lon / cell))):\(Int(floor(lat / cell)))"
        }
        func rememberGiant(_ node: Int) {
            guard degree[node] >= 2 else { return }
            let ll = coordinate(forNode: node)
            guard ll.longitude >= minLon, ll.longitude <= maxLon,
                  ll.latitude >= minLat, ll.latitude <= maxLat else { return }
            giantGrid[gridKey(ll.longitude, ll.latitude), default: []].append(node)
        }

        for ei in 0..<pack.undirectedEdgeCount {
            let access = GraphV2Pack.unpackAccess(pack.edgeAttrs[ei])
            let a = Int(fromArr[ei])
            let b = Int(toArr[ei])
            guard a >= 0, b >= 0, a < n, b < n else { continue }
            let surface = GraphV2Pack.unpackSurface(pack.edgeAttrs[ei])
            // Through giant ≈ paved (surface 0), same as server edge.c === 0.
            if surface == 0 {
                rememberGiant(a)
                rememberGiant(b)
                continue
            }
            guard accessAllowed(access, allowUnknown: true, profile: profile) else { continue }
            let eid = pack.edgeId(ei)
            if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
            if accessName(access) != "motorized_unknown" { continue }
            let mid = coordinate(forNode: a) // coarse corridor filter
            let mid2 = coordinate(forNode: b)
            let inBox = { (ll: CLLocationCoordinate2D) -> Bool in
                ll.longitude >= minLon && ll.longitude <= maxLon
                    && ll.latitude >= minLat && ll.latitude <= maxLat
            }
            if inBox(mid) || inBox(mid2) {
                islandNodes.insert(a)
                islandNodes.insert(b)
            }
        }

        var out: [JunctionStitch] = []
        var seen = Set<String>()
        for island in islandNodes {
            let ll = coordinate(forNode: island)
            let cx = Int(floor(ll.longitude / cell))
            let cy = Int(floor(ll.latitude / cell))
            var best: Int?
            var bestD = stitchM + 1
            for dx in -2...2 {
                for dy in -2...2 {
                    for gn in giantGrid["\(cx + dx):\(cy + dy)"] ?? [] {
                        if gn == island || degree[gn] < 2 { continue }
                        let d = meters(ll, coordinate(forNode: gn))
                        if d < bestD, d > 0.5 {
                            bestD = d
                            best = gn
                        }
                    }
                }
            }
            guard let best, bestD <= stitchM else { continue }
            // Hard ban: dead-end ↔ dead-end.
            if degree[island] <= 1, degree[best] <= 1 { continue }
            let a = min(island, best)
            let b = max(island, best)
            let key = "\(a):\(b)"
            guard seen.insert(key).inserted else { continue }
            out.append(JunctionStitch(
                a: island,
                b: best,
                meters: max(1, bestD),
                edgeId: "soft-stitch-\(key)"
            ))
        }
        return out
    }

    // MARK: - Preferred-node fallback (no edge topology)

    private func routeViaPreferredNodes(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        startSnap: EdgeSnap,
        endSnap: EdgeSnap,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: Set<String>,
        ctx: HopSearchContext
    ) -> Swift.Result<Result, Failure> {
        let startEi = startSnap.edgeIndex
        let endEi = endSnap.edgeIndex
        let start = preferredNode(for: startSnap, toward: to)
        let end = preferredNode(for: endSnap, toward: from)
        if start == end {
            return .failure(.identicalEnds)
        }

        let n = pack.nodeCount
        var dist = [Double](repeating: .infinity, count: n)
        var prev = [Int](repeating: -1, count: n)
        var prevEdge = [Int](repeating: -1, count: n)
        /// Negative prevEdge marks a junction stitch index into `stitches`.
        var prevStitch = [Int](repeating: -1, count: n)
        var heap = MinHeap()

        dist[start] = 0
        heap.push(node: start, cost: 0)

        let policyUnknown = allowUnknown && profile != .cleanest
        let endLL = endSnap.projected
        let abMeters = meters(startSnap.projected, endLL)
        let startOnMajorHighway = snapIsMajorHighwayPin(startSnap, profile: profile)
        let endOnMajorHighway = snapIsMajorHighwayPin(endSnap, profile: profile)
        let stitches = junctionStitches(
            near: from, and: to, profile: profile,
            allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds
        )
        var stitchAdj: [Int: [(to: Int, idx: Int)]] = [:]
        for (idx, s) in stitches.enumerated() {
            stitchAdj[s.a, default: []].append((to: s.b, idx: idx))
            stitchAdj[s.b, default: []].append((to: s.a, idx: idx))
        }

        while let cur = heap.pop() {
            if cur.cost != dist[cur.node] { continue }
            if cur.node == end { break }

            let arcStart = Int(pack.nodeOffsets[cur.node])
            let arcEnd = Int(pack.nodeOffsets[cur.node + 1])
            if arcStart >= 0, arcEnd <= pack.edgeTargets.count {
                for i in arcStart..<arcEnd {
                    let toNode = Int(pack.edgeTargets[i])
                    let ei = Int(pack.edgeUndirectedIndex[i])
                    guard ei >= 0, ei < pack.undirectedEdgeCount else { continue }
                    let attr = pack.edgeAttrs[ei]
                    let access = GraphV2Pack.unpackAccess(attr)
                    if !traversalAccessAllowed(ei: ei, from: cur.node, to: toNode, allowUnknown: policyUnknown, profile: profile) { continue }
                    if edgeBlockedByPavedOnly(ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
                    if ctx.noBacktrack, prevEdge[cur.node] == ei { continue }
                    if pack.v4HopIllegal(
                        ei: ei, from: cur.node, to: toNode,
                        startEi: startEi, endEi: endEi,
                        incomingEi: prevEdge[cur.node]
                    ) { continue }
                    let toLL = coordinate(forNode: toNode)
                    if hopBlocked(toLL, edgeFrom: coordinate(forNode: cur.node), from: from, to: to, ctx: ctx) {
                        continue
                    }

                    let surface = GraphV2Pack.unpackSurface(attr)
                    let roadClass = GraphV2Pack.unpackRoadClass(attr)
                    let confidence = GraphV2Pack.unpackConfidence(attr)
                    var step = hopCostStep(
                        meters: Double(pack.edgeMeters[ei]),
                        edgeIndex: ei,
                        surface: surface,
                        roadClass: roadClass,
                        access: access,
                        confidence: confidence,
                        profile: profile,
                        ctx: ctx,
                        toLL: toLL,
                        endLL: endLL,
                        abMeters: abMeters,
                        startSnap: startSnap,
                        startOnMajorHighway: startOnMajorHighway,
                        endOnMajorHighway: endOnMajorHighway,
                        policyUnknown: policyUnknown
                    )
                    step *= UrbanCore.fallbackMultiplier(
                        point: toLL,
                        start: from,
                        end: to,
                        boxes: packUrbanCores,
                        edgeFrom: coordinate(forNode: cur.node),
                        penalty: UrbanCore.resolveCleanMetroPenalty(
                            profile: profile,
                            override: ctx.cleanMetroMultiplier,
                            avoidMajorHighways: ctx.avoidMotorways
                        )
                    )
                    if ctx.settlementFallback {
                        step *= UrbanCore.settlementFallbackMultiplier(
                            point: toLL, start: from, end: to, boxes: settlementBoxes(for: profile),
                            penalty: UrbanCore.resolveSettlementPenalty(
                                profile: profile,
                                override: ctx.cleanMetroMultiplier,
                                avoidMajorHighways: ctx.avoidMotorways
                            )
                        )
                    }

                    let fromLL = coordinate(forNode: cur.node)
                    step += OnDeviceProfileCosts.approachAwayExtra(
                        profile: profile,
                        dFromMeters: meters(fromLL, endLL),
                        dToMeters: meters(toLL, endLL),
                        abMeters: abMeters,
                        regionId: pack.regionId
                    )
                    if ctx.corridorMeters == nil {
                        step += OnDeviceProfileCosts.corridorCrossTrackExtra(
                            profile: profile,
                            point: toLL,
                            lineFrom: startSnap.projected,
                            lineTo: endLL,
                            edgeMeters: Double(pack.edgeMeters[ei])
                        )
                    }

                    step = backtrackPenalized(step, edgeID: eid, ctx: ctx)
                    let cost = cur.cost + step
                    if cost < dist[toNode] {
                        dist[toNode] = cost
                        prev[toNode] = cur.node
                        prevEdge[toNode] = ei
                        prevStitch[toNode] = -1
                        heap.push(node: toNode, cost: cost)
                    }
                }
            }

            if let links = stitchAdj[cur.node] {
                for link in links {
                    if ctx.pavedOnly { continue }
                    let s = stitches[link.idx]
                    var step = (s.meters / 1000.0) * Self.junctionStitchCostPremium
                    let stitchTo = coordinate(forNode: link.to)
                    step *= UrbanCore.fallbackMultiplier(
                        point: stitchTo,
                        start: from,
                        end: to,
                        boxes: packUrbanCores,
                        edgeFrom: coordinate(forNode: cur.node),
                        penalty: UrbanCore.resolveCleanMetroPenalty(
                            profile: profile,
                            override: ctx.cleanMetroMultiplier,
                            avoidMajorHighways: ctx.avoidMotorways
                        )
                    )
                    if ctx.settlementFallback {
                        step *= UrbanCore.settlementFallbackMultiplier(
                            point: stitchTo, start: from, end: to, boxes: settlementBoxes(for: profile),
                            penalty: UrbanCore.resolveSettlementPenalty(
                                profile: profile,
                                override: ctx.cleanMetroMultiplier,
                                avoidMajorHighways: ctx.avoidMotorways
                            )
                        )
                    }
                    let fromLL = coordinate(forNode: cur.node)
                    let toLL = coordinate(forNode: link.to)
                    step += OnDeviceProfileCosts.approachAwayExtra(
                        profile: profile,
                        dFromMeters: meters(fromLL, endLL),
                        dToMeters: meters(toLL, endLL),
                        abMeters: abMeters,
                        regionId: pack.regionId
                    )
                    let cost = cur.cost + step
                    if cost < dist[link.to] {
                        dist[link.to] = cost
                        prev[link.to] = cur.node
                        prevEdge[link.to] = -1
                        prevStitch[link.to] = link.idx
                        heap.push(node: link.to, cost: cost)
                    }
                }
            }
        }

        guard dist[end].isFinite else { return .failure(.noPath) }

        var legs: [Leg] = []
        var node = end
        while node != start {
            let parent = prev[node]
            guard parent >= 0 else { return .failure(.noPath) }
            if prevStitch[node] >= 0 {
                let s = stitches[prevStitch[node]]
                let a = coordinate(forNode: parent)
                let b = coordinate(forNode: node)
                legs.append(Leg(
                    coordinates: [a, b],
                    distanceMeters: s.meters,
                    surfaceName: "access",
                    edgeId: s.edgeId,
                    accessName: "motorized_permissive"
                ))
            } else {
                let ei = prevEdge[node]
                guard ei >= 0 else { return .failure(.noPath) }
                let a = coordinate(forNode: parent)
                let b = coordinate(forNode: node)
                let m = Double(pack.edgeMeters[ei])
                let surface = OnDeviceProfileCosts.surfaceName(
                    code: GraphV2Pack.unpackSurface(pack.edgeAttrs[ei])
                )
                let id = pack.edgeId(ei)
                let shape = edgePolyline(ei: ei, fromNode: parent, toNode: node, fallback: [a, b])
                legs.append(Leg(
                    coordinates: shape,
                    distanceMeters: m,
                    surfaceName: surface,
                    edgeId: id,
                    accessName: accessNameForEdge(ei),
                    roadClassName: roadClassNameForEdge(ei),
                    surfaceLeaf: pack.hasLeaves ? pack.surfaceLeaf(ei) : nil,
                    structureType: structureTypeForEdge(ei),
                    structureLeaf: structureLeafForEdge(ei),
                    layer: layerForEdge(ei),
                    crossingLabel: crossingLabelForEdge(ei),
                    waterCrossing: waterCrossingForEdge(ei),
                    edgeIndex: ei,
                    fromNode: parent,
                    toNode: node
                ))
            }
            node = parent
        }
        legs.reverse()

        if let stub = softStitchStub(tap: from, snap: startSnap, idSuffix: "start") {
            legs.insert(stub, at: 0)
        }
        if let stub = softStitchStub(tap: to, snap: endSnap, idSuffix: "end") {
            legs.append(stub)
        }

        return .success(finalize(
            legs: legs,
            nodeFallback: [startSnap.projected, endSnap.projected],
            profile: profile,
            allowUnknown: allowUnknown && profile != .cleanest,
            fastFuelPrune: ctx.fastSearch
        ))
    }

    // MARK: - Finalize + geographic prune

    private func finalize(
        legs: [Leg],
        nodeFallback: [CLLocationCoordinate2D],
        profile: RouteProfile = .balanced,
        allowUnknown: Bool = false,
        fastFuelPrune: Bool = false
    ) -> Result {
        var worked = legs

        // Geographic loop pruning when legs carry real polyline geometry.
        // Clean+leaves lockstep: JS `pruneGeographicLoops` is a no-op on the NS
        // fixture routes; Swift's proximity-grid variant can drop short stubs and
        // break edge-id identity. Skip prune so both engines keep the Dijkstra list.
        // Clean+leaves keeps the exact lockstep path for ordinary planning.
        // Fast fuel hops are independently bounded and still need the same
        // meaningful-loop guard as Dirt/Balanced before a pump is committed.
        let skipGeoPrune = profile == .cleanest && pack.hasLeaves && !fastFuelPrune
        let hasGeometry = worked.contains { $0.coordinates.count >= 3 }
            || pack.geometry != nil
        if hasGeometry, !worked.isEmpty, !skipGeoPrune {
            let pieces = worked.map {
                OnDevicePathPruning.EdgePiece(
                    edgeId: $0.edgeId,
                    coords: $0.coordinates,
                    meters: $0.distanceMeters,
                    surfaceName: $0.surfaceName
                )
            }
            // Fast fuel hops still need loop erasure. They use a coarser
            // meaningful-loop threshold to avoid spending the full route
            // budget on dozens of tiny geometry revisits while preserving
            // the rider-visible detours and out-and-backs.
            let pruningOptions = fastFuelPrune
                ? OnDevicePathPruning.Options(cellMeters: 40, matchMeters: 60, minLoopMeters: 100)
                : OnDevicePathPruning.Options(cellMeters: 20, matchMeters: 30, minLoopMeters: 20)
            let pruned = OnDevicePathPruning.pruneGeographicLoops(
                pieces,
                options: pruningOptions
            )
            worked = pruned.edges.map { edge in
                let prior = worked.first(where: { $0.edgeId == edge.edgeId })
                return Leg(
                    coordinates: edge.coords,
                    distanceMeters: edge.meters,
                    surfaceName: edge.surfaceName,
                    edgeId: edge.edgeId,
                    accessName: prior?.accessName ?? "motorized_permissive",
                    roadClassName: prior?.roadClassName ?? "unknown",
                    surfaceLeaf: prior?.surfaceLeaf,
                    structureType: prior?.structureType,
                    structureLeaf: prior?.structureLeaf,
                    layer: prior?.layer ?? 0,
                    crossingLabel: prior?.crossingLabel,
                    waterCrossing: prior?.waterCrossing ?? false,
                    edgeIndex: prior?.edgeIndex,
                    fromNode: prior?.fromNode,
                    toNode: prior?.toNode
                )
            }
            // Second pass: remove sharp out-and-backs that share no exact revisit
            // cell (parallel digitizations / mid-edge snap stubs).
            let strippedPieces = OnDevicePathPruning.stripHeadingReversals(
                worked.map {
                    OnDevicePathPruning.EdgePiece(
                        edgeId: $0.edgeId,
                        coords: $0.coordinates,
                        meters: $0.distanceMeters,
                        surfaceName: $0.surfaceName
                    )
                }
            )
            worked = strippedPieces.map { edge in
                let prior = worked.first(where: { $0.edgeId == edge.edgeId })
                return Leg(
                    coordinates: edge.coords,
                    distanceMeters: edge.meters,
                    surfaceName: edge.surfaceName,
                    edgeId: edge.edgeId,
                    accessName: prior?.accessName ?? "motorized_permissive",
                    roadClassName: prior?.roadClassName ?? "unknown",
                    surfaceLeaf: prior?.surfaceLeaf,
                    structureType: prior?.structureType,
                    structureLeaf: prior?.structureLeaf,
                    layer: prior?.layer ?? 0,
                    crossingLabel: prior?.crossingLabel,
                    waterCrossing: prior?.waterCrossing ?? false,
                    edgeIndex: prior?.edgeIndex,
                    fromNode: prior?.fromNode,
                    toNode: prior?.toNode
                )
            }
        }

        var edgeIds: [String] = []
        var meters: Double = 0
        var dirtMeters: Double = 0
        var pavedMeters: Double = 0
        var unknownMeters: Double = 0
        for leg in worked {
            if !leg.edgeId.isEmpty,
               !leg.edgeId.hasPrefix("soft-stitch-"),
               !leg.edgeId.hasPrefix("perm-stitch-") {
                edgeIds.append(leg.edgeId)
            }
            meters += leg.distanceMeters
            if leg.structureType == "ferry" { continue }
            if leg.paintSurfaceName == "paved" {
                pavedMeters += leg.distanceMeters
            } else if OnDeviceProfileCosts.isAdventureSurface(leg.paintSurfaceName) {
                dirtMeters += leg.distanceMeters
            }
            if leg.accessName == "motorized_unknown" {
                unknownMeters += leg.distanceMeters
            }
        }

        let coords = flattenRouteCoordinates(legs: worked, nodeFallback: nodeFallback)
        let dirtPct: Int
        let pavedPct: Int
        let unknownPct: Int
        if meters > 0 {
            dirtPct = Int((dirtMeters / meters * 100).rounded())
            pavedPct = Int((pavedMeters / meters * 100).rounded())
            unknownPct = Int((unknownMeters / meters * 100).rounded())
        } else {
            dirtPct = 0
            pavedPct = 0
            unknownPct = 0
        }

        // Phase E1: honest reported % from surfaceLeaf (selection keeps coarse dirtPct).
        // Exclude soft/perm stitches — they have no leaf and must not inflate Unknown/Dirt%.
        let reported: SurfaceFamilyStats.Percents
        if pack.hasLeaves {
            let leafLegs = worked.filter {
                !$0.edgeId.hasPrefix("soft-stitch-") &&
                !$0.edgeId.hasPrefix("perm-stitch-") &&
                $0.structureType != "ferry"
            }
            let rows = leafLegs.map { ($0.distanceMeters, $0.surfaceLeaf) }
            let leafMeters = leafLegs.reduce(0.0) { $0 + $1.distanceMeters }
            reported = SurfaceFamilyStats.honestPercents(
                rows: rows,
                distanceMeters: leafMeters,
                familyMap: pack.surfaceFamilyMap
            )
        } else {
            reported = SurfaceFamilyStats.Percents(
                dirtPercent: dirtPct,
                pavedPercent: pavedPct,
                gravelPercent: 0,
                unknownSurfacePercent: 0
            )
        }

        var searchMeta = SearchMeta()
        if let start = coords.first, let end = coords.last {
            searchMeta.settlementFallbackUsed = coords.contains {
                UrbanCore.blocks(
                    point: $0,
                    start: start,
                    end: end,
                    boxes: settlementBoxes(for: profile)
                )
            }
        }
        return Result(
            coordinates: coords,
            distanceMeters: meters,
            edgeIds: edgeIds,
            legs: worked,
            dirtPercent: dirtPct,
            pavedPercent: pavedPct,
            unknownAccessPercent: unknownPct,
            reportedDirtPercent: reported.dirtPercent,
            reportedPavedPercent: reported.pavedPercent,
            unknownSurfacePercent: reported.unknownSurfacePercent,
            hasSurfaceLeaves: pack.hasLeaves,
            maneuvers: graphDecisionManeuvers(
                legs: worked,
                profile: profile,
                allowUnknown: allowUnknown,
                totalMeters: meters
            ),
            searchMeta: searchMeta
        )
    }

    /// Junction mode is authored from real eligible graph choices. A bend in
    /// an uninterrupted road is not a junction; a straight movement through a
    /// branching node is explicitly announced as Continue straight.
    private func graphDecisionManeuvers(
        legs: [Leg],
        profile: RouteProfile,
        allowUnknown: Bool,
        totalMeters: Double
    ) -> [RouteManeuver] {
        guard !legs.isEmpty else { return [] }
        var output: [RouteManeuver] = []
        var alongMeters = 0.0
        let ignoredRoadClasses: Set<String> = ["service", "parking", "driveway"]

        for index in 1..<legs.count {
            let incoming = legs[index - 1]
            let outgoing = legs[index]
            alongMeters += incoming.distanceMeters

            guard let incomingEdge = incoming.edgeIndex,
                  let outgoingEdge = outgoing.edgeIndex,
                  let node = incoming.toNode,
                  node == outgoing.fromNode,
                  node >= 0,
                  node < pack.nodeCount,
                  incoming.coordinates.count >= 2,
                  outgoing.coordinates.count >= 2
            else { continue }

            let arcStart = Int(pack.nodeOffsets[node])
            let arcEnd = Int(pack.nodeOffsets[node + 1])
            guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
            let hasUsefulAlternative = (arcStart..<arcEnd).contains { arcIndex in
                let candidateEdge = Int(pack.edgeUndirectedIndex[arcIndex])
                let targetNode = Int(pack.edgeTargets[arcIndex])
                guard candidateEdge >= 0,
                      candidateEdge < pack.undirectedEdgeCount,
                      candidateEdge != incomingEdge,
                      candidateEdge != outgoingEdge,
                      targetNode != incoming.fromNode,
                      targetNode != outgoing.toNode,
                      Double(pack.edgeMeters[candidateEdge]) >= 30,
                      !ignoredRoadClasses.contains(roadClassNameForEdge(candidateEdge).lowercased())
                else { return false }
                let access = GraphV2Pack.unpackAccess(pack.edgeAttrs[candidateEdge])
                return accessAllowed(access, allowUnknown: allowUnknown, profile: profile)
            }
            guard hasUsefulAlternative else { continue }

            let a = incoming.coordinates[incoming.coordinates.count - 2]
            let b = incoming.coordinates[incoming.coordinates.count - 1]
            let c = outgoing.coordinates[1]
            let bearingIn = atan2(b.longitude - a.longitude, b.latitude - a.latitude)
            let bearingOut = atan2(c.longitude - b.longitude, c.latitude - b.latitude)
            var delta = (bearingOut - bearingIn) * 180 / .pi
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            let degrees = abs(delta).rounded()
            let straight = degrees < 30
            let side = straight ? nil : (delta > 0 ? "right" : "left")

            output.append(RouteManeuver(
                instruction: straight ? "Continue straight" : "Turn \(side ?? "")",
                type: straight ? "continueStraight" : "turn",
                stableID: "jct:\(incoming.edgeId)>\(outgoing.edgeId)",
                kind: "junction",
                side: side,
                number: nil,
                degrees: degrees,
                distanceMeters: 0,
                alongMeters: alongMeters
            ))
        }

        let lastID = legs.last.flatMap { $0.edgeId.isEmpty ? nil : $0.edgeId } ?? "destination"
        output.append(RouteManeuver(
            instruction: "Arrive at destination",
            type: "arrive",
            stableID: "arrive:\(lastID)",
            kind: "arrive",
            distanceMeters: 0,
            alongMeters: totalMeters
        ))
        return output
    }

    // MARK: - Soft-stitch stubs

    /// Short connector from off-road tap/GPS to the nearest point on a pack edge.
    /// Drawn for driveway / camp approaches so the route visibly meets the road.
    private func softStitchStub(
        tap: CLLocationCoordinate2D,
        snap: EdgeSnap,
        idSuffix: String
    ) -> Leg? {
        guard snap.edgeIndex >= 0 else { return nil }
        let d = meters(tap, snap.projected)
        guard d >= Self.softStitchMinMeters else { return nil }
        guard d <= Self.preferredMatchMeters else { return nil }

        return Leg(
            coordinates: [tap, snap.projected],
            distanceMeters: d,
            surfaceName: "access",
            edgeId: "soft-stitch-\(idSuffix)"
        )
    }

    // MARK: - Geometry helpers

    private func edgeGeometry(_ ei: Int) -> [CLLocationCoordinate2D]? {
        guard let geom = pack.geometry else { return nil }
        let poly = geom.polyline(edgeIndex: ei)
        return poly.count >= 2 ? poly : nil
    }

    private func coordsFromAToMatch(
        _ coords: [CLLocationCoordinate2D],
        snap: EdgeSnap
    ) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        let end = min(snap.segmentIndex, coords.count - 1)
        if end >= 0 {
            for i in 0...end { out.append(coords[i]) }
        }
        if let last = out.last {
            if abs(last.latitude - snap.projected.latitude) > 1e-9
                || abs(last.longitude - snap.projected.longitude) > 1e-9 {
                out.append(snap.projected)
            }
        } else {
            out.append(snap.projected)
        }
        return dedupeCoords(out)
    }

    private func coordsFromMatchToB(
        _ coords: [CLLocationCoordinate2D],
        snap: EdgeSnap
    ) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = [snap.projected]
        let start = snap.segmentIndex + 1
        if start < coords.count {
            for i in start..<coords.count { out.append(coords[i]) }
        }
        return dedupeCoords(out)
    }

    private func coordsBetweenMatches(
        _ coords: [CLLocationCoordinate2D],
        start: EdgeSnap,
        end: EdgeSnap
    ) -> [CLLocationCoordinate2D] {
        if start.distanceAlongM <= end.distanceAlongM {
            var forward: [CLLocationCoordinate2D] = [start.projected]
            let from = start.segmentIndex + 1
            let to = end.segmentIndex
            if from <= to, from < coords.count {
                for i in from...min(to, coords.count - 1) {
                    forward.append(coords[i])
                }
            }
            forward.append(end.projected)
            return dedupeCoords(forward)
        }
        return Array(coordsBetweenMatches(coords, start: end, end: start).reversed())
    }

    private func dedupeCoords(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for c in coords {
            if let last = out.last,
               abs(last.latitude - c.latitude) < 1e-9,
               abs(last.longitude - c.longitude) < 1e-9 {
                continue
            }
            out.append(c)
        }
        return out
    }

    private func lineMeters(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<coords.count {
            total += meters(coords[i - 1], coords[i])
        }
        return total
    }

    private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Prefer geometry.v1 polyline; fall back to node chord.
    private func edgePolyline(
        ei: Int,
        fromNode: Int,
        toNode: Int,
        fallback: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard let geom = pack.geometry else { return fallback }
        let forward: Bool
        if let edgeFrom = pack.edgeFrom, let edgeTo = pack.edgeTo,
           ei < edgeFrom.count, ei < edgeTo.count {
            let a = Int(edgeFrom[ei])
            let b = Int(edgeTo[ei])
            if fromNode == a, toNode == b {
                forward = true
            } else if fromNode == b, toNode == a {
                forward = false
            } else {
                let poly = geom.polyline(edgeIndex: ei)
                guard let first = poly.first, let last = poly.last else { return fallback }
                let from = coordinate(forNode: fromNode)
                let dStart = meters(from, first)
                let dEnd = meters(from, last)
                forward = dStart <= dEnd
                let oriented = forward ? poly : Array(poly.reversed())
                return oriented.count >= 2 ? oriented : fallback
            }
        } else {
            forward = true
        }
        let poly = geom.polyline(edgeIndex: ei, forward: forward)
        return poly.count >= 2 ? poly : fallback
    }

    private func flattenRouteCoordinates(
        legs: [Leg],
        nodeFallback: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        for leg in legs {
            for c in leg.coordinates {
                if let last = coords.last,
                   abs(last.latitude - c.latitude) < 1e-9,
                   abs(last.longitude - c.longitude) < 1e-9 {
                    continue
                }
                coords.append(c)
            }
        }
        return coords.count >= 2 ? coords : nodeFallback
    }

    // MARK: - Snap

    private final class FuelSnapCache: @unchecked Sendable {
        static let shared = FuelSnapCache()
        private let lock = NSLock()
        private weak var owner: GraphV2Pack?
        private weak var geometry: GeometryV1Pack?
        private struct Entry { let snaps: [EdgeSnap]; var used: UInt64 }
        private var entries: [String: Entry] = [:]
        private var tick: UInt64 = 0

        func get(_ key: String, pack: GraphV2Pack) -> [EdgeSnap]? {
            lock.lock(); defer { lock.unlock() }
            if owner !== pack || geometry !== pack.geometry {
                entries.removeAll(keepingCapacity: false)
                owner = pack; geometry = pack.geometry
            }
            guard var entry = entries[key] else { return nil }
            tick &+= 1; entry.used = tick; entries[key] = entry
            return entry.snaps
        }

        func put(_ snaps: [EdgeSnap], key: String, pack: GraphV2Pack) {
            lock.lock(); defer { lock.unlock() }
            if owner !== pack || geometry !== pack.geometry {
                entries.removeAll(keepingCapacity: false)
                owner = pack; geometry = pack.geometry
            }
            if entries[key] == nil, entries.count >= NativeFuelPreparation.cacheLimit,
               let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
                entries.removeValue(forKey: oldest)
            }
            tick &+= 1; entries[key] = Entry(snaps: snaps, used: tick)
        }
    }

    private func fuelSnaps(
        to point: CLLocationCoordinate2D,
        allowUnknown: Bool,
        profile: RouteProfile
    ) -> [EdgeSnap] {
        guard !executionCancelled() else { return [] }
        guard NativeFuelPreparation.enabled else {
            return nearestEdgeSnaps(
                to: point, allowUnknown: allowUnknown, profile: profile,
                maxMeters: Self.preferredMatchMeters
            )
        }
        let key = "\(point.longitude.bitPattern):\(point.latitude.bitPattern):\(profile.rawValue):\(allowUnknown)"
        if let cached = FuelSnapCache.shared.get(key, pack: pack) { return cached }
        guard !Task.isCancelled, !executionCancelled() else { return [] }
        let snaps = nearestEdgeSnaps(
            to: point, allowUnknown: allowUnknown, profile: profile,
            maxMeters: Self.preferredMatchMeters
        )
        guard !Task.isCancelled, !executionCancelled() else { return [] }
        FuelSnapCache.shared.put(snaps, key: key, pack: pack)
        return snaps
    }

    private struct EdgeSnap {
        var edgeIndex: Int
        var nodeA: Int
        var nodeB: Int
        var distanceMeters: Double
        var projected: CLLocationCoordinate2D
        /// Meters from node A along the edge to the projection.
        var distanceAlongM: Double
        /// Segment index on the geometry polyline (or 0 for chord).
        var segmentIndex: Int
        /// Bearing of the snapped segment, degrees clockwise from north.
        var tangentDeg: Double
        /// V4 directed-candidate score (distance + heading + intent). V3 leaves 0.
        var score: Double = 0
        var forward: Bool = true
        var osmWayId: String? = nil
        var accessClass: String? = nil
        var accessCode: Int = 0
        var component: Int = -1
    }

    /// Snap a seam seed onto pack fabric (cross-pack hops). Wider than pin snap.
    static let seamSnapMeters: Double = 12_000

    func nearestRoadCoordinate(
        to point: CLLocationCoordinate2D,
        allowUnknown: Bool,
        profile: RouteProfile,
        maxMeters: Double = OnDeviceRouter.seamSnapMeters,
        osmCoreOnly: Bool = false
    ) -> CLLocationCoordinate2D? {
        nearestEdgeSnaps(
            to: point,
            allowUnknown: allowUnknown,
            profile: profile,
            maxMeters: maxMeters,
            osmCoreOnly: osmCoreOnly
        ).first(where: { $0.distanceMeters <= maxMeters })?.projected
    }

    private func nearestEdgeSnap(
        to point: CLLocationCoordinate2D,
        allowUnknown: Bool,
        profile: RouteProfile
    ) -> EdgeSnap? {
        nearestEdgeSnaps(to: point, allowUnknown: allowUnknown, profile: profile).first
    }

    /// Closest eligible pack edges within `maxMeters`, nearest first (capped).
    /// Returns extra candidates so adventure re-sort + paved diversification still
    /// have yellow/white connectors available in dense track meshes.
    private func nearestEdgeSnaps(
        to point: CLLocationCoordinate2D,
        allowUnknown: Bool,
        profile: RouteProfile,
        maxMeters: Double = OnDeviceRouter.maxSnapMeters,
        osmCoreOnly: Bool = false,
        headingDeg: Double? = nil,
        intentBearingDeg: Double? = nil
    ) -> [EdgeSnap] {
        var rejections: [String] = []
        return nearestEdgeSnaps(
            to: point,
            allowUnknown: allowUnknown,
            profile: profile,
            maxMeters: maxMeters,
            osmCoreOnly: osmCoreOnly,
            headingDeg: headingDeg,
            intentBearingDeg: intentBearingDeg,
            rejections: &rejections
        )
    }

    private func nearestEdgeSnaps(
        to point: CLLocationCoordinate2D,
        allowUnknown: Bool,
        profile: RouteProfile,
        maxMeters: Double = OnDeviceRouter.maxSnapMeters,
        osmCoreOnly: Bool = false,
        headingDeg: Double? = nil,
        intentBearingDeg: Double? = nil,
        rejections: inout [String]
    ) -> [EdgeSnap] {
        guard let fromArr = pack.edgeFrom, let toArr = pack.edgeTo else {
            return nearestNodeFallback(to: point).map {
                [
                    EdgeSnap(
                        edgeIndex: -1,
                        nodeA: $0,
                        nodeB: $0,
                        distanceMeters: 0,
                        projected: coordinate(forNode: $0),
                        distanceAlongM: 0,
                        segmentIndex: 0,
                        tangentDeg: 0
                    )
                ]
            } ?? []
        }

        let policyUnknown = allowUnknown && profile != .cleanest
        var bestByEdge: [Int: EdgeSnap] = [:]
        let lat = point.latitude
        let lon = point.longitude
        let geom = pack.geometry
        let grid = PackEdgeSpatialIndex.shared.grid(for: pack)
        // ~1.1 km / cell at mid-latitudes. Scan the full requested radius:
        // stopping after the nearest hit misses through-roads across cell borders.
        let cellKm = PackEdgeSpatialIndex.cellDegrees * 111.0
        let maxRadius = max(2, Int(ceil(maxMeters / 1000.0 / cellKm)) + 2)

        var checked = Set<Int>()
        for radius in 0...maxRadius {
            if executionCancelled() { return [] }
            for ei in grid.edgeIndices(nearLat: lat, lon: lon, radiusCells: radius) {
                if executionCancelled() { return [] }
                if checked.contains(ei) { continue }
                checked.insert(ei)
                if pack.version < 4 || !pack.legalTopology {
                    let access = GraphV2Pack.unpackAccess(pack.edgeAttrs[ei])
                    guard accessAllowed(access, allowUnknown: policyUnknown, profile: profile) else { continue }
                }
                if osmCoreOnly, !GraphV2Pack.isOsmCoreEdge(pack.edgeId(ei)) { continue }
                let a = Int(fromArr[ei])
                let b = Int(toArr[ei])
                guard a >= 0, b >= 0, a < pack.nodeCount, b < pack.nodeCount else { continue }
                let aLon = Double(pack.nodeCoords[a * 2])
                let aLat = Double(pack.nodeCoords[a * 2 + 1])
                let bLon = Double(pack.nodeCoords[b * 2])
                let bLat = Double(pack.nodeCoords[b * 2 + 1])

                let poly: [CLLocationCoordinate2D]
                if let g = geom {
                    let p = g.polyline(edgeIndex: ei)
                    poly = p.count >= 2
                        ? p
                        : [
                            CLLocationCoordinate2D(latitude: aLat, longitude: aLon),
                            CLLocationCoordinate2D(latitude: bLat, longitude: bLon)
                        ]
                } else {
                    poly = [
                        CLLocationCoordinate2D(latitude: aLat, longitude: aLon),
                        CLLocationCoordinate2D(latitude: bLat, longitude: bLon)
                    ]
                }

                var along = 0.0
                for i in 1..<poly.count {
                    if executionCancelled() { return [] }
                    let segA = poly[i - 1]
                    let segB = poly[i]
                    let segM = meters(segA, segB)
                    let proj = projectOntoSegment(point: point, a: segA, b: segB)
                    let d = meters(point, proj.coord)
                    if d <= maxMeters {
                        let candidate = EdgeSnap(
                            edgeIndex: ei,
                            nodeA: a,
                            nodeB: b,
                            distanceMeters: d,
                            projected: proj.coord,
                            distanceAlongM: along + segM * proj.t,
                            segmentIndex: i - 1,
                            tangentDeg: bearingDeg(from: segA, to: segB)
                        )
                        if let existing = bestByEdge[ei] {
                            if d < existing.distanceMeters {
                                bestByEdge[ei] = candidate
                            }
                        } else {
                            bestByEdge[ei] = candidate
                        }
                    }
                    along += segM
                }
            }
        }

        let ranked = bestByEdge.values.sorted { $0.distanceMeters < $1.distanceMeters }
        guard pack.version >= 4, pack.legalTopology else {
            return Array(ranked.prefix(Self.maxStartSnapCandidates * 2))
        }
        let policyAllow = allowUnknown && profile != .cleanest
        var scored: [EdgeSnap] = []
        scored.reserveCapacity(ranked.count * 2)
        for snap in ranked {
            guard snap.edgeIndex >= 0 else { continue }
            let dirs: [(forward: Bool, from: Int, to: Int, tangent: Double)] = [
                (true, snap.nodeA, snap.nodeB, snap.tangentDeg),
                (false, snap.nodeB, snap.nodeA, (snap.tangentDeg + 180).truncatingRemainder(dividingBy: 360))
            ]
            for dir in dirs {
                let legal = v4DirectionLegal(
                    ei: snap.edgeIndex,
                    from: dir.from,
                    to: dir.to,
                    allowUnknown: policyAllow
                )
                if !legal.ok {
                    rejections.append(legal.reason)
                    continue
                }
                var score = snap.distanceMeters
                if let headingDeg { score += angleDiffDeg(headingDeg, dir.tangent) * 0.4 }
                if let intentBearingDeg { score += angleDiffDeg(intentBearingDeg, dir.tangent) * 0.25 }
                var kept = snap
                kept.tangentDeg = dir.tangent
                kept.forward = dir.forward
                kept.score = score
                kept.accessCode = legal.code
                kept.accessClass = v4AccessClassName(legal.code)
                if snap.edgeIndex < pack.osmWayIds.count {
                    kept.osmWayId = String(pack.osmWayIds[snap.edgeIndex])
                }
                scored.append(kept)
            }
        }
        scored.sort { $0.score < $1.score }
        var kept: [EdgeSnap] = []
        for cand in scored {
            if headingDeg != nil || intentBearingDeg != nil {
                let heading = headingDeg ?? intentBearingDeg ?? 0
                if let opposite = kept.first(where: { existing in
                    existing.edgeIndex != cand.edgeIndex
                        && existing.distanceMeters < 80
                        && cand.distanceMeters < 80
                        && angleDiffDeg(existing.tangentDeg, cand.tangentDeg) > 140
                }) {
                    if angleDiffDeg(heading, cand.tangentDeg) > 70,
                       angleDiffDeg(heading, opposite.tangentDeg) < 40 {
                        rejections.append("median_opposite_carriageway")
                        continue
                    }
                }
            }
            kept.append(cand)
            if kept.count >= 12 { break }
        }
        return kept
    }

    private func v4DirectionLegal(
        ei: Int,
        from: Int,
        to: Int,
        allowUnknown: Bool
    ) -> (ok: Bool, code: Int, reason: String) {
        guard pack.hasDirectedArc(from: from, to: to, edge: ei) else {
            return (false, 2, "prohibited_direction")
        }
        let code = Int(pack.v4AccessCode(ei: ei, from: from, to: to))
        if code == 2 { return (false, code, "inaccessible") }
        if code == 5 { return (false, code, "impassable") }
        if code == 1 && !allowUnknown { return (false, code, "unknown_trail") }
        return (true, code, "")
    }

    private func v4AccessClassName(_ code: Int) -> String {
        switch code {
        case 0: return "motorized_verified"
        case 1: return "motorized_unknown"
        case 2: return "motorized_denied"
        case 3: return "motorized_endpoint"
        case 4: return "motorized_destination"
        case 5: return "motorized_impassable"
        default: return "motorized_unknown"
        }
    }

    private func weakComponentIds(allowUnknown: Bool) -> [Int] {
        let n = pack.nodeCount
        guard n > 0, let fromArr = pack.edgeFrom, let toArr = pack.edgeTo else {
            return []
        }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var x = i
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            guard a >= 0, b >= 0, a < n, b < n else { return }
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        func member(_ code: Int) -> Bool {
            if code == 0 { return true }
            if code == 1 { return allowUnknown }
            if code == 3 || code == 4 { return true }
            return false
        }
        for ei in 0..<pack.undirectedEdgeCount {
            let a = Int(fromArr[ei])
            let b = Int(toArr[ei])
            let fwd = Int(pack.v4AccessCode(ei: ei, from: a, to: b))
            let rev = Int(pack.v4AccessCode(ei: ei, from: b, to: a))
            if member(fwd) || member(rev) { union(a, b) }
        }
        return (0..<n).map { find($0) }
    }

    private func selectConnectedSnapPairs(
        starts: [EdgeSnap],
        ends: [EdgeSnap],
        allowUnknown: Bool
    ) -> (pairs: [(EdgeSnap, EdgeSnap)], rejectionReasons: [String]) {
        let components = weakComponentIds(allowUnknown: allowUnknown)
        var annotatedStarts = starts
        var annotatedEnds = ends
        func component(of snap: EdgeSnap) -> Int {
            guard !components.isEmpty else { return -1 }
            let node = snap.forward ? snap.nodeA : snap.nodeB
            guard node >= 0, node < components.count else { return -1 }
            return components[node]
        }
        for i in annotatedStarts.indices {
            annotatedStarts[i].component = component(of: annotatedStarts[i])
        }
        for i in annotatedEnds.indices {
            annotatedEnds[i].component = component(of: annotatedEnds[i])
        }
        var pairs: [(start: EdgeSnap, end: EdgeSnap, score: Double)] = []
        var rejects: [String] = []
        for start in annotatedStarts {
            for end in annotatedEnds {
                pairs.append((start, end, start.score + end.score))
            }
        }
        pairs.sort { $0.score < $1.score }
        var kept: [(EdgeSnap, EdgeSnap)] = []
        for pair in pairs {
            if pair.start.component != pair.end.component {
                rejects.append("disconnected_component")
                continue
            }
            kept.append((pair.start, pair.end))
            if kept.count >= 12 { break }
        }
        return (kept, rejects)
    }

    private func snapEndpoint(
        raw: CLLocationCoordinate2D,
        snap: EdgeSnap,
        candidateCount: Int,
        rejectionReasons: [String]
    ) -> RouteSnapEndpoint {
        RouteSnapEndpoint(
            raw: SnapCoordinate(longitude: raw.longitude, latitude: raw.latitude),
            snapped: SnapCoordinate(longitude: snap.projected.longitude, latitude: snap.projected.latitude),
            distanceM: Int(snap.distanceMeters.rounded()),
            candidateCount: candidateCount,
            osmWayId: snap.osmWayId,
            accessClass: snap.accessClass,
            component: snap.component,
            rejectionReasons: rejectionReasons
        )
    }

    /// Prefer the endpoint with higher degree (mainline over spur), then closer to the far end.
    private func preferredNode(for snap: EdgeSnap, toward other: CLLocationCoordinate2D) -> Int {
        if snap.nodeA == snap.nodeB { return snap.nodeA }
        let degA = degree(snap.nodeA)
        let degB = degree(snap.nodeB)
        if degA != degB { return degA > degB ? snap.nodeA : snap.nodeB }
        let a = coordinate(forNode: snap.nodeA)
        let b = coordinate(forNode: snap.nodeB)
        let da = meters(a, other)
        let db = meters(b, other)
        return da <= db ? snap.nodeA : snap.nodeB
    }

    private func degree(_ node: Int) -> Int {
        let start = Int(pack.nodeOffsets[node])
        let end = Int(pack.nodeOffsets[node + 1])
        return max(0, end - start)
    }

    private func nearestNodeFallback(to point: CLLocationCoordinate2D) -> Int? {
        var best = -1
        var bestD = Double.infinity
        for i in 0..<pack.nodeCount {
            let lon = Double(pack.nodeCoords[i * 2])
            let lat = Double(pack.nodeCoords[i * 2 + 1])
            let dlat = lat - point.latitude
            let dlon = lon - point.longitude
            let d = dlat * dlat + dlon * dlon
            if d < bestD {
                bestD = d
                best = i
            }
        }
        guard best >= 0 else { return nil }
        let nodeCoord = coordinate(forNode: best)
        let d = meters(point, nodeCoord)
        guard d <= Self.maxSnapMeters else { return nil }
        return best
    }

    private struct Projection {
        var coord: CLLocationCoordinate2D
        var t: Double
    }

    private func projectOntoSegment(
        point: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> Projection {
        let ax = a.longitude, ay = a.latitude
        let bx = b.longitude, by = b.latitude
        let px = point.longitude, py = point.latitude
        let abx = bx - ax, aby = by - ay
        let apx = px - ax, apy = py - ay
        let ab2 = abx * abx + aby * aby
        let t: Double
        if ab2 <= 0 {
            t = 0
        } else {
            t = max(0, min(1, (apx * abx + apy * aby) / ab2))
        }
        return Projection(
            coord: CLLocationCoordinate2D(latitude: ay + t * aby, longitude: ax + t * abx),
            t: t
        )
    }

    /// Remove A→…→A cycles in the node sequence (simple tendril / loop cleanup).
    private func pruneNodeRevisits(nodes: [Int], edges: [Int]) -> (nodes: [Int], edges: [Int]) {
        guard nodes.count == edges.count + 1, nodes.count > 1 else {
            return (nodes, edges)
        }
        var outNodes: [Int] = []
        var outEdges: [Int] = []
        var indexOf: [Int: Int] = [:]

        for i in 0..<nodes.count {
            let node = nodes[i]
            if let start = indexOf[node] {
                if start < outNodes.count {
                    outNodes.removeSubrange((start + 1)...)
                }
                if start < outEdges.count {
                    outEdges.removeSubrange(start...)
                }
                indexOf = [:]
                for (idx, n) in outNodes.enumerated() { indexOf[n] = idx }
                continue
            }
            if i > 0 {
                outEdges.append(edges[i - 1])
            }
            indexOf[node] = outNodes.count
            outNodes.append(node)
        }

        if outNodes.count >= 2, outEdges.count == outNodes.count - 1 {
            return (outNodes, outEdges)
        }
        return (nodes, edges)
    }

    private func coordinate(forNode i: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: Double(pack.nodeCoords[i * 2 + 1]),
            longitude: Double(pack.nodeCoords[i * 2])
        )
    }

    private func accessName(_ code: Int) -> String {
        if code >= 0, code < pack.accessNames.count { return pack.accessNames[code] }
        return ""
    }

    private func accessNameForEdge(_ ei: Int) -> String {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return "motorized_unknown" }
        let name = accessName(GraphV2Pack.unpackAccess(pack.edgeAttrs[ei]))
        return name.isEmpty ? "motorized_unknown" : name
    }

    private func snapIsMajorHighwayPin(_ snap: EdgeSnap, profile: RouteProfile) -> Bool {
        guard snap.distanceMeters < OnDeviceProfileCosts.majorHighwayPinMeters else { return false }
        if profile == .cleanest, pack.hasLeaves {
            let tier = pack.roadTier(snap.edgeIndex)
            return tier == .motorway || tier == .trunk || tier == .arterial
        }
        return OnDeviceProfileCosts.isMajorHighway(
            roadClassNameForEdge(snap.edgeIndex),
            profile: profile
        )
    }

    private func roadClassNameForEdge(_ ei: Int) -> String {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return "unknown" }
        return GraphV2Pack.roadClassName(GraphV2Pack.unpackRoadClass(pack.edgeAttrs[ei]))
    }

    private func structureTypeForEdge(_ ei: Int) -> String? {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return nil }
        let name = GraphV2Pack.structureName(GraphV2Pack.unpackStructure(pack.edgeAttrs[ei]))
        return name == "none" ? nil : name
    }

    private func structureLeafForEdge(_ ei: Int) -> String? {
        guard ei >= 0, ei < pack.undirectedEdgeCount, pack.hasLeaves else { return nil }
        if let leaf = pack.structureLeaf(ei), leaf != "n/a", !leaf.isEmpty {
            return leaf
        }
        return nil
    }

    private func layerForEdge(_ ei: Int) -> Int {
        guard ei >= 0, ei < pack.undirectedEdgeCount, pack.hasLeaves else { return 0 }
        return pack.layer(ei)
    }

    private func crossingLabelForEdge(_ ei: Int) -> String? {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return nil }
        let code = GraphV2Pack.unpackStructure(pack.edgeAttrs[ei])
        return OnDeviceProfileCosts.structureCrossingLabel(
            structureCode: code,
            structureLeaf: structureLeafForEdge(ei),
            layer: layerForEdge(ei)
        )
    }

    private func waterCrossingForEdge(_ ei: Int) -> Bool {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return false }
        return OnDeviceProfileCosts.isWaterCrossing(
            structureCode: GraphV2Pack.unpackStructure(pack.edgeAttrs[ei]),
            structureLeaf: structureLeafForEdge(ei)
        )
    }

    private func edgeIsDirt(_ ei: Int) -> Bool {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return false }
        let attr = pack.edgeAttrs[ei]
        let paint = OnDeviceProfileCosts.riderPaintSurface(
            surfaceName: OnDeviceProfileCosts.surfaceName(code: GraphV2Pack.unpackSurface(attr)),
            roadClassName: GraphV2Pack.roadClassName(GraphV2Pack.unpackRoadClass(attr))
        )
        return OnDeviceProfileCosts.isAdventureSurface(paint)
    }

    /// Clean paved-only: leaf law when pack has leaves; else coarse gate.
    private func edgeBlockedForCleanPavement(_ ei: Int) -> Bool {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return true }
        if pack.hasLeaves {
            return RoadTierStats.isBlockedForCleanLeaf(
                family: pack.surfaceFamily(ei),
                tier: pack.roadTier(ei),
                pavedOnly: true,
                isEndpointEdge: false
            )
        }
        let attr = pack.edgeAttrs[ei]
        return OnDeviceProfileCosts.isBlockedForCleanPavement(
            surfaceName: OnDeviceProfileCosts.surfaceName(code: GraphV2Pack.unpackSurface(attr)),
            roadClassName: GraphV2Pack.roadClassName(GraphV2Pack.unpackRoadClass(attr))
        )
    }

    private func edgeBlockedByPavedOnly(
        _ ei: Int,
        ctx: HopSearchContext,
        allowSnapEdges startEi: Int = -1,
        endEi: Int = -1
    ) -> Bool {
        if ei == startEi || ei == endEi { return false }
        if pack.hasLeaves, ctx.profile == .cleanest {
            return RoadTierStats.isBlockedForCleanLeaf(
                family: pack.surfaceFamily(ei),
                tier: pack.roadTier(ei),
                pavedOnly: ctx.pavedOnly,
                isEndpointEdge: false
            )
        }
        guard ctx.pavedOnly else { return false }
        return edgeBlockedForCleanPavement(ei)
    }

    /// Pack duplicate nodes within `cleanCoincidentNodeMeters` share a place.
    private func coincidentSiblingLists() -> [[Int]?] {
        if pack.version >= 4 {
            return [[Int]?](repeating: nil, count: pack.nodeCount)
        }
        let n = pack.nodeCount
        var lists = [[Int]?](repeating: nil, count: n)
        let epsilon = HopSearchPolicy.cleanCoincidentNodeMeters
        let qLat = epsilon / 111_000.0
        var buckets: [String: [Int]] = [:]
        for i in 0..<n {
            let ll = coordinate(forNode: i)
            let cos = max(0.2, cos(ll.latitude * .pi / 180))
            let qLon = epsilon / (111_000.0 * cos)
            let key = "\(Int((ll.longitude / qLon).rounded())):\(Int((ll.latitude / qLat).rounded()))"
            buckets[key, default: []].append(i)
        }
        for group in buckets.values where group.count >= 2 {
            for (idx, id) in group.enumerated() {
                var others: [Int] = []
                others.reserveCapacity(group.count - 1)
                for (j, other) in group.enumerated() where j != idx {
                    others.append(other)
                }
                lists[id] = others
            }
        }
        return lists
    }

    private func isBacktrack(
        prevKind: UInt8,
        prevData: Int,
        ei: Int,
        virt: [VirtEdge]
    ) -> Bool {
        guard ei >= 0 else { return false }
        if prevKind == 0 { return prevData == ei }
        if prevKind == 1, prevData >= 0, prevData < virt.count {
            return virt[prevData].ei == ei
        }
        return false
    }

    private func incomingUndirected(
        prevKind: UInt8,
        prevData: Int,
        virt: [VirtEdge]
    ) -> Int {
        if prevKind == 0 { return prevData }
        if prevKind == 1, prevData >= 0, prevData < virt.count {
            return virt[prevData].ei
        }
        return -1
    }

    private func bearingDeg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    private func angleDiffDeg(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }

    private func hopBlocked(
        _ point: CLLocationCoordinate2D,
        edgeFrom: CLLocationCoordinate2D? = nil,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        ctx: HopSearchContext
    ) -> Bool {
        if ctx.cityWall,
           UrbanCore.blocks(point: point, start: from, end: to, boxes: packUrbanCores) {
            return true
        }
        if ctx.cityWall, let edgeFrom,
           UrbanCore.blocks(
               segmentFrom: edgeFrom,
               segmentTo: point,
               start: from,
               end: to,
               boxes: packUrbanCores
           ) {
            return true
        }
        if ctx.settlementWall,
           UrbanCore.blocks(point: point, start: from, end: to, boxes: packSettlements) {
            return true
        }
        if ctx.hardCorridor, let corridor = ctx.corridorMeters,
           abs(GeoMath.crossTrackMeters(point: point, lineFrom: from, to: to)) > corridor {
            return true
        }
        return false
    }

    private func backtrackPenalized(
        _ cost: Double,
        edgeID: String,
        ctx: HopSearchContext
    ) -> Double {
        guard !edgeID.isEmpty else { return cost }
        if edgeID == ctx.arrivalEdgeId { return cost * 12 }
        if ctx.priorEdgeIds.contains(edgeID) {
            return cost * max(1, ctx.backtrackFactor)
        }
        return cost
    }

    private func hopCostStep(
        meters edgeMeters: Double,
        edgeIndex ei: Int = -1,
        surface: Int,
        roadClass: Int,
        access: Int,
        confidence: Int,
        profile: RouteProfile,
        ctx: HopSearchContext,
        toLL: CLLocationCoordinate2D,
        endLL: CLLocationCoordinate2D,
        abMeters: Double,
        startSnap: EdgeSnap,
        startOnMajorHighway: Bool,
        endOnMajorHighway: Bool,
        policyUnknown: Bool
    ) -> Double {
        if ei >= 0, GraphV2Pack.isFerryStructure(GraphV2Pack.unpackStructure(pack.edgeAttrs[ei])) {
            let sec = OnDeviceProfileCosts.ferryCrossingSeconds(
                distanceMeters: edgeMeters,
                storedSeconds: pack.crossingSeconds(ei)
            )
            return OnDeviceProfileCosts.ferryRelaxStepCost(crossingSeconds: sec)
        }
        let km = edgeMeters / 1000.0
        switch ctx.costMode {
        case .distance, .balancedResource:
            return km
        case .pavement:
            let paint = OnDeviceProfileCosts.riderPaintSurface(
                surfaceName: OnDeviceProfileCosts.surfaceName(code: surface),
                roadClassName: GraphV2Pack.roadClassName(roadClass)
            )
            let dirt = OnDeviceProfileCosts.isAdventureSurface(paint)
            let surfaceName = OnDeviceProfileCosts.surfaceName(code: surface)
            var step: Double
            let penalized = ei >= 0 && ctx.shortDirtPenaltyEdgeIds.contains(pack.edgeId(ei))
            if penalized || !dirt {
                step = km * HopSearchPolicy.dirtRidePavedPerKm
            } else if surfaceName == "gravel" {
                step = km * HopSearchPolicy.dirtRideGravelPerKm
            } else if surfaceName == "access" || surfaceName == "resource" || surfaceName == "track" {
                step = km * HopSearchPolicy.dirtRideResourcePerKm
            } else {
                step = km * HopSearchPolicy.dirtRideUnknownTrackPerKm
            }
            if !penalized && confidence == 0 { step *= 1.2 }
            step *= OnDeviceProfileCosts.majorHighwayAvoidMult(
                profile: profile,
                roadClassCode: roadClass,
                metersFromStart: meters(toLL, startSnap.projected),
                metersToDestination: meters(toLL, endLL),
                startOnMajorHighway: startOnMajorHighway,
                endOnMajorHighway: endOnMajorHighway,
                avoidMajorHighways: !pack.hasLeaves && ctx.avoidMotorways
            )
            if profile == .cleanest, pack.hasLeaves, ei >= 0, ctx.avoidMotorways || ctx.preferBackRoads {
                step *= RoadTierStats.e4LeafCostMult(
                    tier: pack.roadTier(ei),
                    avoidMotorways: ctx.avoidMotorways,
                    preferBackRoads: ctx.preferBackRoads,
                    metersFromStart: meters(toLL, startSnap.projected),
                    metersToDestination: meters(toLL, endLL),
                    startOnHighway: startOnMajorHighway,
                    endOnHighway: endOnMajorHighway
                )
            }
            return step
        case .profile:
            // Phase E2: Clean + leaves → road-tier × surface-family costs only.
            if profile == .cleanest, pack.hasLeaves, ei >= 0 {
                let tier = pack.roadTier(ei)
                let family = pack.surfaceFamily(ei)
                var step = km * RoadTierStats.cleanLeafCostMult(tier: tier, family: family)
                step *= RoadTierStats.e4LeafCostMult(
                    tier: tier,
                    avoidMotorways: ctx.avoidMotorways,
                    preferBackRoads: ctx.preferBackRoads,
                    metersFromStart: meters(toLL, startSnap.projected),
                    metersToDestination: meters(toLL, endLL),
                    startOnHighway: startOnMajorHighway,
                    endOnHighway: endOnMajorHighway
                )
                return step
            }
            var step = km * OnDeviceProfileCosts.edgeCostPerKm(
                profile: profile,
                surfaceCode: surface,
                roadClassCode: roadClass,
                regionId: pack.regionId,
                accessCode: access,
                confidenceCode: confidence,
                pavedBias: pavedBias
            )
            step *= OnDeviceProfileCosts.pavementLateJoinMult(
                profile: profile,
                surfaceCode: surface,
                distanceToDestinationMeters: meters(toLL, endLL),
                abMeters: abMeters
            )
            step *= OnDeviceProfileCosts.cleanCityStreetMult(
                profile: profile,
                roadClassCode: roadClass,
                distanceToDestinationMeters: meters(toLL, endLL)
            )
            step *= OnDeviceProfileCosts.majorHighwayAvoidMult(
                profile: profile,
                roadClassCode: roadClass,
                metersFromStart: meters(toLL, startSnap.projected),
                metersToDestination: meters(toLL, endLL),
                startOnMajorHighway: startOnMajorHighway,
                endOnMajorHighway: endOnMajorHighway,
                avoidMajorHighways: !pack.hasLeaves && ctx.avoidMotorways
            )
            if profile == .cleanest, pack.hasLeaves, ei >= 0, ctx.avoidMotorways || ctx.preferBackRoads {
                step *= RoadTierStats.e4LeafCostMult(
                    tier: pack.roadTier(ei),
                    avoidMotorways: ctx.avoidMotorways,
                    preferBackRoads: ctx.preferBackRoads,
                    metersFromStart: meters(toLL, startSnap.projected),
                    metersToDestination: meters(toLL, endLL),
                    startOnHighway: startOnMajorHighway,
                    endOnHighway: endOnMajorHighway
                )
            }
            return step
        }
    }

    private func traversalAccessAllowed(ei: Int, from: Int, to: Int, allowUnknown: Bool, profile: RouteProfile) -> Bool {
        if pack.version >= 4, pack.legalTopology {
            let code = pack.v4AccessCode(ei: ei, from: from, to: to)
            // Endpoint-only access is separately scoped by v4HopIllegal.
            return code == 0 || (code == 1 && allowUnknown && profile != .cleanest) || code == 3 || code == 4
        }
        return accessAllowed(GraphV2Pack.unpackAccess(pack.edgeAttrs[ei]), allowUnknown: allowUnknown, profile: profile)
    }

    private func accessAllowed(_ code: Int, allowUnknown: Bool, profile: RouteProfile) -> Bool {
        // Eligibility gate (not a cost). Purple motorized_unknown edges are
        // in the search graph only when Allow unknown is on. Clean never opens them.
        let name = accessName(code)
        if name == "motorized_restricted" || name == "motorized_excluded" { return false }
        if name == "motorized_unknown" { return allowUnknown && profile != .cleanest }
        if name == "motorized_verified" || name == "motorized_permissive" { return true }
        return false
    }
}

private nonisolated struct MinHeap {
    private var items: [(node: Int, cost: Double)] = []

    mutating func push(node: Int, cost: Double) {
        items.append((node, cost))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) >> 1
            if items[p].cost <= items[i].cost { break }
            items.swapAt(p, i)
            i = p
        }
    }

    mutating func pop() -> (node: Int, cost: Double)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let end = items.removeLast()
        if items.isEmpty { return top }
        items[0] = end
        var i = 0
        while true {
            var s = i
            let l = i * 2 + 1
            let r = l + 1
            if l < items.count, items[l].cost < items[s].cost { s = l }
            if r < items.count, items[r].cost < items[s].cost { s = r }
            if s == i { break }
            items.swapAt(s, i)
            i = s
        }
        return top
    }
}

/// Degree-cell index of undirected edges by endpoint bbox. Built once per pack
/// instance so BC (~660k edges) nearest-road snaps stay off the full scan.
private nonisolated final class PackEdgeSpatialIndex: @unchecked Sendable {
    static let shared = PackEdgeSpatialIndexCache()
    static let cellDegrees: Double = 0.05

    private let buckets: [Int64: [Int]]

    init(pack: GraphV2Pack) {
        var map: [Int64: [Int]] = [:]
        guard let fromArr = pack.edgeFrom, let toArr = pack.edgeTo else {
            buckets = [:]
            return
        }
        let cell = Self.cellDegrees
        for ei in 0..<pack.undirectedEdgeCount {
            let a = Int(fromArr[ei])
            let b = Int(toArr[ei])
            guard a >= 0, b >= 0, a < pack.nodeCount, b < pack.nodeCount else { continue }
            let aLon = Double(pack.nodeCoords[a * 2])
            let aLat = Double(pack.nodeCoords[a * 2 + 1])
            let bLon = Double(pack.nodeCoords[b * 2])
            let bLat = Double(pack.nodeCoords[b * 2 + 1])
            let minX = Int(floor(min(aLon, bLon) / cell))
            let maxX = Int(floor(max(aLon, bLon) / cell))
            let minY = Int(floor(min(aLat, bLat) / cell))
            let maxY = Int(floor(max(aLat, bLat) / cell))
            for x in minX...maxX {
                for y in minY...maxY {
                    let key = Self.key(x: x, y: y)
                    map[key, default: []].append(ei)
                }
            }
        }
        buckets = map
    }

    func edgeIndices(nearLat lat: Double, lon: Double, radiusCells: Int) -> [Int] {
        let cell = Self.cellDegrees
        let cx = Int(floor(lon / cell))
        let cy = Int(floor(lat / cell))
        var out: [Int] = []
        let r = max(0, radiusCells)
        for x in (cx - r)...(cx + r) {
            for y in (cy - r)...(cy + r) {
                // Outer ring only when radius > 0 (inner cells already scanned).
                if r > 0,
                   x > cx - r, x < cx + r,
                   y > cy - r, y < cy + r {
                    continue
                }
                if let bucket = buckets[Self.key(x: x, y: y)] {
                    out.append(contentsOf: bucket)
                }
            }
        }
        return out
    }

    private static func key(x: Int, y: Int) -> Int64 {
        (Int64(x) & 0xffff_ffff) << 32 | (Int64(y) & 0xffff_ffff)
    }
}

private nonisolated final class PackEdgeSpatialIndexCache: @unchecked Sendable {
    private let lock = NSLock()
    private weak var cachedPack: GraphV2Pack?
    private var cachedKey: ObjectIdentifier?
    private var cachedGrid: PackEdgeSpatialIndex?

    func grid(for pack: GraphV2Pack) -> PackEdgeSpatialIndex {
        let key = ObjectIdentifier(pack)
        lock.lock()
        if cachedKey == key, cachedPack === pack, let existing = cachedGrid {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let built = PackEdgeSpatialIndex(pack: pack)

        lock.lock()
        if cachedKey == key, cachedPack === pack, let existing = cachedGrid {
            lock.unlock()
            return existing
        }
        cachedPack = pack
        cachedKey = key
        cachedGrid = built
        lock.unlock()
        return built
    }
}
