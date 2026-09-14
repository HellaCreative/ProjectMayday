import CoreLocation
import Foundation

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
    /// Carrier only: no ranking, bucket or termination changes in this stage.
    var owningRideSurfacePrefix: OwningRideSurfacePrefix? = nil
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

    /// Exact internal matching identity, independent of the first traversed
    /// edge (which can differ at a genuine node). Not a presentation model.
    struct MatchedEndpoint: Equatable, Sendable {
        let sourceEpoch: String
        enum Location: Equatable, Sendable {
            case node(Int64)
            case edge(parent: NativeRoutingContinuation.Road, alongMeters: Double, longitude: Double, latitude: Double)
        }
        let location: Location
    }

    struct Result: Sendable {
        var coordinates: [CLLocationCoordinate2D]
        var distanceMeters: Double
        var terminalContinuation: NativeRoutingContinuation? = nil
        /// Preserves per-hop leaf availability when concatenating mixed pack formats.
        var aggregatedSurfaceContribution: NativeRideSurfaceAggregation? = nil
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
        var matchedStart: MatchedEndpoint? = nil
        var matchedEnd: MatchedEndpoint? = nil
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
        /// Whole public calculation wall time; selected-search elapsedMs stays separate.
        var calculationElapsedMs: Int? = nil
        var selectionAttempts: Int? = nil
        var selectionLimitedOutcomes: [String]? = nil
        var rideObjective: String? = nil
        /// Native resource-label objective, in weighted kilometres. Diagnostic
        /// evidence for whole/fractional traversal consistency, not ride distance.
        var resourceSelectionCost: Double? = nil
        var resourceSelectionDirtMeters: Double? = nil
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

    init(pack: GraphV2Pack) {
        self.pack = pack
    }
    /// Balanced ratio-seeking: scale paved km cost. Dirt/Clean stay 1.
    var pavedBias: Double = 1
    /// The owner-required refill approach precedes the recreational ride.
    var initialFuelApproach = false
    /// Single-objective label payload only; graph, queue and indexes are separate.
    var maximumSearchLabelPayloadBytes = 128 * 1024 * 1024
    /// Regional joins are recorded graph nodes, not rider tap locations.
    private var incomingContinuation: NativeRoutingContinuation?
    private var importedArrival: GraphV2Pack.V4TurnStateSpace.ImportedContinuation?
    private var legalTurnState: GraphV2Pack.V4TurnStateSpace?
    var recordedStartNode: Int? = nil
    var recordedEndNode: Int? = nil

    /// Planning-session seed for controlled variety. New process → new seed.
    /// Internal qualification switch; normal routing uses the identical memoized arithmetic.
    var useDirectedStepMemo = true
    var usePackGeometryEnvelope = RoutingWorkContext.usePackGeometryEnvelope
    /// Allocation granularity only; state × bucket identity is unchanged.
    var balancedLabelPageCapacity = 32
    /// Fixed read-pointer metadata, independent of state count; qualified against 256 slots.
    var balancedLabelReadCacheSlots = 4096
    var balancedEnvelopeTimeCapSeconds = HopSearchPolicy.pass2TimeCapSeconds
    private var balancedCalculationDeadline: Double?
    /// Temporary same-binary qualification switch; both paths preserve existing policy.
    var useExtractedFullRoadCost = true
    var useSharedRoadLegality = false // Qualification-only until route A/B passes.
    var useSharedFullRoadPolicy = false // Same-binary qualification only.
    var useSharedCleanPolicyReads = false // Qualification-only until A/B passes.
    var useLabelReadPointerCache = true
    var useScopedRoadBounds = true
    // Confined to one synchronous request; never copied into returned route data.
    private var roadBoundsQuery: ExactSnapIndex.BoundsQuery?
    private var edgeDetailQuery: PagedEdgeDetail.Query?
    /// Qualification only: both walkers preserve the exact predecessor law.
    var useCombinedRetraceCallback = true
    var useReachableCachedMatchesBeforeCoverage = true
    /// Qualification switch for optional station exclusion; exact matching remains mandatory.
    var useStationCoveragePreprobe = true
    /// Qualification-only resource-alternative budget; production retains its existing cap.
    var dirtResourceCandidatePopCapOverride: Int? = nil
    var ridePreferences: RidePreferences?
    private var activeRidePreferences: RidePreferences? {
        guard !initialFuelApproach, let value = ridePreferences else { return nil }
        let normalized = value.normalized
        return normalized == RidePreferences() ? nil : normalized
    }
    var sessionSeed: UInt64 = 0
    /// MapLibre zoom for V4 tap radius. Nil falls back to 550 m, capped at 2000 m.
    var mapZoom: Double? = nil
    /// Optional explicit snap radius, still capped by graph version.
    var matchLimitMeters: Double? = nil
    /// V4 `customers` roads are endpoint-only and open solely for an explicitly
    /// selected service POI, never for an arbitrary rider pin.
    var startEndpointKind: String? = nil
    var endEndpointKind: String? = nil

    /// New packs carry OSM-derived local cores. Static boxes remain a temporary
    /// compatibility fallback for older installed packs.
    private var packUrbanCores: [UrbanCore.Box] {
        activeRidePreferences?.avoidCities == false ? [] : (pack.urbanCores.isEmpty ? UrbanCore.boxes : pack.urbanCores)
    }

    private var packSettlements: [UrbanCore.Box] { activeRidePreferences?.avoidCities == false ? [] : pack.settlements }

    private func settlementBoxes(for profile: RouteProfile) -> [UrbanCore.Box] {
        guard activeRidePreferences?.avoidCities != false else { return [] }
        return UrbanCore.settlementBoxes(
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
    ) throws -> Double? {
        try nearestEdgeSnap(to: point, allowUnknown: allowUnknown, profile: profile)?.distanceMeters
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
        ctx.urbanEdgeMemo = UrbanEdgeMemo(owner: pack,from: from,to: to,boxes: packUrbanCores)
        defer { ctx.urbanEdgeMemo?.recordMeasurements(RoutingWorkContext.measurement) }
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
        arrivalContinuation: NativeRoutingContinuation? = nil,
        backtrackFactor: Double = 4,
        sessionSeed: UInt64? = nil,
        maxRouteMeters: Double? = nil,
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false
    ) -> Swift.Result<Result, Failure> {
        if edgeDetailQuery == nil, let reader = pack.edgeDetailReader {
            do {
                return try reader.withQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { query in
                    var worker = self
                    worker.edgeDetailQuery = query
                    defer { worker.edgeDetailQuery = nil }
                    return worker.routeDetailed(from: from,to: to,profile: profile,
                        allowUnknown: allowUnknown,avoidEdgeIds: avoidEdgeIds,priorEdgeIds: priorEdgeIds,
                        arrivalEdgeId: arrivalEdgeId,arrivalContinuation: arrivalContinuation,
                        backtrackFactor: backtrackFactor,sessionSeed: sessionSeed,maxRouteMeters: maxRouteMeters,
                        cleanMetroMultiplier: cleanMetroMultiplier,avoidMotorways: avoidMotorways,
                        preferBackRoads: preferBackRoads)
                }
            } catch {
                return .failure(.searchLimit(RoutingWorkContext.stopReason ?? "routingDataUnavailable"))
            }
        }
        let calculationStarted = ProcessInfo.processInfo.systemUptime
        let outcome: Swift.Result<Result, Failure> = {
        var worker = self
        worker.balancedCalculationDeadline = profile == .balanced && !initialFuelApproach
            ? CFAbsoluteTimeGetCurrent() + max(0, balancedEnvelopeTimeCapSeconds) : nil
        worker.roadBoundsQuery = nil
        guard useScopedRoadBounds, let index = pack.exactSnapIndex else {
            return worker.routeDetailedWithinBounds(from: from, to: to, profile: profile,
                allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds, priorEdgeIds: priorEdgeIds,
                arrivalEdgeId: arrivalEdgeId, arrivalContinuation: arrivalContinuation,
                backtrackFactor: backtrackFactor, sessionSeed: sessionSeed, maxRouteMeters: maxRouteMeters,
                cleanMetroMultiplier: cleanMetroMultiplier, avoidMotorways: avoidMotorways,
                preferBackRoads: preferBackRoads)
        }
        do {
            // No route or fuel proof escapes until the backing index passes its
            // closing identity check. Matching and town checks share these pages.
            return try index.withBoundsQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { query in
                worker.roadBoundsQuery = query
                defer { worker.roadBoundsQuery = nil }
                return worker.routeDetailedWithinBounds(from: from, to: to, profile: profile,
                allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds, priorEdgeIds: priorEdgeIds,
                arrivalEdgeId: arrivalEdgeId, arrivalContinuation: arrivalContinuation,
                backtrackFactor: backtrackFactor, sessionSeed: sessionSeed, maxRouteMeters: maxRouteMeters,
                cleanMetroMultiplier: cleanMetroMultiplier, avoidMotorways: avoidMotorways,
                preferBackRoads: preferBackRoads)
            }
        } catch {
            return .failure(.searchLimit(RoutingWorkContext.stopReason ?? "roadBoundsUnavailable"))
        }
        }()
        guard case .success(var result) = outcome else { return outcome }
        // Mutable predecessor rewrites can change the reconstructed path after a
        // descendant label was budgeted. Only the returned actual metres prove
        // that this selected route fits; failure does not prove disconnection.
        if let failure = Self.reconstructedDistanceFailure(resultMeters: result.distanceMeters, maximumMeters: maxRouteMeters) {
            return .failure(failure)
        }
        result.searchMeta.calculationElapsedMs = Int((ProcessInfo.processInfo.systemUptime - calculationStarted) * 1000)
        return .success(result)
    }

    /// Matches exceedsLengthSlack's strict spent-distance cap. Its +1 allowance
    /// applies only to reverse lower-bound guidance, not actual travelled metres.
    static func reconstructedDistanceFailure(resultMeters: Double, maximumMeters: Double?) -> Failure? {
        guard let maximumMeters, maximumMeters.isFinite, resultMeters > maximumMeters else { return nil }
        return .searchLimit("reconstructedDistanceExceedsCap")
    }

    private func routeDetailedWithinBounds(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: Set<String> = [],
        priorEdgeIds: Set<String> = [],
        arrivalEdgeId: String? = nil,
        arrivalContinuation: NativeRoutingContinuation? = nil,
        backtrackFactor: Double = 4,
        sessionSeed: UInt64? = nil,
        maxRouteMeters: Double? = nil,
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false
    ) -> Swift.Result<Result, Failure> {
        if let reason = RoutingWorkContext.stopReason { return .failure(.searchLimit(reason)) }
        var worker = self
        worker.incomingContinuation = arrivalContinuation
        if pack.version >= 4, pack.legalTopology {
            worker.legalTurnState = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        }
        if let arrivalContinuation {
            guard let turns = worker.legalTurnState else { return .failure(.searchLimit("legalContinuationUnavailable")) }
            do { worker.importedArrival = try turns.importContinuation(arrivalContinuation, pack: pack) }
            catch { return .failure(.searchLimit("legalContinuationIncompatible")) }
        }
        let routed = worker.routeDetailedImpl(from: from, to: to, profile: profile,
            allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds, priorEdgeIds: priorEdgeIds,
            arrivalEdgeId: arrivalEdgeId, backtrackFactor: backtrackFactor, sessionSeed: sessionSeed,
            maxRouteMeters: maxRouteMeters, cleanMetroMultiplier: cleanMetroMultiplier,
            avoidMotorways: avoidMotorways, preferBackRoads: preferBackRoads)
        guard case .success(var result) = routed else {
            if case .failure(.noPath) = routed, let arrival = arrivalContinuation,
               case .edge = arrival.location,
               !arrival.restrictionContext.isEmpty || !arrival.activeRestrictions.isEmpty {
                return .failure(.searchLimit("legalContinuationDirectionUnavailable"))
            }
            return routed
        }
        if result.searchMeta.rideObjective == "initial-fuel-presence" {
            return .success(result) // No movement means no invented incoming direction.
        }
        if let turns = worker.legalTurnState {
            do { result.terminalContinuation = try worker.terminalContinuation(for: result, turns: turns) }
            catch { return .failure(.searchLimit(RoutingWorkContext.stopReason ?? "legalContinuationOrGeometryUnavailable")) }
        }
        return .success(result)
    }

    private func routeDetailedImpl(
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
        if let reason = RoutingWorkContext.stopReason { return .failure(.searchLimit(reason)) }
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
        // Initial matching already ran the distance-only access/turn search;
        // recreational wall fallbacks would repeat the identical calculation.
        if initialFuelApproach { return pavedWall }
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
    ) throws -> [Double]? {
        let measurement = RoutingWorkContext.measurement
        let measuredPhase = measurement?.begin(.reverseGuidance)
        defer { measurement?.end(measuredPhase) }
        _ = cityWall
        let snaps = try Self.rangeSnapCache.snaps(pack: pack, point: from,
            profile: profile, allowUnknown: allowUnknown) {
            try nearestEdgeSnaps(to: from, allowUnknown: allowUnknown, profile: profile,
                maxMeters: Self.preferredMatchMeters)
        }
        guard !snaps.isEmpty else {
            return nil
        }
        let n = pack.nodeCount
        guard n > 0 else { return nil }
        measurement?.increment(.labelsCreated, by: UInt64(n))
        var dist = [Double](repeating: .infinity, count: n)
        var prevEdge = [Int](repeating: -1, count: n)
        var heap = MinHeap()
        defer { heap.flushMeasurement() }
        // Seed every nearby eligible edge, not only the geometric nearest.
        // Fuel forecourts and GPS fixes often sit beside a disconnected service
        // spur while a through-road is only a few metres farther away.
        for snap in snaps {
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
            try RoutingWorkContext.check()
            if cur.cost != dist[cur.node] { continue }
            if cur.cost > maxMeters { break }
            let arcStart = Int(pack.nodeOffsets[cur.node])
            let arcEnd = Int(pack.nodeOffsets[cur.node + 1])
            guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
            heap.recordExpansion(arcs: arcEnd - arcStart)
            for i in arcStart..<arcEnd {
                let toNode = Int(pack.edgeTargets[i])
                let ei = Int(pack.edgeUndirectedIndex[i])
                guard ei >= 0, ei < pack.undirectedEdgeCount, toNode >= 0, toNode < n else { continue }
                if prevEdge[cur.node] == ei { continue }
                if pack.version >= 4, pack.legalTopology {
                    // Reachability discovery is an admissible lower bound. It
                    // may include endpoint-only edges, but never denied,
                    // impassable, or disabled unknown directions. Exact turn
                    // and endpoint legality is proved by the final route.
                    let code = Int(pack.v4AccessCode(ei: ei, from: cur.node, to: toNode))
                    if code == 2 || code == 5 || (code == 1 && !policyUnknown) { continue }
                } else {
                    let access = GraphV2Pack.unpackAccess(pack.edgeAttrs[ei])
                    if !accessAllowed(access, allowUnknown: policyUnknown, profile: profile) { continue }
                }
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
        allowUnknown: Bool,
        from origin: CLLocationCoordinate2D? = nil
    ) throws -> Double? {
        var best = Double.infinity
        let snaps = try Self.rangeSnapCache.snaps(pack: pack, point: point,
            profile: profile, allowUnknown: allowUnknown) {
            try nearestEdgeSnaps(to: point, allowUnknown: allowUnknown, profile: profile,
                maxMeters: Self.preferredMatchMeters)
        }
        let origins: [EdgeSnap]
        if let origin {
            origins = try Self.rangeSnapCache.snaps(pack: pack, point: origin,
                profile: profile, allowUnknown: allowUnknown) {
                try nearestEdgeSnaps(to: origin, allowUnknown: allowUnknown, profile: profile,
                    maxMeters: Self.preferredMatchMeters)
            }
        } else { origins = [] }
        let policyUnknown = allowUnknown && profile != .cleanest
        func permits(_ edge: Int, _ from: Int, _ to: Int) -> Bool {
            guard pack.hasDirectedArc(from: from, to: to, edge: edge) else { return false }
            guard pack.version >= 4, pack.legalTopology else { return true }
            let code = Int(pack.v4AccessCode(ei: edge, from: from, to: to))
            return code != 2 && code != 5 && (code != 1 || policyUnknown)
        }
        for snap in snaps {
            guard snap.edgeIndex >= 0, snap.edgeIndex < pack.undirectedEdgeCount else { continue }
            let edgeM = Double(pack.edgeMeters[snap.edgeIndex])
            let access = max(0, snap.distanceMeters)
            // Node-only fields cannot represent a short interior-edge approach
            // when neither endpoint is inside the range. Preserve its directed
            // fractional path, just as regional fuelRoadDistances does. This
            // remains relaxed guidance; it does not certify turn/endpoint law.
            for origin in origins where origin.edgeIndex == snap.edgeIndex {
                let delta = snap.distanceAlongM - origin.distanceAlongM
                if (delta >= 0 && permits(snap.edgeIndex, snap.nodeA, snap.nodeB)) ||
                   (delta <= 0 && permits(snap.edgeIndex, snap.nodeB, snap.nodeA)) {
                    best = min(best, max(0, origin.distanceMeters) + abs(delta) + access)
                }
            }
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
    ) throws -> [String: Double] {
        let wall = true
        guard let dist = try exploreNodeMeters(
            from: from, toward: toward, maxMeters: maxMeters, profile: profile,
            allowUnknown: allowUnknown, cityWall: wall
        ) else { return [:] }
        // Keep origin interior-edge stations in the full matching path even
        // when both endpoints lie beyond the bounded range field.
        let origins = try Self.rangeSnapCache.snaps(pack: pack,point: from,
            profile: profile,allowUnknown: allowUnknown) {
            try nearestEdgeSnaps(to: from,allowUnknown: allowUnknown,profile: profile,
                maxMeters: Self.preferredMatchMeters)
        }
        let protectedEdges = Set(origins.map(\.edgeIndex))
        var skipped = 0
        defer { RoutingWorkContext.measurement?.increment(.stationMatchesSkipped,by: UInt64(skipped)) }
        var out: [String: Double] = [:]
        for pump in pumps {
            try RoutingWorkContext.check()
            let ll = CLLocationCoordinate2D(latitude: pump.latitude, longitude: pump.longitude)
            // Existing exact matches are reevaluated against this current field below.
            let cached = useReachableCachedMatchesBeforeCoverage
                ? try Self.rangeSnapCache.cached(pack: pack, point: ll,
                    profile: profile, allowUnknown: allowUnknown) : nil
            if cached != nil {
                RoutingWorkContext.measurement?.increment(.rangeSnapCoverageBypasses)
            }
            if useStationCoveragePreprobe, cached == nil, try stationCoverageCannotReach(ll, distances: dist, nodeOffset: 0,
                protectedEdges: protectedEdges) {
                skipped += 1
                continue
            }
            if let m = try graphMeters(to: ll, dist: dist, profile: profile, allowUnknown: allowUnknown, from: from),
               m <= maxMeters {
                out[pump.id] = m
            }
        }
        return out
    }

    private static let stationCoverageCache = StationCoverageCache()
    private func forEachStationCoverageEdge(_ point: CLLocationCoordinate2D,meters: Double,
        index: ExactSnapIndex,bounds: ExactSnapIndex.BoundsQuery, cellSuperset: Bool = false,
        visit: (Int) throws -> Void) throws {
        if usePackGeometryEnvelope,
           try !bounds.mayContainMatch(latitude: point.latitude, longitude: point.longitude, meters: meters) {
            RoutingWorkContext.measurement?.increment(.snapEnvelopeRejectedQueries)
            return
        }
        // Caller retains the validated index query around both cache hits and
        // misses, including its final source/cancellation check.
        try Self.stationCoverageCache.enumerate(owner: pack,index: index,
            latitude: point.latitude,longitude: point.longitude,meters: meters,cellSuperset: cellSuperset,
            cancelled: { RoutingWorkContext.stopReason != nil },visit: visit) { emit in
            var examined = 0, boundsChecks = 0
            defer {
                RoutingWorkContext.measurement?.increment(.stationCoverageEdgesScanned,by: UInt64(examined))
                RoutingWorkContext.measurement?.increment(.stationCoverageBoundsChecks,by: UInt64(boundsChecks))
            }
            let radius = try StationCoverageCache.coverageRadius(meters: meters)
            for ring in 0...radius {
                try index.forEachEdge(nearLat: point.latitude,lon: point.longitude,radiusCells: ring,
                    query: bounds,cancelled: { RoutingWorkContext.stopReason != nil }) { edge in
                    examined += 1
                    if !cellSuperset {
                        boundsChecks += 1
                        guard try bounds.mayIntersect(edge: edge,latitude: point.latitude,
                            longitude: point.longitude,meters: meters) else { return }
                    }
                    try emit(edge)
                }
            }
        }
    }

    /// Probe the complete existing snap coverage. A superset is intentional:
    /// no candidate is removed from the ordinary geometry matcher.
    private func stationCoverageCannotReach(_ point: CLLocationCoordinate2D,
        distances: [Double], nodeOffset: Int, protectedEdges: Set<Int>,
        maxMeters: Double = Self.preferredMatchMeters) throws -> Bool {
        guard pack.version >= 4, pack.legalTopology,
              let index = pack.exactSnapIndex, let edgeFrom = pack.edgeFrom,
              let edgeTo = pack.edgeTo, maxMeters.isFinite, maxMeters > 0, nodeOffset >= 0,
              nodeOffset <= distances.count,
              pack.nodeCount <= distances.count - nodeOffset else { return false }
        var endpointBoundsChecks = 0
        defer { RoutingWorkContext.measurement?.increment(.stationCoverageBoundsChecks,by: UInt64(endpointBoundsChecks)) }
        return try index.withBoundsQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { bounds in
            guard try index.hasCompleteEndpointCoverage(query: bounds) else { return false }
            return try StationFieldProbe.canSkip(completedField: true, distances: distances,
                protectedEdges: protectedEdges, boundsMayIntersect: { edge in
                    endpointBoundsChecks += 1
                    return try bounds.mayIntersect(edge: edge,latitude: point.latitude,longitude: point.longitude,meters: maxMeters)
                }) { visit in
                try forEachStationCoverageEdge(point,meters: maxMeters,index: index,bounds: bounds,cellSuperset: true) { edge in
                        guard edgeFrom.indices.contains(edge), edgeTo.indices.contains(edge) else {
                            try visit(edge, -1, -1)
                            return
                        }
                        let a = Int(edgeFrom[edge]), b = Int(edgeTo[edge])
                        guard a >= 0, b >= 0, a < pack.nodeCount, b < pack.nodeCount else {
                            try visit(edge, -1, -1)
                            return
                        }
                        try visit(edge, nodeOffset + a, nodeOffset + b)
                }
            }
        }
    }

    private func stationCoverageCannotReach(_ point: CLLocationCoordinate2D,
        isPossiblyReachedNode: @escaping (Int) -> Bool, nodeOffset: Int, protectedEdges: Set<Int>,
        maxMeters: Double = Self.preferredMatchMeters) throws -> Bool {
        guard pack.version >= 4, pack.legalTopology,
              let index = pack.exactSnapIndex, let edgeFrom = pack.edgeFrom,
              let edgeTo = pack.edgeTo, maxMeters.isFinite, maxMeters > 0, nodeOffset >= 0 else { return false }
        var endpointBoundsChecks = 0
        defer { RoutingWorkContext.measurement?.increment(.stationCoverageBoundsChecks,by: UInt64(endpointBoundsChecks)) }
        return try index.withBoundsQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { bounds in
            guard try index.hasCompleteEndpointCoverage(query: bounds) else { return false }
            return try StationFieldProbe.canSkip(completedField: true, protectedEdges: protectedEdges,
                isPossiblyReachedNode: isPossiblyReachedNode, boundsMayIntersect: { edge in
                    endpointBoundsChecks += 1
                    return try bounds.mayIntersect(edge: edge,latitude: point.latitude,longitude: point.longitude,meters: maxMeters)
                }) { visit in
                try forEachStationCoverageEdge(point,meters: maxMeters,index: index,bounds: bounds,cellSuperset: true) { edge in
                        guard edgeFrom.indices.contains(edge), edgeTo.indices.contains(edge) else {
                            try visit(edge, -1, -1)
                            return
                        }
                        let a = Int(edgeFrom[edge]), b = Int(edgeTo[edge])
                        guard a >= 0, b >= 0, a < pack.nodeCount, b < pack.nodeCount else {
                            try visit(edge, -1, -1)
                            return
                        }
                        try visit(edge, nodeOffset + a, nodeOffset + b)
                }
            }
        }
    }

    struct RelaxedArrivalFuelField: Sendable {
        let reachedNodes: Set<Int>
        let protectedEdges: Set<Int>
        let reachesRecordedBorder: Bool
    }

    /// These caps bound an optional proof accelerator, never routing behavior.
    /// Exhaustion discards the incomplete field and retains every station.
    struct RelaxedArrivalFuelFieldLimits: Sendable {
        var maximumStates: Int = 32_768
        var maximumQueueEntries: Int = 65_536
        var maximumBorderNodes: Int = 32_768
    }

    /// A strict relaxation of every legal continuation: fractional arrivals
    /// start at both parent ends for zero cost; turns, access, and profile
    /// preferences are omitted. No snap offset or geographic metric is charged.
    func relaxedArrivalFuelField(arrival: NativeRoutingContinuation,
                                 remainingMeters: Double,
                                 limits: RelaxedArrivalFuelFieldLimits = .init()) throws -> RelaxedArrivalFuelField? {
        try RoutingWorkContext.check()
        let measurement = RoutingWorkContext.measurement
        let phase = measurement?.begin(.reverseGuidance)
        defer { measurement?.end(phase) }
        guard pack.version >= 4, pack.legalTopology,
              pack.osmNodeIds.count == pack.nodeCount,
              remainingMeters.isFinite, remainingMeters >= 0,
              limits.maximumStates > 0, limits.maximumQueueEntries > 0,
              limits.maximumBorderNodes >= 0 else { return nil }
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        guard let imported = try? turns.importContinuation(arrival, pack: pack) else { return nil }
        let seeds: Set<Int>
        switch imported.location {
        case .node: seeds = [imported.toNode]
        case .edge: seeds = [imported.fromNode, imported.toNode]
        }
        guard let distances = try relaxedFuelDistances(seeds: seeds, maximumMeters: remainingMeters, limits: limits) else { return nil }
        return .init(reachedNodes: Set(distances.keys), protectedEdges: [imported.incomingEdge], reachesRecordedBorder: false)
    }

    private func relaxedFuelDistances(seeds: Set<Int>, maximumMeters: Double,
        limits: RelaxedArrivalFuelFieldLimits) throws -> [Int: Double]? {
        let remainingMeters = maximumMeters
        let measurement = RoutingWorkContext.measurement
        var borderNodes: Set<Int64> = []
        for anchors in pack.crossPackSeams.values {
            for anchor in anchors {
                try RoutingWorkContext.check()
                guard let node = anchor.osmNodeId else { return nil }
                if !borderNodes.contains(node) {
                    guard borderNodes.count < limits.maximumBorderNodes else { return nil }
                    borderNodes.insert(node)
                }
            }
        }
        guard seeds.count <= limits.maximumStates,
              seeds.count <= limits.maximumQueueEntries else { return nil }
        var distances: [Int: Double] = [:]
        var heap = MinHeap()
        defer { heap.flushMeasurement() }
        for node in seeds {
            guard node >= 0, node < pack.nodeCount else { return nil }
            distances[node] = 0
            measurement?.increment(.labelsCreated)
            heap.push(node: node, cost: 0)
        }
        while let current = heap.pop() {
            try RoutingWorkContext.check()
            guard distances[current.node] == current.cost else { continue }
            // A reached recorded border makes a single-pack negative proof
            // insufficient. Stop this optional accelerator immediately.
            if borderNodes.contains(pack.osmNodeIds[current.node]) { return nil }
            let start = Int(pack.nodeOffsets[current.node]), end = Int(pack.nodeOffsets[current.node + 1])
            guard start >= 0, end >= start, end <= pack.edgeTargets.count else { return nil }
            for arc in start..<end {
                try RoutingWorkContext.check()
                let target = Int(pack.edgeTargets[arc]), edge = Int(pack.edgeUndirectedIndex[arc])
                guard target >= 0, target < pack.nodeCount,
                      edge >= 0, edge < pack.edgeMeters.count else { return nil }
                let cost = current.cost + Double(pack.edgeMeters[edge])
                if cost <= remainingMeters, cost < (distances[target] ?? .infinity) {
                    guard heap.count < limits.maximumQueueEntries else { return nil }
                    if distances[target] == nil {
                        guard distances.count < limits.maximumStates else { return nil }
                        measurement?.increment(.labelsCreated)
                    }
                    distances[target] = cost
                    heap.push(node: target, cost: cost)
                }
            }
        }
        return distances
    }

    /// False means only "still needs actual matching and legal routing".
    func stationOutsideRelaxedArrivalField(_ point: CLLocationCoordinate2D,
        field: RelaxedArrivalFuelField, maxMeters: Double) throws -> Bool {
        guard !field.reachesRecordedBorder,
              let index = pack.exactSnapIndex, let edgeFrom = pack.edgeFrom, let edgeTo = pack.edgeTo,
              maxMeters.isFinite, maxMeters > 0 else { return false }
        var endpointBoundsChecks = 0
        defer { RoutingWorkContext.measurement?.increment(.stationCoverageBoundsChecks,by: UInt64(endpointBoundsChecks)) }
        return try index.withBoundsQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { bounds in
            guard try index.hasCompleteEndpointCoverage(query: bounds) else { return false }
            return try StationFieldProbe.canSkip(completedField: true, protectedEdges: field.protectedEdges,
                isPossiblyReachedNode: { node in
                    node >= self.pack.nodeCount || field.reachedNodes.contains(node)
                }, boundsMayIntersect: { edge in
                    endpointBoundsChecks += 1
                    return try bounds.mayIntersect(edge: edge,latitude: point.latitude,longitude: point.longitude,meters: maxMeters)
                }) { visit in
                try forEachStationCoverageEdge(point,meters: maxMeters,index: index,bounds: bounds,cellSuperset: true) { edge in
                        guard edgeFrom.indices.contains(edge), edgeTo.indices.contains(edge) else {
                            try visit(edge, -1, -1); return
                        }
                        try visit(edge, Int(edgeFrom[edge]), Int(edgeTo[edge]))
                }
            }
        }
    }

    /// Bounds refer to the actual endpoint-match radius, not the old fuel
    /// discovery radius. Index envelopes are a superset of every eligible snap.
    private static let initialFuelBoundMemo = InitialFuelBoundMemo()
    func initialStationLowerBounds(from origin: CLLocationCoordinate2D,
        stations: [(point: CLLocationCoordinate2D, matchMeters: Double)], incumbentMeters: Double,
        sourceIdentity: String? = nil,
        limits: RelaxedArrivalFuelFieldLimits = .init()) throws -> [Double]? {
        guard let sourceIdentity, !sourceIdentity.isEmpty, let index = pack.exactSnapIndex,
              stations.count <= InitialFuelBoundMemo.maximumStations,
              sourceIdentity.utf8.count <= InitialFuelBoundMemo.maximumIdentityBytes else {
            return try uncachedInitialStationLowerBounds(from: origin, stations: stations,
                incumbentMeters: incumbentMeters, limits: limits)
        }
        let input = InitialFuelBoundMemo.Input(sourceIdentity: sourceIdentity,
            origin: .init(latitude: origin.latitude, longitude: origin.longitude, meters: 0),
            stations: stations.map { .init(latitude: $0.point.latitude,
                longitude: $0.point.longitude, meters: $0.matchMeters) },
            incumbentMeters: incumbentMeters, maximumStates: limits.maximumStates,
            maximumQueueEntries: limits.maximumQueueEntries, maximumBorderNodes: limits.maximumBorderNodes)
        return try Self.initialFuelBoundMemo.value(owner: pack, index: index, input: input,
            validate: {
                try RoutingWorkContext.check()
                try index.withBoundsQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { _ in
                    try pack.geometry?.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
                }
            }, compute: {
                try uncachedInitialStationLowerBounds(from: origin, stations: stations,
                    incumbentMeters: incumbentMeters, limits: limits)
            })
    }

    private func uncachedInitialStationLowerBounds(from origin: CLLocationCoordinate2D,
        stations: [(point: CLLocationCoordinate2D, matchMeters: Double)], incumbentMeters: Double,
        limits: RelaxedArrivalFuelFieldLimits) throws -> [Double]? {
        try RoutingWorkContext.check()
        let phase = RoutingWorkContext.measurement?.begin(.reverseGuidance)
        defer { RoutingWorkContext.measurement?.end(phase) }
        guard pack.version >= 4, pack.legalTopology, pack.osmNodeIds.count == pack.nodeCount,
              incumbentMeters.isFinite, incumbentMeters >= 0,
              limits.maximumStates > 0, limits.maximumQueueEntries > 0,
              limits.maximumBorderNodes >= 0, !stations.isEmpty else { return nil }
        let originCap = stations.map { $0.matchMeters }.max() ?? 0
        guard originCap.isFinite, originCap > 0 else { return nil }
        var seeds: Set<Int> = [], protected: Set<Int> = []
        var capacityExceeded = false
        let originComplete = try enumerateInitialMatchCoverage(origin, meters: originCap) { edge, a, b in
            if seeds.count >= limits.maximumStates || protected.count >= limits.maximumStates {
                capacityExceeded = true; return
            }
            seeds.insert(a); seeds.insert(b); protected.insert(edge)
        }
        guard originComplete, !capacityExceeded, !seeds.isEmpty,
              seeds.count <= limits.maximumStates else { return nil }
        guard let distances = try relaxedFuelDistances(seeds: seeds, maximumMeters: incumbentMeters, limits: limits) else { return nil }
        var result: [Double] = []
        for station in stations {
            try RoutingWorkContext.check()
            var lower = Double.infinity
            let complete = try enumerateInitialMatchCoverage(station.point, meters: station.matchMeters) { edge, a, b in
                if protected.contains(edge) { lower = 0 }
                else { lower = min(lower, distances[a] ?? .infinity, distances[b] ?? .infinity) }
            }
            guard complete else { return nil }
            result.append(lower)
        }
        return result
    }

    private func enumerateInitialMatchCoverage(_ point: CLLocationCoordinate2D, meters: Double,
        visit: (Int, Int, Int) throws -> Void) throws -> Bool {
        guard meters.isFinite, meters > 0, let index = pack.exactSnapIndex,
              let from = pack.edgeFrom, let to = pack.edgeTo else { return false }
        var valid = true
        try index.withBoundsQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { bounds in
            try forEachStationCoverageEdge(point,meters: meters,index: index,bounds: bounds) { edge in
                    guard from.indices.contains(edge), to.indices.contains(edge),
                          Int(from[edge]) >= 0, Int(to[edge]) >= 0,
                          Int(from[edge]) < pack.nodeCount, Int(to[edge]) < pack.nodeCount else {
                        valid = false; return
                    }
                    try visit(edge, Int(from[edge]), Int(to[edge]))
            }
        }
        return valid
    }

    /// Temporary dense distance guidance; extract only portal values and release
    /// the field before routing. This is not a full legal-tail proof. Endpoint
    /// seeds cover ALL geometric matching possibilities conservatively, with
    /// partial road distance and the existing charged final-stitch cost. No geometric-distance assumption.
    static func recordedTailLowerBounds(packs: [GraphV2Pack],
        seamSnapshots: [[String: [GraphV2Pack.CrossPackSeamAnchor]]],
        destination: CLLocationCoordinate2D, mapZoom: Double?, matchLimitMeters: Double?) throws
        -> [String: [Int64: Double]] {
        try RoutingWorkContext.check()
        guard let destinationPack = packs.last, packs.count >= 2,
              packs.allSatisfy({ $0.version >= 4 && $0.legalTopology }),
              seamSnapshots.count == packs.count else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
        let phase = RoutingWorkContext.measurement?.begin(.reverseGuidance)
        defer { RoutingWorkContext.measurement?.end(phase) }
        var offsets: [Int] = [], total = 0
        for pack in packs { offsets.append(total); total += pack.nodeCount }
        var extra: [Int: [RoadCompass.Arc]] = [:]
        var requested: [Int: [Int64: Int]] = [:]
        for index in packs.indices {
            try RoutingWorkContext.check()
            for other in packs.indices where other > index {
                guard let localID = packs[index].regionId?.lowercased(),
                      let remoteID = packs[other].regionId?.lowercased() else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
                for pair in try ExactGuidanceSeams.connections(local: packs[index], remote: packs[other],
                    anchors: seamSnapshots[index][remoteID] ?? [], reverse: seamSnapshots[other][localID] ?? []) {
                    let a = offsets[index] + pair.localNode, b = offsets[other] + pair.remoteNode
                    extra[a, default: []].append(.init(to: b, edge: -1, meters: 0))
                    extra[b, default: []].append(.init(to: a, edge: -1, meters: 0))
                    requested[index, default: [:]][packs[index].osmNodeIds[pair.localNode]] = a
                    requested[other, default: [:]][packs[other].osmNodeIds[pair.remoteNode]] = b
                }
            }
        }
        let cap = TapRadius.meters(zoom: mapZoom, latitude: destination.latitude,
            requestedMeters: matchLimitMeters, graphBinaryVersion: Int(destinationPack.version))
        let destinationRouter = OnDeviceRouter(pack: destinationPack)
        var rejections: [String] = []
        let matches = try destinationRouter.nearestEdgeSnaps(to: destination,
            allowUnknown: true, profile: .dirt, maxMeters: cap,
            rejections: &rejections, collectAllGeometricMatches: true)
        guard !matches.isEmpty else {
            throw RoutingError.fuelUnknown("Destination matching coverage is incomplete; regional tail distance is unverified.")
        }
        let target = total, lastOffset = offsets[offsets.count - 1]
        for snap in matches {
            try RoutingWorkContext.check()
            let along = max(0, snap.distanceAlongM)
            let stored = Double(destinationPack.edgeMeters[snap.edgeIndex])
            guard let geometry = try destinationRouter.edgeGeometry(snap.edgeIndex), geometry.count >= 2 else {
                throw RoutingError.fuelUnknown("Destination road geometry is unavailable.")
            }
            let geometryLeft = destinationRouter.lineMeters(destinationRouter.coordsFromAToMatch(geometry, snap: snap))
            let geometryRight = destinationRouter.lineMeters(destinationRouter.coordsFromMatchToB(geometry, snap: snap))
            let stitch = destinationRouter.softStitchStub(tap: destination, snap: snap, idSuffix: "end")?.distanceMeters ?? 0
            let left = min(along, geometryLeft) + stitch
            let right = min(max(0, stored - along), geometryRight) + stitch
            guard left.isFinite, right.isFinite else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
            // Both directions, all geometric parents, no intent shortlist.
            // The existing final-stitch helper supplies exactly the charged
            // distance, including its accepted omission outside the stitch range.
            extra[lastOffset + snap.nodeA, default: []].append(.init(to: target, edge: snap.edgeIndex, meters: left))
            extra[lastOffset + snap.nodeB, default: []].append(.init(to: target, edge: snap.edgeIndex, meters: right))
        }
        var invalid = false
        let field = RoadCompass.build(stateCount: total + 1, destination: target, reverse: true,
            recordSuccessors: false, cancelled: { RoutingWorkContext.stopReason != nil || invalid }) { state, visit in
            for arc in extra[state] ?? [] { visit(arc) }
            guard state < total, let index = packs.indices.last(where: { offsets[$0] <= state }) else { return }
            let pack = packs[index], node = state - offsets[index]
            guard node >= 0, node < pack.nodeCount, pack.nodeOffsets.indices.contains(node + 1) else { invalid = true; return }
            let start = Int(pack.nodeOffsets[node]), end = Int(pack.nodeOffsets[node+1])
            guard start >= 0, end >= start, end <= pack.edgeTargets.count, end <= pack.edgeUndirectedIndex.count else { invalid = true; return }
            for arc in start..<end {
                let edge = Int(pack.edgeUndirectedIndex[arc]), next = Int(pack.edgeTargets[arc])
                guard next >= 0, next < pack.nodeCount, pack.edgeMeters.indices.contains(edge) else { invalid = true; return }
                // Ignore access/turn preferences only in this LOWER BOUND. The
                // actual approach and remaining tail retain all legal rules.
                visit(.init(to: offsets[index] + next, edge: edge, meters: Double(pack.edgeMeters[edge])))
            }
        }
        try RoutingWorkContext.check()
        guard !invalid, field.status == "complete" else {
            throw RoutingError.fuelUnknown("Regional tail distance preparation did not complete.")
        }
        var result: [String: [Int64: Double]] = [:]
        for (index, nodes) in requested {
            guard let region = packs[index].regionId?.lowercased() else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
            for (original, global) in nodes { result[region, default: [:]][original] = field.remaining[global] }
        }
        return result
    }

    /// A direction-aware distance field over installed packs and reciprocal
    /// recorded seams. This is guidance: exact routes still prove turn legality.
    static func fuelRoadDistances(packs: [GraphV2Pack],
                                  seamSnapshots: [[String: [GraphV2Pack.CrossPackSeamAnchor]]]? = nil,
                                  anchor: CLLocationCoordinate2D,
                                  points: [CLLocationCoordinate2D], profile: RouteProfile,
                                  allowUnknown: Bool, reverse: Bool,
                                  useCachedMatchesBeforeCoverage: Bool = true,
                                  useStationCoveragePreprobe: Bool = true,
                                  forwardRangeMeters: Double? = nil,
                                  forwardFieldLimits: BoundedForwardFuelField.Limits = .init()) throws -> [Double]? {
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        var diagnosticStatus = "incomplete", matchingStage = "anchor"
        var matchCounts: [String: Int] = [:], matchSeconds: [String: Double] = [:]
        var seamSeconds = 0.0, fieldSeconds = 0.0, coverageSeconds = 0.0, coverageCalls = 0
        var diagnosticSkipped = 0, forwardPreparation = "none"
        defer {
            let matches = ["anchor", "seam", "station"].map {
                "\($0):\(matchCounts[$0, default: 0])/\(matchSeconds[$0, default: 0])s"
            }.joined(separator: ",")
            let diagnosticLine = "fuel field profile=\(profile) reverse=\(reverse) anchor=\(anchor.latitude),\(anchor.longitude) points=\(points.count) packs=\(packs.compactMap(\.regionId).joined(separator: ",")) status=\(diagnosticStatus) stop=\(RoutingWorkContext.stopReason ?? "none") elapsed=\(ProcessInfo.processInfo.systemUptime - diagnosticStart)s matchMisses=\(matches) seamPrep=\(seamSeconds)s fieldBuild=\(fieldSeconds)s coverage=\(coverageCalls)/\(coverageSeconds)s skipped=\(diagnosticSkipped) forward=\(forwardPreparation)"
            Task { @MainActor in RoutingDebugLog.shared.event(diagnosticLine) }
        }
        let seams = seamSnapshots ?? packs.map(\.crossPackSeams)
        guard seams.count == packs.count else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
        let routers = packs.map { OnDeviceRouter(pack: $0) }
        var offsets: [Int] = [], count = 0
        for pack in packs { offsets.append(count); count += pack.nodeCount }
        guard count > 0 else { return nil }
        var extra: [Int: [RoadCompass.Arc]] = [:]
        let policyUnknown = allowUnknown && profile != .cleanest
        func permitted(_ pack: GraphV2Pack, from: Int, to: Int, edge: Int) -> Bool {
            guard pack.hasDirectedArc(from: from, to: to, edge: edge) else { return false }
            if pack.version >= 4, pack.legalTopology {
                let code = Int(pack.v4AccessCode(ei: edge, from: from, to: to))
                return code != 2 && code != 5 && (code != 1 || policyUnknown)
            }
            return true // Legacy snap eligibility already checks access.
        }
        func snaps(_ point: CLLocationCoordinate2D, _ index: Int) throws -> [EdgeSnap] {
            let router = routers[index]
            return try Self.rangeSnapCache.snaps(pack: packs[index], point: point,
                profile: profile, allowUnknown: allowUnknown) {
                let began = ProcessInfo.processInfo.systemUptime
                let stage = matchingStage
                matchCounts[stage, default: 0] += 1
                defer { matchSeconds[stage, default: 0] += ProcessInfo.processInfo.systemUptime - began }
                return try router.nearestEdgeSnaps(to: point, allowUnknown: allowUnknown,
                    profile: profile, maxMeters: Self.preferredMatchMeters)
            }
        }
        func attach(_ point: CLLocationCoordinate2D, index: Int, virtual: Int, edgeID: String? = nil) throws {
            let pack = packs[index], offset = offsets[index]
            for snap in try snaps(point, index) where edgeID == nil
                || (String(pack.osmWayIds[snap.edgeIndex]) == edgeID?.split(separator: ":").first.map(String.init)
                    && snap.distanceMeters <= 2) {
                let ei = snap.edgeIndex, a = offset + snap.nodeA, b = offset + snap.nodeB
                let left = max(0, snap.distanceAlongM) + snap.distanceMeters
                let right = max(0, Double(pack.edgeMeters[ei]) - snap.distanceAlongM) + snap.distanceMeters
                if permitted(pack, from: snap.nodeA, to: snap.nodeB, edge: ei) {
                    extra[a, default: []].append(.init(to: virtual, edge: ei, meters: left))
                    extra[virtual, default: []].append(.init(to: b, edge: ei, meters: right))
                }
                if permitted(pack, from: snap.nodeB, to: snap.nodeA, edge: ei) {
                    extra[b, default: []].append(.init(to: virtual, edge: ei, meters: right))
                    extra[virtual, default: []].append(.init(to: a, edge: ei, meters: left))
                }
            }
        }
        let anchorNode = count; count += 1
        for index in packs.indices { try attach(anchor, index: index, virtual: anchorNode) }
        matchingStage = "seam"
        let seamBegan = ProcessInfo.processInfo.systemUptime
        do {
        defer { seamSeconds = ProcessInfo.processInfo.systemUptime - seamBegan }
        for index in packs.indices {
            try RoutingWorkContext.check()
            let pack = packs[index]
            for other in packs.indices where other > index {
                let remote = packs[other]
                guard let localID = pack.regionId?.lowercased(), let remoteID = remote.regionId?.lowercased() else { continue }
                if pack.version >= 4 || remote.version >= 4 {
                    let connections = try ExactGuidanceSeams.connections(local: pack, remote: remote,
                        anchors: seams[index][remoteID] ?? [],
                        reverse: seams[other][localID] ?? [])
                    for connection in connections {
                        let a = offsets[index] + connection.localNode
                        let b = offsets[other] + connection.remoteNode
                        // Same original graph node, not a spatial connector. Road
                        // direction/access remains on incident arcs; turn state is
                        // proved by the later actual route, never this guidance.
                        extra[a, default: []].append(.init(to: b, edge: -1, meters: 0))
                        extra[b, default: []].append(.init(to: a, edge: -1, meters: 0))
                    }
                    continue
                }
                for seam in pack.crossPackSeams[remoteID] ?? [] {
                    guard seam.gapMeters <= 2,
                        let reciprocal = (remote.crossPackSeams[localID] ?? []).first(where: {
                            $0.osmWayId == seam.osmWayId && $0.localEdgeId == seam.remoteEdgeId
                                && $0.remoteEdgeId == seam.localEdgeId && $0.gapMeters <= 2
                                && abs($0.latitude - seam.latitude) < 0.00002
                                && abs($0.longitude - seam.longitude) < 0.00002
                        }) else { continue }
                    let virtual = count; count += 1
                    try attach(.init(latitude: seam.latitude, longitude: seam.longitude), index: index,
                           virtual: virtual, edgeID: seam.localEdgeId)
                    try attach(.init(latitude: reciprocal.latitude, longitude: reciprocal.longitude), index: other,
                           virtual: virtual, edgeID: reciprocal.localEdgeId)
                }
            }
        }
        }
        let fieldBegan = ProcessInfo.processInfo.systemUptime
        var bounded: BoundedForwardFuelField?
        if !reverse, let maximum = forwardRangeMeters {
            guard !(extra[anchorNode] ?? []).isEmpty else {
                throw RoutingError.fuelUnknown("The origin has no verified usable road match; range remains unverified.")
            }
            bounded = try BoundedForwardFuelField.build(
                seeds: [.init(node: .init(pack: 0,local: anchorNode),meters: 0)],maximumMeters: maximum,limits: forwardFieldLimits) { key,visit in
                let state = key.local
            for arc in extra[state] ?? [] { try visit(.init(pack: 0,local: arc.to),arc.meters) }
            guard let index = packs.indices.last(where: { offsets[$0] <= state }),
                  state < offsets[index] + packs[index].nodeCount else { return }
            let router = routers[index], pack = packs[index], node = state - offsets[index]
            let start = Int(pack.nodeOffsets[node]), end = Int(pack.nodeOffsets[node + 1])
            guard start >= 0, end >= start, end <= pack.edgeTargets.count, end <= pack.edgeUndirectedIndex.count else { throw BoundedForwardFuelField.Failure.invalidInput }
            for arc in start..<end {
                let ei = Int(pack.edgeUndirectedIndex[arc]), target = Int(pack.edgeTargets[arc])
                guard ei >= 0, ei < pack.edgeMeters.count, target >= 0, target < pack.nodeCount else { throw BoundedForwardFuelField.Failure.invalidInput }
                if pack.version >= 4, pack.legalTopology {
                    let code = Int(pack.v4AccessCode(ei: ei, from: node, to: target))
                    if code == 2 || code == 5 || (code == 1 && !policyUnknown) { continue }
                } else if !router.accessAllowed(GraphV2Pack.unpackAccess(pack.edgeAttrs[ei]),
                    allowUnknown: policyUnknown, profile: profile) { continue }
                try visit(.init(pack: 0,local: offsets[index] + target),Double(pack.edgeMeters[ei]))
            }
            }
        }
        if let bounded {
            forwardPreparation = "complete:\(bounded.completeWithinRange),states:\(bounded.stateCount),arcs:\(bounded.examinedArcs),peakPayload:\(bounded.allocatedPayloadBytes),retainedPayload:\(bounded.retainedPayloadBytes)"
        }
        let remaining: (Int) -> Double
        if let bounded, bounded.completeWithinRange {
            remaining = { bounded.distance(.init(pack: 0,local: $0)) ?? .infinity }
            diagnosticStatus = "bounded-forward-complete"
        } else {
            bounded = nil // Release incomplete sparse preparation before legacy fallback.
            // Optional accelerator exhaustion cannot exclude any station.
        let result = RoadCompass.build(stateCount: count, destination: anchorNode, reverse: reverse,
            recordSuccessors: false,
            cancelled: { RoutingWorkContext.stopReason != nil }) { state, visit in
            for arc in extra[state] ?? [] { visit(arc) }
            guard let index = packs.indices.last(where: { offsets[$0] <= state }),
                  state < offsets[index] + packs[index].nodeCount else { return }
            let router = routers[index], pack = packs[index], node = state - offsets[index]
            for arc in Int(pack.nodeOffsets[node])..<Int(pack.nodeOffsets[node + 1]) {
                let ei = Int(pack.edgeUndirectedIndex[arc]), target = Int(pack.edgeTargets[arc])
                if pack.version >= 4, pack.legalTopology {
                    let code = Int(pack.v4AccessCode(ei: ei, from: node, to: target))
                    if code == 2 || code == 5 || (code == 1 && !policyUnknown) { continue }
                } else if !router.accessAllowed(GraphV2Pack.unpackAccess(pack.edgeAttrs[ei]),
                    allowUnknown: policyUnknown, profile: profile) { continue }
                visit(.init(to: offsets[index] + target, edge: ei, meters: Double(pack.edgeMeters[ei])))
            }
        }
        diagnosticStatus = "field-" + result.status
        guard result.status == "complete" else { throw RoutingError.fuelUnknown("Regional guidance did not complete; fuel reachability remains unverified.") }

            // A completed fallback field can prove the same range exclusion
            // as the sparse accelerator. Do not match every connected station
            // merely because the bounded preparation ran out of state slots.
            if !reverse, let maximum = forwardRangeMeters {
                remaining = { node in
                    let distance = result.remaining[node]
                    return distance.isFinite && distance > maximum ? .infinity : distance
                }
                diagnosticStatus = "full-forward-range-complete"
            } else {
                remaining = { result.remaining[$0] }
            }
        }
        fieldSeconds = ProcessInfo.processInfo.systemUptime - fieldBegan
        // The field is complete. Keep anchor-interior matches even when no
        // graph endpoint can represent their direct same-edge continuation.
        matchingStage = "anchor"
        let anchorMatches = try packs.indices.map { try snaps(anchor, $0) }
        matchingStage = "station"
        let protectedByPack = anchorMatches.map { Set($0.map(\.edgeIndex)) }
        var skipped = 0
        defer {
            diagnosticSkipped = skipped
            RoutingWorkContext.measurement?.increment(.stationMatchesSkipped, by: UInt64(skipped))
        }
        func coverageCannotReach(_ point: CLLocationCoordinate2D, index: Int) throws -> Bool {
            coverageCalls += 1
            let began = ProcessInfo.processInfo.systemUptime
            defer { coverageSeconds += ProcessInfo.processInfo.systemUptime - began }
            return try routers[index].stationCoverageCannotReach(point,
                isPossiblyReachedNode: { $0 < 0 || $0 >= count || remaining($0) != .infinity },
                nodeOffset: offsets[index], protectedEdges: protectedByPack[index])
        }
        var distances: [Double] = []
        for point in points {
            try RoutingWorkContext.check()
            var best = Double.infinity
            for index in packs.indices {
                let pack = packs[index], offset = offsets[index], anchorSnaps = anchorMatches[index]
                // A completed exact match needs no optional coverage preprobe.
                // Reevaluate every cached snap against this field; never cache reachability.
                let cached = useCachedMatchesBeforeCoverage
                    ? try Self.rangeSnapCache.cached(pack: pack, point: point,
                        profile: profile, allowUnknown: allowUnknown) : nil
                if cached != nil {
                    RoutingWorkContext.measurement?.increment(.rangeSnapCoverageBypasses)
                }
                if (useStationCoveragePreprobe || bounded?.completeWithinRange == true), cached == nil, try coverageCannotReach(point, index: index) {
                    skipped += 1
                    continue
                }
                for snap in try cached ?? snaps(point, index) {
                    let ei = snap.edgeIndex
                    for end in anchorSnaps where end.edgeIndex == ei {
                        let delta = reverse ? end.distanceAlongM - snap.distanceAlongM : snap.distanceAlongM - end.distanceAlongM
                        if (delta >= 0 && permitted(pack, from: snap.nodeA, to: snap.nodeB, edge: ei))
                            || (delta <= 0 && permitted(pack, from: snap.nodeB, to: snap.nodeA, edge: ei)) {
                            best = min(best, snap.distanceMeters + abs(delta) + end.distanceMeters)
                        }
                    }
                    let forward = permitted(pack, from: snap.nodeA, to: snap.nodeB, edge: ei)
                    let backward = permitted(pack, from: snap.nodeB, to: snap.nodeA, edge: ei)
                    if reverse ? backward : forward {
                        best = min(best, snap.distanceMeters + snap.distanceAlongM + remaining(offset + snap.nodeA))
                    }
                    if reverse ? forward : backward {
                        best = min(best, snap.distanceMeters + max(0, Double(pack.edgeMeters[ei]) - snap.distanceAlongM) + remaining(offset + snap.nodeB))
                    }
                }
            }
            distances.append(best)
        }
        diagnosticStatus += "-returned"
        return distances
    }

    func shortestGraphMeters(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        maxMeters: Double,
        profile: RouteProfile,
        allowUnknown: Bool
    ) throws -> Double? {
        let wall = true
        guard let dist = try exploreNodeMeters(
            from: from, toward: to, maxMeters: maxMeters, profile: profile,
            allowUnknown: allowUnknown, cityWall: wall
        ) else { return nil }
        return try graphMeters(to: to, dist: dist, profile: profile, allowUnknown: allowUnknown, from: from)
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
        do {
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
        var startRaw = try nearestEdgeSnaps(
            to: from, allowUnknown: allowUnknown, profile: profile,
            maxMeters: snapCap,
            headingDeg: nil,
            intentBearingDeg: startEndpointKind == "customers" ? nil : bearingDeg(from: from, to: to),
            rejections: &startRejects
        ).filter { $0.distanceMeters <= snapCap }
        var endRaw = try nearestEdgeSnaps(
            to: to, allowUnknown: allowUnknown, profile: profile,
            maxMeters: snapCap,
            headingDeg: nil,
            intentBearingDeg: endEndpointKind == "customers" ? nil : bearingDeg(from: to, to: from),
            rejections: &endRejects
        ).filter { $0.distanceMeters <= snapCap }
        if let node = recordedStartNode {
            startRaw = try recordedNodeSnaps(node: node, point: from, profile: profile, allowUnknown: allowUnknown)
        }
        if let node = recordedEndNode {
            endRaw = try recordedNodeSnaps(node: node, point: to, profile: profile, allowUnknown: allowUnknown)
        }
        if let imported = importedArrival {
            switch imported.location {
            case .node:
                startRaw = try recordedNodeSnaps(node: imported.toNode,
                    point: coordinate(forNode: imported.toNode), profile: profile, allowUnknown: allowUnknown)
                    .map { original in
                        var snap = original
                        snap.distanceMeters = meters(from, snap.projected)
                        return snap
                    }.filter { $0.distanceMeters <= snapCap }
            case .edge(let fraction):
                if let snap = try continuationParentSnap(edge: imported.incomingEdge, fromNode: imported.fromNode,
                    fraction: fraction, point: from), snap.distanceMeters <= snapCap {
                    startRaw = [snap]
                } else { startRaw = [] }
            }
            guard !startRaw.isEmpty else { return .failure(.searchLimit("legalContinuationLocationUnavailable")) }
        }
        // Selected pumps stay on the closest packed anchor; intent must not
        // move a failed station entrance onto a nearby public through-road.
        if v4, startEndpointKind == "customers", let nearest = startRaw.first?.distanceMeters {
            startRaw = startRaw.filter { $0.distanceMeters <= nearest + 2 }
        }
        if v4, endEndpointKind == "customers", let nearest = endRaw.first?.distanceMeters {
            endRaw = endRaw.filter { $0.distanceMeters <= nearest + 2 }
        }
        guard !startRaw.isEmpty else { return .failure(.cannotSnapStart) }
        guard !endRaw.isEmpty else { return .failure(.cannotSnapEnd) }

        let tapSeparation = meters(from, to)
        if initialFuelApproach, incomingContinuation == nil,
           startEndpointKind == "customers", endEndpointKind == "customers",
           from.latitude == to.latitude, from.longitude == to.longitude {
            // Presence must lie on the actual matched road, not across a
            // nearby barrier or on a convenient replacement snap.
            let present = startRaw.contains { snap in
                guard snap.distanceMeters <= 0.001,
                      endRaw.contains(where: { $0.edgeIndex == snap.edgeIndex && $0.distanceMeters <= 0.001 })
                else { return false }
                return [(snap.nodeA, snap.nodeB), (snap.nodeB, snap.nodeA)].contains { a, b in
                    pack.hasDirectedArc(from: a, to: b, edge: snap.edgeIndex)
                        && pack.v4AccessAllowed(ei: snap.edgeIndex, from: a, to: b,
                            startEi: snap.edgeIndex, endEi: snap.edgeIndex,
                            allowUnknown: allowUnknown && profile != .cleanest,
                            startEndpointKind: "customers", endEndpointKind: "customers")
                }
            }
            guard present else { return .failure(.cannotSnapStart) }
            var presence = Result(coordinates: [from, to], distanceMeters: 0,
                edgeIds: [], legs: [], dirtPercent: 0, pavedPercent: 0,
                unknownAccessPercent: 0, reportedDirtPercent: 0,
                reportedPavedPercent: 0, unknownSurfacePercent: 0)
            presence.searchMeta.rideObjective = "initial-fuel-presence"
            return .success(presence)
        }
        if tapSeparation < Self.identicalEndsMeters && !initialFuelApproach {
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
            v4Pairs = connected.pairs
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
            func anchor(_ snap: EdgeSnap) -> MatchedEndpoint? {
                guard let epoch = pack.sourceEpoch, !epoch.isEmpty,
                      pack.osmWayIds.indices.contains(snap.edgeIndex),
                      pack.osmNodeIds.indices.contains(snap.nodeA), pack.osmNodeIds.indices.contains(snap.nodeB),
                      snap.distanceAlongM.isFinite,
                      snap.projected.longitude.isFinite, snap.projected.latitude.isFinite else { return nil }
                for node in [snap.nodeA, snap.nodeB] {
                    let point = coordinate(forNode: node)
                    if snap.projected.longitude == point.longitude, snap.projected.latitude == point.latitude {
                        return .init(sourceEpoch: epoch, location: .node(pack.osmNodeIds[node]))
                    }
                }
                return .init(sourceEpoch: epoch, location: .edge(
                    parent: .init(wayID: pack.osmWayIds[snap.edgeIndex],
                        fromNodeID: pack.osmNodeIds[snap.nodeA], toNodeID: pack.osmNodeIds[snap.nodeB]),
                    alongMeters: snap.distanceAlongM, longitude: snap.projected.longitude, latitude: snap.projected.latitude))
            }
            out.matchedStart = anchor(startSnap)
            out.matchedEnd = anchor(endSnap)
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
                if let deadline = ctx.calculationDeadline, CFAbsoluteTimeGetCurrent() >= deadline {
                    return .failure(.searchLimit("timeCap"))
                }
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
            if let deadline = ctx.calculationDeadline, CFAbsoluteTimeGetCurrent() >= deadline {
                return .failure(.searchLimit("timeCap"))
            }
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
        ctx.calculationDeadline = balancedCalculationDeadline
        ctx.urbanEdgeMemo = UrbanEdgeMemo(owner: pack,from: from,to: to,boxes: packUrbanCores)
        defer { ctx.urbanEdgeMemo?.recordMeasurements(RoutingWorkContext.measurement) }
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
        ctx.cleanMetroMultiplier = cleanMetroMultiplier
        let e4 = RoadTierStats.e4Flags(
            for: profile,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads
        )
        ctx.avoidMotorways = e4.avoidMotorways
        ctx.preferBackRoads = e4.preferBackRoads

        if initialFuelApproach {
            // This mapped-station approach precedes the recreational ride.
            // Keep access, turn state and explicit road exclusions, but do not
            // let riding-character walls or preferences rank station distance.
            ctx.costMode = .distance
            ctx.variety = false
            ctx.cityWall = false
            ctx.pavedOnly = false
            ctx.settlementWall = false
            ctx.settlementFallback = false
            ctx.noBacktrack = false
            ctx.avoidMotorways = false
            ctx.preferBackRoads = false
            ctx.maxPathMeters = maxRouteMeters
            var result = runProfile(ctx)
            if case .success(var route) = result {
                route.searchMeta.rideObjective = "initial-fuel-approach"
                result = .success(route)
            }
            return result
        }

        if profile == .dirt {
            let base = HopSearchPolicy.dirtCorridorMeters
            let comparisonWidths = [base * 2, base]
            let connectivityWidths: [Double?] = [base * 3, base * 4, nil]
            var candidates: [(route: Result, width: Double, objective: String)] = []
            var lastBoundedFailure: Failure = .noPath
            var selectionAudit = NativeSelectionSearchAudit()
            func auditedProfile(_ context: HopSearchContext) -> Swift.Result<Result, Failure> {
                let outcome = runProfile(context)
                selectionAudit.record(outcome)
                return outcome
            }

            func searchDirt(
                width: Double?,
                costMode: HopSearchPolicy.CostMode = .pavement
            ) -> Swift.Result<Result, Failure> {
                var hunt = ctx
                hunt.costMode = costMode
                hunt.variety = false
                hunt.corridorMeters = width
                hunt.hardCorridor = width != nil
                hunt.boundedSearch = true
                hunt.timeCapSeconds = HopSearchPolicy.dirtCandidateTimeCapSeconds
                hunt.popCap = costMode == .balancedResource
                    ? (dirtResourceCandidatePopCapOverride ?? HopSearchPolicy.dirtCandidatePopCap)
                    : HopSearchPolicy.dirtCandidatePopCap
                hunt.maxPathMeters = maxRouteMeters
                lastFailure = .noPath
                let initial: Result
                switch auditedProfile(hunt) {
                case .success(let route): initial = route
                case .failure(let failure): return .failure(failure)
                }
                var route = initial
                var penaltyEdgeIds = hunt.shortDirtPenaltyEdgeIds
                var repairPasses = 0
                for _ in 0..<HopSearchPolicy.maximumShortDirtRepairPasses {
                    let found = Self.shortDirtExcursionEdgeIDs(in: route.legs)
                    let additions = found.subtracting(penaltyEdgeIds)
                    if additions.isEmpty { break }
                    penaltyEdgeIds.formUnion(additions)
                    hunt.shortDirtPenaltyEdgeIds = penaltyEdgeIds
                    guard case .success(let next) = auditedProfile(hunt) else { break }
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
                case .success(let route): candidates.append((route, width, "pavement"))
                case .failure(let failure): lastBoundedFailure = failure
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
            if primaryBestDirt < 70 {
                switch searchDirt(width: base, costMode: .balancedResource) {
                case .success(let route):
                    candidates.append((route, base, "resource"))
                case .failure(let failure):
                    lastBoundedFailure = failure
                }
            }
            guard let selected = try chooseDirtEnvelopeCandidate(candidates) else {
                return .failure(lastBoundedFailure)
            }
            var route = selected.route
            selectionAudit.apply(to: &route.searchMeta)
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
            let base = HopSearchPolicy.balancedCorridorMeters
            let multipliers: [Double] = [1, 2, 3, 4, 6, 8]
            return BalancedEnvelopeSearch.run(widths: multipliers.map({ base * $0 }) + [0],
                deadline: ctx.calculationDeadline) { width in
                var envelope = ctx
                envelope.costMode = .balancedResource
                envelope.variety = false
                envelope.corridorMeters = width > 0 ? width : nil
                envelope.hardCorridor = width > 0
                envelope.boundedSearch = true
                envelope.timeCapSeconds = HopSearchPolicy.pass2TimeCapSeconds
                envelope.popCap = HopSearchPolicy.pass2PopCap * 10
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
                    return .failure(failure)
                }
            }
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
            envelope.timeCapSeconds = ctx.pavedOnly ? 12.0 : HopSearchPolicy.pass2TimeCapSeconds
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
        } catch {
            return .failure(.searchLimit(RoutingWorkContext.stopReason ?? "snapIndexUnavailable"))
        }
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
    ) throws -> (route: Result, width: Double, objective: String)? {
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
        return try pool.min { lhs, rhs in
            let a = lhs.candidate
            let b = rhs.candidate
            if let preferences = activeRidePreferences, preferences.wander < 1 || preferences.avoidHighways {
                let costA = (try preferenceRouteCost(a.route, preferences: preferences))
                let costB = (try preferenceRouteCost(b.route, preferences: preferences))
                if costA != costB { return costA < costB }
            }
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
        do {
        // Same snapped edge: paint the along-edge span (find-path-v2 vBetween).
        if activeRidePreferences == nil, !initialFuelApproach,
           startSnap.edgeIndex >= 0,
           startSnap.edgeIndex == endSnap.edgeIndex,
           abs(startSnap.distanceAlongM - endSnap.distanceAlongM) > (initialFuelApproach ? 0 : 1) {
            let sameEi = startSnap.edgeIndex
            let edgeA = Int(pack.edgeFrom?[sameEi] ?? -1)
            let edgeB = Int(pack.edgeTo?[sameEi] ?? -1)
            let alongForward = startSnap.distanceAlongM <= endSnap.distanceAlongM
            if let imported = importedArrival, let turns = legalTurnState {
                let next = continuationStartState(edge: sameEi,
                    targetNode: alongForward ? edgeB : edgeA,
                    movement: abs(startSnap.distanceAlongM - endSnap.distanceAlongM), turns: turns)
                guard next >= 0 else {
                    return .failure(.searchLimit("legalContinuationDirectionUnavailable"))
                }
                _ = imported
            }
            if !pack.v4AccessAllowed(
                ei: sameEi,
                from: alongForward ? edgeA : edgeB,
                to: alongForward ? edgeB : edgeA,
                startEi: sameEi,
                endEi: sameEi,
                allowUnknown: allowUnknown && profile != .cleanest,
                startEndpointKind: startEndpointKind,
                endEndpointKind: endEndpointKind
            ) { return .failure(.noPath) }
            // Snapped A/B edge is always traversable under Clean law.
            if (try edgeBlockedByPavedOnly(
                startSnap.edgeIndex, ctx: ctx,
                allowSnapEdges: startSnap.edgeIndex, endEi: endSnap.edgeIndex
            )) {
                return .failure(.noPath)
            }
            if pack.version >= 4,
               pack.v4AccessCode(ei: sameEi, from: alongForward ? edgeA : edgeB, to: alongForward ? edgeB : edgeA) == 4,
               abs(startSnap.distanceAlongM - endSnap.distanceAlongM) > CustomerEndpointAccess.limitMeters {
                return .failure(.searchLimit("customer_access_scope"))
            }
            if let same = try sameEdgeResult(from: from, to: to, startSnap: startSnap, endSnap: endSnap) {
                if let cap = ctx.maxPathMeters, same.distanceMeters > cap {
                    return .failure(.noPath)
                }
                let crossesAvoidedCity = ctx.cityWall && same.coordinates.indices.dropFirst().contains { index in
                    UrbanCore.blocks(segmentFrom: same.coordinates[index - 1], segmentTo: same.coordinates[index],
                        start: from, end: to, boxes: packUrbanCores)
                }
                if !crossesAvoidedCity { return .success(same) }
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
        } catch {
            return .failure(.searchLimit(RoutingWorkContext.stopReason ?? "routingDataUnavailable"))
        }
    }

    // MARK: - Same-edge shortcut

    private func sameEdgeResult(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        startSnap: EdgeSnap,
        endSnap: EdgeSnap
    ) throws -> Result? {
        let ei = startSnap.edgeIndex
        let alongForward = startSnap.distanceAlongM <= endSnap.distanceAlongM
        let legal = alongForward
            ? pack.hasDirectedArc(from: startSnap.nodeA, to: startSnap.nodeB, edge: ei)
            : pack.hasDirectedArc(from: startSnap.nodeB, to: startSnap.nodeA, edge: ei)
        guard legal else { return nil }
        let poly = try edgeGeometry(ei) ?? [
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
        guard alongM > (initialFuelApproach ? 0 : 1) else { return nil }

        let surface = OnDeviceProfileCosts.surfaceName(
            code: GraphV2Pack.unpackSurface(pack.edgeAttrs[ei])
        )
        let id = pack.edgeId(ei)

        let geometryMeasurement = RoutingWorkContext.measurement
        let geometryPhase = geometryMeasurement?.begin(.geometry)
        defer { geometryMeasurement?.end(geometryPhase) }
        var legs: [Leg] = []
        if let stub = softStitchStub(tap: from, snap: startSnap, idSuffix: "start") {
            legs.append(stub)
        }
        legs.append(Leg(
            coordinates: between,
            distanceMeters: alongM,
            surfaceName: surface,
            edgeId: id,
            accessName: accessNameForTraversal(ei,
                from: alongForward ? startSnap.nodeA : startSnap.nodeB,
                to: alongForward ? startSnap.nodeB : startSnap.nodeA),
            roadClassName: roadClassNameForEdge(ei),
            surfaceLeaf: pack.hasLeaves ? (try pack.surfaceLeaf(ei,query: edgeDetailQuery)) : nil,
            structureType: structureTypeForEdge(ei),
            structureLeaf: (try structureLeafForEdge(ei)),
            layer: (try layerForEdge(ei)),
            crossingLabel: (try crossingLabelForEdge(ei)),
            waterCrossing: (try waterCrossingForEdge(ei)),
            edgeIndex: ei, fromNode: alongForward ? startSnap.nodeA : startSnap.nodeB,
            toNode: alongForward ? startSnap.nodeB : startSnap.nodeA
        ))
        if let stub = softStitchStub(tap: to, snap: endSnap, idSuffix: "end") {
            legs.append(stub)
        }

        return finalize(legs: legs, nodeFallback: between, profile: .cleanest)
    }

    // MARK: - Virtual endpoint Dijkstra (find-path-v2 parity)

    private struct VirtEdge {
        var roadSpan: PathRetrace.Span? = nil
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
        do {
        let measurement = RoutingWorkContext.measurement
        let measuredPhase = measurement?.begin(.search)
        defer { measurement?.end(measuredPhase) }
        let n = pack.nodeCount
        let startVirt = n
        let endVirt = n + 1
        let turnState = legalTurnState ?? pack.makeV4TurnStateSpace(startNode: startVirt, endNode: endVirt)
        let total = turnState.stateCount
        let policyUnknown = allowUnknown && profile != .cleanest
        let startEi = startSnap.edgeIndex
        let endEi = endSnap.edgeIndex
        let startPoly = try edgeGeometry(startEi) ?? [
            coordinate(forNode: startSnap.nodeA),
            coordinate(forNode: startSnap.nodeB)
        ]
        let endPoly = startEi == endEi
            ? startPoly
            : (try edgeGeometry(endEi) ?? [
                coordinate(forNode: endSnap.nodeA),
                coordinate(forNode: endSnap.nodeB)
            ])

        let edgeMetersStart = Double(pack.edgeMeters[startEi])
        let edgeMetersEnd = Double(pack.edgeMeters[endEi])
        let endLL = endSnap.projected
        let abMeters = meters(startSnap.projected, endLL)
        let startOnMajorHighway = (try snapIsMajorHighwayPin(startSnap, profile: profile))
        let endOnMajorHighway = (try snapIsMajorHighwayPin(endSnap, profile: profile))


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

        let startAlong = max(0, min(edgeMetersStart, startSnap.distanceAlongM))
        let endAlong = max(0, min(edgeMetersEnd, endSnap.distanceAlongM))
        virt[vStartA].roadSpan = .init(edge: startEi, lower: 0, upper: startAlong)
        virt[vStartB].roadSpan = .init(edge: startEi, lower: startAlong, upper: edgeMetersStart)
        virt[vEndA].roadSpan = .init(edge: endEi, lower: 0, upper: endAlong)
        virt[vEndB].roadSpan = .init(edge: endEi, lower: endAlong, upper: edgeMetersEnd)
        if vBetween >= 0 {
            virt[vBetween].roadSpan = .init(edge: startEi, lower: min(startAlong,endAlong), upper: max(startAlong,endAlong))
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
        if let imported = importedArrival, case .node = imported.location {
            if imported.toNode == startSnap.nodeA, mSA == 0 {
                linkVirtArc(vStartA, from: startVirt, to: startSnap.nodeA, forward: true)
            }
            if imported.toNode == startSnap.nodeB, mSB == 0 {
                linkVirtArc(vStartB, from: startVirt, to: startSnap.nodeB, forward: true)
            }
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

        var ctx = ctx
        if let cap = ctx.maxPathMeters {
            // The returned itinerary includes these approach connectors, so
            // reserve their exact lengths before spending distance on roads.
            let approachMeters = (softStitchStub(tap: from, snap: startSnap, idSuffix: "start")?.distanceMeters ?? 0)
                + (softStitchStub(tap: to, snap: endSnap, idSuffix: "end")?.distanceMeters ?? 0)
            guard cap >= approachMeters else { return .failure(.noPath) }
            ctx.maxPathMeters = cap - approachMeters
        }
        if startEndpointKind == "customers" {
            ctx.customerStartEdges = pack.customerEndpointEdges(edgeIndex: startEi,
                seeds: (virtAdj[startVirt] ?? []).filter { $0.to < n }.map { ($0.to, virt[$0.id].meters) })
        }
        if endEndpointKind == "customers" {
            ctx.customerEndEdges = pack.customerEndpointEdges(edgeIndex: endEi,
                seeds: (virtAdjRev[endVirt] ?? []).filter { $0.to < n }.map { ($0.to, virt[$0.id].meters) }, reverse: true)
        }
        // Restore the accepted 71aa7fd geographic-progress calculation.
        // Legal turn states still resolve to their physical graph coordinates.
        func awayExtra(fromNode: Int, toNode: Int) -> Double {
            func ll(_ node: Int) -> CLLocationCoordinate2D? {
                if node == startVirt { return startSnap.projected }
                if node == endVirt { return endSnap.projected }
                let graphNode = turnState.graphNode(of: node)
                if graphNode >= 0, graphNode < n { return coordinate(forNode: graphNode) }
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

        var slackToDest: [Double]? = nil
        if let cap = ctx.maxPathMeters, cap.isFinite, cap < .greatestFiniteMagnitude / 4 {
            slackToDest = try fillShortestMeters(
                from: endVirt,
                capMeters: cap,
                nodeCount: n,
                total: total,
                virt: virt,
                virtAdj: virtAdjRev,
                from: from,
                to: to,
                ctx: ctx,
                startEi: startEi, endEi: endEi,
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

        guard let labels = try? DemandSearchLabels(
            stateCount: total, maxPayloadBytes: maximumSearchLabelPayloadBytes,
            useReadPointerCache: useLabelReadPointerCache,
            shouldStop: { RoutingWorkContext.stopReason != nil }
        ) else { return .failure(.searchLimit("labelStorageConfiguration")) }
        var measuredLabelCapacity = 0
        var measuredLabelPages = 0
        func publishLabelAllocation() {
            guard labels.allocationRevision != measuredLabelPages else { return }
            let stats = labels.statistics
            measurement?.increment(.labelPagesAllocated, by: UInt64(stats.allocatedPages - measuredLabelPages))
            measurement?.increment(.labelsCreated, by: UInt64(stats.allocatedLabelCapacity - measuredLabelCapacity))
            measurement?.set(.labelBytes, to: UInt64(stats.allocatedPayloadBytes))
            measuredLabelPages = stats.allocatedPages
            measuredLabelCapacity = stats.allocatedLabelCapacity
        }
        defer { measurement?.set(.labelBytes, to: 0) }
        func writeLabel(_ state: Int, _ update: (inout DemandSearchLabels.Label) -> Void) -> Failure? {
            do {
                try labels.mutate(state, update)
                publishLabelAllocation()
                return nil
            } catch DemandSearchLabels.StorageError.memoryLimit {
                return .searchLimit("labelMemoryCap:payloadBytes=\(maximumSearchLabelPayloadBytes)")
            } catch DemandSearchLabels.StorageError.cancelled {
                return .searchLimit(RoutingWorkContext.stopReason ?? "cancelled")
            } catch {
                return .searchLimit("labelStorageInvalidState")
            }
        }
        func applySlots(_ action: HopSearchPolicy.RelaxAction, to row: inout DemandSearchLabels.Label) {
            // Identical to HopSearchPolicy.apply; rejection never allocates.
            if action == .acceptReset { row.slots = 1 }
            else if action != .reject, row.slots < 255 { row.slots += 1 }
        }
        func createsLabelCycle(from: Int, through target: Int) -> Bool {
            var node = from
            var hops = 0
            let cap = total + 2
            while node >= 0, hops < cap {
                if node == target { return true }
                node = labels[node].predecessor
                hops += 1
            }
            return hops >= cap
        }
        func pathRecord(_ label: Int) -> PathRetrace.Span? {
            let row = labels[label]
            if row.predecessor < 0 { return nil }
            if row.predecessorKind == 0 {
                let ei = row.predecessorData
                return .init(edge: ei, lower: 0, upper: Double(pack.edgeMeters[ei]))
            }
            return row.predecessorKind == 1 ? virt[row.predecessorData].roadSpan : nil
        }
        var retraceQueries: UInt64 = 0
        var retracePredecessorVisits: UInt64 = 0
        defer {
            measurement?.increment(.singleRetraceQueries, by: retraceQueries)
            measurement?.increment(.singleRetracePredecessorVisits, by: retracePredecessorVisits)
        }
        func retraces(_ label: Int, _ span: PathRetrace.Span?) -> Bool {
            guard pack.version >= 4, let span else { return false }
            retraceQueries &+= 1
            if !useCombinedRetraceCallback {
                let result = PathRetrace.containsCounted(node: label, span: span,
                    previous: { labels[$0].predecessor }, record: { ancestor in
                        let row = labels[ancestor]
                        guard row.predecessor >= 0 else { return nil }
                        let entry = row.predecessorData
                        if row.predecessorKind == 0 {
                            guard entry == span.edge else { return nil }
                            return .init(edge: entry, lower: 0, upper: Double(pack.edgeMeters[entry]))
                        }
                        return row.predecessorKind == 1 ? virt[entry].roadSpan : nil
                    })
                retracePredecessorVisits &+= result.visits
                return result.contains
            }
            // Synchronous read-only traversal of the same predecessor chain;
            // no dense array snapshot or cached path history is created.
            let result = PathRetrace.containsCounted(node: label, span: span, step: { ancestor in
                let row = labels[ancestor]
                guard row.predecessor >= 0 else { return (row.predecessor,nil) }
                let entry = row.predecessorData
                if row.predecessorKind == 0 {
                    guard entry == span.edge else { return (row.predecessor,nil) }
                    return (row.predecessor,.init(edge: entry, lower: 0, upper: Double(pack.edgeMeters[entry])))
                }
                return (row.predecessor,row.predecessorKind == 1 ? virt[entry].roadSpan : nil)
            })
            retracePredecessorVisits &+= result.visits
            return result.contains
        }
        var heap = MinHeap()
        defer { heap.flushMeasurement() }

        // Preserve the arrival road tier across virtual snap stubs and
        // duplicate-node stitches. The toll belongs at the real transition,
        // not on every trunk/motorway edge.
        func predecessorGraphEdgeIndex(at node: Int) -> Int? {
            var cursor = node
            for _ in 0..<8 where cursor >= 0 && labels[cursor].predecessor >= 0 {
                if labels[cursor].predecessorKind == 0 { return labels[cursor].predecessorData }
                if labels[cursor].predecessorKind == 1 {
                    let id = labels[cursor].predecessorData
                    guard id >= 0, id < virt.count, virt[id].ei >= 0 else { return nil }
                    return virt[id].ei
                }
                guard labels[cursor].predecessorKind == 2 else { return nil }
                cursor = labels[cursor].predecessor
            }
            return nil
        }

        if let failure = writeLabel(startVirt, { $0.cost = 0; $0.pathMeters = 0 }) {
            return .failure(failure)
        }
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
        let perSearchDeadline: Double? = isHunt
            ? huntStart + (ctx.timeCapSeconds ?? HopSearchPolicy.pass2TimeCapSeconds)
            : nil
        let deadline = ctx.calculationDeadline.map { min($0, perSearchDeadline ?? $0) } ?? perSearchDeadline

        while let cur = heap.pop() {
            if let reason = RoutingWorkContext.stopReason { return .failure(.searchLimit(reason)) }
            if cur.cost != labels[cur.node].cost { continue }
            pops += 1
            if pops > popCap { abort = "popCap"; break }
            if let deadline, (pops & 255) == 0, CFAbsoluteTimeGetCurrent() > deadline {
                abort = "timeCap"
                break
            }
            if cur.node == endVirt { break }

            let graphNode = turnState.graphNode(of: cur.node)

            if graphNode >= 0, graphNode < n {
                let arcStart = Int(pack.nodeOffsets[graphNode])
                let arcEnd = Int(pack.nodeOffsets[graphNode + 1])
                guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
                heap.recordExpansion(arcs: arcEnd - arcStart)

                for i in arcStart..<arcEnd {
                    let toNode = Int(pack.edgeTargets[i])
                    let ei = Int(pack.edgeUndirectedIndex[i])
                    guard ei >= 0, ei < pack.undirectedEdgeCount else { continue }
                    // find-path-v2: only suppress immediate U-turn on a prior *real*
                    // edge. Clean+leaves must not treat a mid-edge virt stub of `ei`
                    // as blocking the real traversal of `ei` (JS parity / E2 lockstep).
                    if ctx.noBacktrack {
                        if profile == .cleanest, pack.hasLeaves {
                            if labels[cur.node].predecessorKind == 0, labels[cur.node].predecessorData == ei { continue }
                        } else if isBacktrack(
                            prevKind: labels[cur.node].predecessorKind, prevData: labels[cur.node].predecessorData,
                            ei: ei, virt: virt
                        ) {
                            continue
                        }
                    }
                    if !pack.v4AccessAllowed(
                        ei: ei, from: graphNode, to: toNode,
                        startEi: startEi, endEi: endEi,
                        allowUnknown: policyUnknown,
                        startEndpointKind: startEndpointKind,
                        endEndpointKind: endEndpointKind,
                        customerStartEdges: ctx.customerStartEdges, customerEndEdges: ctx.customerEndEdges
                    ) { continue }
                    let toState = turnState.transition(
                        state: cur.node, outgoingEdge: ei, toNode: toNode
                    )
                    if toState < 0 { continue }
                    let attr = pack.edgeAttrs[ei]
                    let access = GraphV2Pack.unpackAccess(attr)
                    if pack.version < 4,
                       !accessAllowed(access, allowUnknown: policyUnknown, profile: profile) {
                        continue
                    }
                    if (try edgeBlockedByPavedOnly(ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi)) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }

                    let toLL = coordinate(forNode: toNode)
                    if try hopBlocked(toLL, edgeFrom: coordinate(forNode: graphNode), edgeIndex: ei, from: from, to: to, ctx: ctx) {
                        continue
                    }

                    let edgeM = Double(pack.edgeMeters[ei])
                    let newMeters = labels[cur.node].pathMeters + edgeM
                    if exceedsLengthSlack(
                        newMeters: newMeters, toNode: toNode,
                        slackToDest: slackToDest, cap: ctx.maxPathMeters
                    ) { continue }

                    let surface = GraphV2Pack.unpackSurface(attr)
                    let roadClass = GraphV2Pack.unpackRoadClass(attr)
                    let confidence = GraphV2Pack.unpackConfidence(attr)
                    let step: Double
                    if useExtractedFullRoadCost {
                        step = try fullRealRoadStep(meters: edgeM, edgeIndex: ei, attributes: attr,
                            edgeID: eid, surface: surface, roadClass: roadClass, access: access, confidence: confidence,
                            profile: profile, ctx: ctx, toLL: toLL, edgeFrom: coordinate(forNode: graphNode),
                            from: from, to: to, endLL: endLL, projectedOrigin: startSnap.projected, abMeters: abMeters,
                            startOnMajorHighway: startOnMajorHighway, endOnMajorHighway: endOnMajorHighway,
                            policyUnknown: policyUnknown,
                            awayExtraMeters: applyAway ? awayExtra(fromNode: cur.node, toNode: toState) : nil,
                            applySoftCorridor: applySoftCorridor, predecessorTier: {
                                guard let previous = predecessorGraphEdgeIndex(at: cur.node) else { return nil }
                                return try pack.roadTier(previous,query: edgeDetailQuery)
                            })
                    } else {
                        var referenceStep = (try hopCostStep(
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
                            projectedOrigin: startSnap.projected,
                            startOnMajorHighway: startOnMajorHighway,
                            endOnMajorHighway: endOnMajorHighway,
                            policyUnknown: policyUnknown
                        ))
                        referenceStep *= UrbanCore.fallbackMultiplier(
                            point: toLL,
                            start: from,
                            end: to,
                            boxes: packUrbanCores,
                            edgeFrom: coordinate(forNode: graphNode),
                            penalty: UrbanCore.resolveCleanMetroPenalty(
                                profile: profile,
                                override: ctx.cleanMetroMultiplier,
                                avoidMajorHighways: ctx.avoidMotorways
                            )
                        )
                        if ctx.settlementFallback {
                            referenceStep *= UrbanCore.settlementFallbackMultiplier(
                                point: toLL, start: from, end: to, boxes: settlementBoxes(for: profile),
                                penalty: UrbanCore.resolveSettlementPenalty(
                                    profile: profile,
                                    override: ctx.cleanMetroMultiplier,
                                    avoidMajorHighways: ctx.avoidMotorways
                                )
                            )
                        }
                        if applyAway {
                            let away = awayExtra(fromNode: cur.node, toNode: toState)
                            referenceStep += ctx.costMode == .pavement ? away * 10 : away
                            if applySoftCorridor {
                                referenceStep += OnDeviceProfileCosts.corridorCrossTrackExtra(
                                    profile: profile,
                                    point: toLL,
                                    lineFrom: startSnap.projected,
                                    lineTo: endLL,
                                    edgeMeters: edgeM
                                )
                            }
                        }
                        referenceStep = backtrackPenalized(referenceStep, edgeID: eid, ctx: ctx)
                        let isFerry = GraphV2Pack.isFerryStructure(GraphV2Pack.unpackStructure(attr))
                        if !isFerry, profile == .cleanest, pack.hasLeaves, ctx.avoidMotorways,
                           let fromEI = predecessorGraphEdgeIndex(at: cur.node) {
                            referenceStep += RoadTierStats.e4MajorHighwayEntryCost(
                                fromTier: (try pack.roadTier(fromEI,query: edgeDetailQuery)),
                                toTier: (try pack.roadTier(ei,query: edgeDetailQuery)),
                                enabled: true,
                                metersFromStart: meters(toLL, startSnap.projected),
                                metersToDestination: meters(toLL, endLL),
                                startOnHighway: startOnMajorHighway,
                                endOnHighway: endOnMajorHighway
                            )
                        }
                        // Initial refill ranks physical routed metres. Override all
                        // recreational penalties, including ferry-time pricing.
                        if initialFuelApproach { referenceStep = edgeM / 1_000 }
                        step = referenceStep
                    }
                    let cost = cur.cost + step
                    let newDirt = edgeIsDirt(ei)
                    let previousLabel = labels[toState]
                    let oldDirt = previousLabel.predecessorKind == 0 ? edgeIsDirt(previousLabel.predecessorData) : false
                    var action = HopSearchPolicy.considerRelax(
                        newCost: cost,
                        oldCost: previousLabel.cost,
                        newEi: ei,
                        oldEi: previousLabel.predecessorData,
                        node: toState,
                        newIsDirt: newDirt,
                        oldIsDirt: oldDirt,
                        seed: ctx.sessionSeed,
                        variety: ctx.variety,
                        slotsUsed: Int(previousLabel.slots)
                    )
                    if action != .reject, retraces(cur.node, .init(edge: ei, lower: 0, upper: Double(pack.edgeMeters[ei]))) { action = .reject }
                    if action == .stealPred, createsLabelCycle(from: cur.node, through: toState) {
                        action = .reject
                    }
                    if action != .reject {
                        if let failure = writeLabel(toState, { row in
                            applySlots(action, to: &row)
                            row.predecessor = cur.node
                            row.predecessorKind = 0
                            row.predecessorData = ei
                            row.forward = pack.edgeFrom.map { Int($0[ei]) == graphNode } ?? true
                            if HopSearchPolicy.shouldPush(action) {
                                row.cost = cost
                                row.pathMeters = newMeters
                            }
                        }) { return .failure(failure) }
                        if HopSearchPolicy.shouldPush(action) {
                            heap.push(node: toState, cost: cost)
                        }
                    }
                }
            }

            if pack.version < 4, graphNode < n, let sibs = coincidentSiblings[graphNode] {
                for toNode in sibs {
                    let cost = cur.cost
                    let newMeters = labels[cur.node].pathMeters
                    let previousLabel = labels[toNode]
                    var action = HopSearchPolicy.considerRelax(
                        newCost: cost,
                        oldCost: previousLabel.cost,
                        newEi: -1,
                        oldEi: previousLabel.predecessorData,
                        node: toNode,
                        newIsDirt: false,
                        oldIsDirt: false,
                        seed: ctx.sessionSeed,
                        variety: false,
                        slotsUsed: Int(previousLabel.slots)
                    )
                    if action == .stealPred, createsLabelCycle(from: cur.node, through: toNode) {
                        action = .reject
                    }
                    if action != .reject {
                        if let failure = writeLabel(toNode, { row in
                            applySlots(action, to: &row)
                            row.predecessor = cur.node
                            row.predecessorKind = 2
                            row.predecessorData = -1
                            row.forward = true
                            if HopSearchPolicy.shouldPush(action) {
                                row.cost = cost
                                row.pathMeters = newMeters
                            }
                        }) { return .failure(failure) }
                        if HopSearchPolicy.shouldPush(action) {
                            heap.push(node: toNode, cost: cost)
                        }
                    }
                }
            }

            if let vlist = virtAdj[graphNode] {
                for item in vlist {
                    let v = virt[item.id]
                    let continuationState: Int?
                    if graphNode == startVirt, importedArrival != nil, v.ei >= 0 {
                        let direction = virtualTraversalNodes(v, forward: item.forward, startSnap: startSnap, endSnap: endSnap)
                        let restored = continuationStartState(edge: v.ei, targetNode: direction.to,
                            movement: v.meters, turns: turnState)
                        if restored < 0 { continue }
                        continuationState = restored
                    } else { continuationState = nil }
                    if pack.version >= 4, v.ei >= 0, !(continuationState != nil && v.meters == 0) {
                        if item.to == endVirt, v.meters > 0,
                           !turnState.allowsExit(state: cur.node, outgoingEdge: v.ei) {
                            continue
                        }
                        let edgeA = Int(pack.edgeFrom?[v.ei] ?? -1)
                        let edgeB = Int(pack.edgeTo?[v.ei] ?? -1)
                        let accessFrom: Int
                        let accessTo: Int
                        if graphNode == startVirt, item.to < n {
                            accessTo = item.to
                            accessFrom = item.to == edgeA ? edgeB : edgeA
                        } else if graphNode < n, item.to == endVirt {
                            accessFrom = graphNode
                            accessTo = graphNode == edgeA ? edgeB : edgeA
                        } else {
                            let alongForward = startSnap.distanceAlongM <= endSnap.distanceAlongM
                            accessFrom = alongForward ? edgeA : edgeB
                            accessTo = alongForward ? edgeB : edgeA
                        }
                        if !pack.v4AccessAllowed(
                            ei: v.ei, from: accessFrom, to: accessTo,
                            startEi: startEi, endEi: endEi,
                            allowUnknown: policyUnknown,
                            startEndpointKind: startEndpointKind,
                            endEndpointKind: endEndpointKind,
                        customerStartEdges: ctx.customerStartEdges, customerEndEdges: ctx.customerEndEdges
                        ) { continue }
                    }
                    if ctx.pavedOnly {
                        if v.junctionStitch { continue }
                        if v.ei >= 0,
                           (try edgeBlockedByPavedOnly(v.ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi)) {
                            continue
                        }
                    }
                    // find-path-v2 does not U-turn-suppress virt expansions.
                    // Dirt/Balanced keep pre-E2 virt backtrack; Clean+leaves match JS.
                    if ctx.noBacktrack, v.ei >= 0,
                       !(profile == .cleanest && pack.hasLeaves),
                       isBacktrack(prevKind: labels[cur.node].predecessorKind, prevData: labels[cur.node].predecessorData, ei: v.ei, virt: virt) {
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
                    let edgeFrom = graphNode < n
                        ? coordinate(forNode: graphNode)
                        : (graphNode == startVirt ? startSnap.projected : endSnap.projected)
                    if try hopBlocked(toLL, edgeFrom: edgeFrom, edgeShape: v.coords, from: from, to: to, ctx: ctx) {
                        continue
                    }
                    let newMeters = labels[cur.node].pathMeters + v.meters
                    if exceedsLengthSlack(
                        newMeters: newMeters, toNode: item.to,
                        slackToDest: slackToDest, cap: ctx.maxPathMeters
                    ) { continue }
                    let isFerry = v.ei >= 0 && GraphV2Pack.isFerryStructure(
                        GraphV2Pack.unpackStructure(pack.edgeAttrs[v.ei]))
                    var step: Double
                    if isFerry {
                        step = (try preferenceStep((try fractionalFerryCost(edge: v.ei, meters: v.meters)), meters: v.meters, edge: v.ei))
                    } else if activeRidePreferences != nil, v.ei >= 0, !v.junctionStitch {
                        let attr = pack.edgeAttrs[v.ei]
                        step = (try hopCostStep(meters: v.meters, edgeIndex: v.ei,
                            surface: GraphV2Pack.unpackSurface(attr), roadClass: GraphV2Pack.unpackRoadClass(attr),
                            access: GraphV2Pack.unpackAccess(attr), confidence: GraphV2Pack.unpackConfidence(attr),
                            profile: profile, ctx: ctx, toLL: toLL, endLL: endLL, abMeters: abMeters,
                            projectedOrigin: startSnap.projected, startOnMajorHighway: startOnMajorHighway,
                            endOnMajorHighway: endOnMajorHighway, policyUnknown: policyUnknown))
                    } else { step = (try preferenceStep(v.meters / 1_000, meters: v.meters, edge: v.ei)) }
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
                        let away = awayExtra(fromNode: cur.node, toNode: item.to < n && v.ei >= 0 ? turnState.stateForArrival(node: item.to, incomingEdge: v.ei) : item.to)
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
                    if initialFuelApproach { step = v.meters / 1_000 }
                    let cost = cur.cost + step
                    let toState = item.to < n && v.ei >= 0
                        ? (continuationState ?? turnState.stateForArrival(node: item.to, incomingEdge: v.ei))
                        : item.to
                    let previousLabel = labels[toState]
                    var action = HopSearchPolicy.considerRelax(
                        newCost: cost,
                        oldCost: previousLabel.cost,
                        newEi: v.ei,
                        oldEi: previousLabel.predecessorData,
                        node: toState,
                        newIsDirt: false,
                        oldIsDirt: false,
                        seed: ctx.sessionSeed,
                        variety: ctx.variety,
                        slotsUsed: Int(previousLabel.slots)
                    )
                    if action != .reject, retraces(cur.node, v.roadSpan) { action = .reject }
                    if action == .stealPred, createsLabelCycle(from: cur.node, through: toState) {
                        action = .reject
                    }
                    if action != .reject {
                        if let failure = writeLabel(toState, { row in
                            applySlots(action, to: &row)
                            row.predecessor = cur.node
                            row.predecessorKind = 1
                            row.predecessorData = item.id
                            row.forward = item.forward
                            if HopSearchPolicy.shouldPush(action) {
                                row.cost = cost
                                row.pathMeters = newMeters
                            }
                        }) { return .failure(failure) }
                        if HopSearchPolicy.shouldPush(action) {
                            heap.push(node: toState, cost: cost)
                        }
                    }
                }
            }
        }

        guard labels[endVirt].cost.isFinite else {
            return .failure(RoutingWorkContext.stopReason.map(Failure.searchLimit) ?? (abort == "completed" ? .noPath : .searchLimit(abort)))
        }

        let geometryMeasurement = RoutingWorkContext.measurement
        let geometryPhase = geometryMeasurement?.begin(.geometry)
        defer { geometryMeasurement?.end(geometryPhase) }
        var legs: [Leg] = []
        var traversedSpans: [PathRetrace.Span] = []
        var node = endVirt
        var hops = 0
        while node != startVirt {
            hops += 1
            if hops > total + 4 { return .failure(.noPath) }
            let labelRow = labels[node]
            let parent = labelRow.predecessor
            guard parent >= 0 else { return .failure(.noPath) }
            if let span = pathRecord(node) { traversedSpans.append(span) }
            if labelRow.predecessorKind == 1 {
                let v = virt[labelRow.predecessorData]
                let forward = labelRow.forward
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
                if coords.count >= 2, v.meters > (initialFuelApproach ? 0 : 0.5) {
                    legs.append(Leg(
                        coordinates: coords,
                        distanceMeters: v.meters,
                        surfaceName: surface,
                        edgeId: id,
                        accessName: accessNameForVirtualTraversal(v, forward: forward,
                            startSnap: startSnap, endSnap: endSnap),
                        roadClassName: v.junctionStitch ? "unknown" : roadClassNameForEdge(v.ei),
                        surfaceLeaf: v.junctionStitch || !pack.hasLeaves ? nil : (try pack.surfaceLeaf(v.ei,query: edgeDetailQuery)),
                        structureType: v.junctionStitch ? nil : structureTypeForEdge(v.ei),
                        structureLeaf: v.junctionStitch ? nil : (try structureLeafForEdge(v.ei)),
                        layer: v.junctionStitch ? 0 : (try layerForEdge(v.ei)),
                        crossingLabel: v.junctionStitch ? nil : (try crossingLabelForEdge(v.ei)),
                        waterCrossing: v.junctionStitch ? false : (try waterCrossingForEdge(v.ei)),
                        edgeIndex: v.junctionStitch ? nil : v.ei,
                        fromNode: v.junctionStitch ? nil : virtualTraversalNodes(v, forward: forward, startSnap: startSnap, endSnap: endSnap).from,
                        toNode: v.junctionStitch ? nil : virtualTraversalNodes(v, forward: forward, startSnap: startSnap, endSnap: endSnap).to
                    ))
                }
            } else if labelRow.predecessorKind == 2 {
                // Coincident duplicate-node stitch — no geometry.
            } else {
                let ei = labelRow.predecessorData
                let aNode = turnState.graphNode(of: parent)
                let bNode = turnState.graphNode(of: node)
                guard aNode >= 0, aNode < n, bNode >= 0, bNode < n else {
                    return .failure(.noPath)
                }
                let a = coordinate(forNode: aNode)
                let b = coordinate(forNode: bNode)
                let m = Double(pack.edgeMeters[ei])
                let surface = OnDeviceProfileCosts.surfaceName(
                    code: GraphV2Pack.unpackSurface(pack.edgeAttrs[ei])
                )
                let id = pack.edgeId(ei)
                let shape = try edgePolyline(ei: ei, fromNode: aNode, toNode: bNode, fallback: [a, b])
                legs.append(Leg(
                    coordinates: shape,
                    distanceMeters: m,
                    surfaceName: surface,
                    edgeId: id,
                    accessName: accessNameForTraversal(ei, from: aNode, to: bNode),
                    roadClassName: roadClassNameForEdge(ei),
                    surfaceLeaf: pack.hasLeaves ? (try pack.surfaceLeaf(ei,query: edgeDetailQuery)) : nil,
                    structureType: structureTypeForEdge(ei),
                    structureLeaf: (try structureLeafForEdge(ei)),
                    layer: (try layerForEdge(ei)),
                    crossingLabel: (try crossingLabelForEdge(ei)),
                    waterCrossing: (try waterCrossingForEdge(ei)),
                    edgeIndex: ei,
                    fromNode: aNode,
                    toNode: bNode
                ))
            }
            node = parent
        }
        legs.reverse()
        if pack.version >= 4, PathRetrace.repeats(traversedSpans) { return .failure(.searchLimit("retrace_rejected")) }
        let customerIDs = Set(ctx.customerStartEdges.union(ctx.customerEndEdges).union([startEi, endEi]).filter {
            pack.version >= 4 && ($0 * 2 + 1) < pack.edgeAccess.count &&
                (pack.edgeAccess[$0 * 2] == 4 || pack.edgeAccess[$0 * 2 + 1] == 4)
        }.map { pack.edgeId($0) })
        guard CustomerEndpointAccess.validRuns(legs.map { ($0.edgeId, $0.distanceMeters) },
            customerIDs: customerIDs, start: startEndpointKind == "customers", end: endEndpointKind == "customers") else {
            return .failure(.searchLimit("customer_access_scope"))
        }

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
                allowUnknown: policyUnknown
            ),
            pops: pops, abort: abort, started: huntStart, isHunt: isHunt
        ))
        } catch {
            return .failure(.searchLimit(RoutingWorkContext.stopReason ?? "routingDataUnavailable"))
        }
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
        do {
        let measurement = RoutingWorkContext.measurement
        let measuredPhase = measurement?.begin(.search)
        defer { measurement?.end(measuredPhase) }
        let directedStepMemo = useDirectedStepMemo ? DirectedStepMemo() : nil
        measurement?.set(.directedCostMemoBytes,to: UInt64(directedStepMemo?.payloadBytes ?? 0))
        defer {
            measurement?.increment(.directedCostMemoHits,by: directedStepMemo?.hits ?? 0)
            measurement?.increment(.directedCostMemoMisses,by: directedStepMemo?.misses ?? 0)
            measurement?.increment(.directedCostMemoEvictions,by: directedStepMemo?.evictions ?? 0)
            measurement?.set(.directedCostMemoBytes,to: 0)
        }
        let startEi = startSnap.edgeIndex
        let endEi = endSnap.edgeIndex
        let endLL = endSnap.projected
        let abMeters = meters(startSnap.projected, endLL)
        let startOnMajorHighway = (try snapIsMajorHighwayPin(startSnap, profile: profile))
        let endOnMajorHighway = (try snapIsMajorHighwayPin(endSnap, profile: profile))
        let B = HopSearchPolicy.balancedBuckets
        let turnState = legalTurnState ?? pack.makeV4TurnStateSpace(startNode: startVirt, endNode: endVirt)
        let totalNodes = turnState.stateCount
        let labels = totalNodes * B
        func lab(_ node: Int, _ bucket: Int) -> Int { node * B + bucket }
        func sid(_ label: Int) -> Int { label / B }

        guard let labelStore = try? DemandBalancedSearchLabels(
            stateCount: labels, maxPayloadBytes: maximumSearchLabelPayloadBytes,
            pageCapacity: profile == .balanced ? balancedLabelPageCapacity : 256,
            useReadPointerCache: useLabelReadPointerCache,
            readCacheSlots: profile == .balanced ? balancedLabelReadCacheSlots : 256,
            shouldStop: { RoutingWorkContext.stopReason != nil }
        ) else { return .failure(.searchLimit("labelStorageConfiguration")) }
        var measuredLabelCapacity = 0
        var measuredLabelPages = 0
        func publishLabelAllocation() {
            guard labelStore.allocationRevision != measuredLabelPages else { return }
            let stats = labelStore.statistics
            measurement?.increment(.labelPagesAllocated, by: UInt64(stats.allocatedPages - measuredLabelPages))
            measurement?.increment(.labelsCreated, by: UInt64(stats.allocatedLabelCapacity - measuredLabelCapacity))
            measurement?.set(.labelBytes, to: UInt64(stats.allocatedPayloadBytes))
            measurement?.set(.labelDirectoryLogicalBytes, to: UInt64(stats.logicalPageDirectoryEntryBytes))
            measuredLabelPages = stats.allocatedPages
            measuredLabelCapacity = stats.allocatedLabelCapacity
        }
        defer {
            let stats = labelStore.statistics
            measurement?.increment(.resourceFiniteLabels, by: UInt64(stats.finiteLabels))
            measurement?.increment(.resourceAllocatedLabelSlots, by: UInt64(stats.allocatedLabelCapacity))
            measurement?.increment(.resourceAllocatedPages, by: UInt64(stats.allocatedPages))
            measurement?.set(.labelBytes, to: 0)
            measurement?.set(.labelDirectoryLogicalBytes, to: 0)
        }
        var labelMemoryExhausted = false
        func writeLabel(_ state: Int, _ update: (inout DemandBalancedSearchLabels.Label) -> Void) -> Failure? {
            do {
                try labelStore.mutate(state, update)
                publishLabelAllocation()
                return nil
            } catch DemandBalancedSearchLabels.StorageError.memoryLimit {
                labelMemoryExhausted = true
                return .searchLimit("labelMemoryCap:payloadBytes=\(maximumSearchLabelPayloadBytes)")
            } catch DemandBalancedSearchLabels.StorageError.cancelled {
                return .searchLimit(RoutingWorkContext.stopReason ?? "cancelled")
            } catch {
                return .searchLimit("labelStorageInvalidState")
            }
        }
        func applySlots(_ action: HopSearchPolicy.RelaxAction, to row: inout DemandBalancedSearchLabels.Label) {
            // Identical to HopSearchPolicy.apply; rejection never allocates.
            if action == .acceptReset { row.slots = 1 }
            else if action != .reject, row.slots < 255 { row.slots += 1 }
        }
        func createsLabelCycle(from: Int, through target: Int) -> Bool {
            var node = from
            var hops = 0
            let cap = labels + 2
            while node >= 0, hops < cap {
                if node == target { return true }
                node = labelStore[node].predecessor
                hops += 1
            }
            return hops >= cap
        }
        func pathRecord(_ label: Int) -> PathRetrace.Span? {
            let row = labelStore[label]
            if row.predecessor < 0 { return nil }
            if row.predecessorKind == 0 {
                let ei = row.predecessorData
                return .init(edge: ei, lower: 0, upper: Double(pack.edgeMeters[ei]))
            }
            return row.predecessorKind == 1 ? virt[row.predecessorData].roadSpan : nil
        }
        var retraceQueries: UInt64 = 0
        var retracePredecessorVisits: UInt64 = 0
        defer {
            measurement?.increment(.resourceRetraceQueries, by: retraceQueries)
            measurement?.increment(.resourceRetracePredecessorVisits, by: retracePredecessorVisits)
        }
        func retraces(_ label: Int, _ span: PathRetrace.Span?) -> Bool {
            guard pack.version >= 4, let span else { return false }
            retraceQueries &+= 1
            if !useCombinedRetraceCallback {
                let result = PathRetrace.containsCounted(node: label, span: span,
                    previous: { labelStore[$0].predecessor }, record: { ancestor in
                        let row = labelStore[ancestor]
                        guard row.predecessor >= 0 else { return nil }
                        let entry = row.predecessorData
                        if row.predecessorKind == 0 {
                            guard entry == span.edge else { return nil }
                            return .init(edge: entry, lower: 0, upper: Double(pack.edgeMeters[entry]))
                        }
                        return row.predecessorKind == 1 ? virt[entry].roadSpan : nil
                    })
                retracePredecessorVisits &+= result.visits
                return result.contains
            }
            // Synchronous read-only traversal retains the same predecessor
            // chain; bucket identities and relaxation order remain unchanged.
            let result = PathRetrace.containsCounted(node: label, span: span, step: { ancestor in
                let row = labelStore[ancestor]
                guard row.predecessor >= 0 else { return (row.predecessor,nil) }
                let entry = row.predecessorData
                if row.predecessorKind == 0 {
                    guard entry == span.edge else { return (row.predecessor,nil) }
                    return (row.predecessor,.init(edge: entry, lower: 0, upper: Double(pack.edgeMeters[entry])))
                }
                return (row.predecessor,row.predecessorKind == 1 ? virt[entry].roadSpan : nil)
            })
            retracePredecessorVisits &+= result.visits
            return result.contains
        }
        func selectedResourceEnd() -> (lab: Int, len: Double, dirt: Double, score: Double)? {
            var labelsAtEnd: [(lab: Int, len: Double, dirt: Double, score: Double)] = []
            for b in 0..<B {
                let endLab = lab(endVirt, b)
                let len = labelStore[endLab].pathMeters
                guard len.isFinite, len > 0 else { continue }
                labelsAtEnd.append((endLab, len, labelStore[endLab].dirtMeters, labelStore[endLab].cost))
            }
            let inBand = profile == .balanced ? labelsAtEnd.filter {
                let ratio = $0.len > 0 ? $0.dirt / $0.len : 0
                return ratio >= HopSearchPolicy.balancedDirtLo && ratio <= HopSearchPolicy.balancedDirtHi
            } : []
            let candidatePool = profile == .balanced && !inBand.isEmpty ? inBand : labelsAtEnd
            return candidatePool.min { a, b in
                let ratioA = a.len > 0 ? a.dirt / a.len : 0
                let ratioB = b.len > 0 ? b.dirt / b.len : 0
                if profile == .dirt, (activeRidePreferences?.wander ?? 1) == 1, abs(ratioA - ratioB) > 0.005 {
                    return ratioA > ratioB
                }
                if let preferences = activeRidePreferences, preferences.wander < 1 {
                    if profile == .dirt {
                        let costA = NativeRidePreferenceCosts.dirtCandidateCost(meters: a.len, dirtMeters: a.dirt, preferences: preferences)
                        let costB = NativeRidePreferenceCosts.dirtCandidateCost(meters: b.len, dirtMeters: b.dirt, preferences: preferences)
                        if costA != costB { return costA < costB }
                    } else if profile == .balanced && !inBand.isEmpty {
                        // Surface feasibility stays mandatory; among its accepted
                        // mixture band, lower Wander values discourage extra riding.
                        let costA = a.score
                        let costB = b.score
                        if costA != costB { return costA < costB }
                    }
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
            }
        }

        var heap = MinHeap()
        defer { heap.flushMeasurement() }
        let startLab = lab(startVirt, 0)
        if let failure = writeLabel(startLab, { $0.cost = 0; $0.pathMeters = 0 }) {
            return .failure(failure)
        }
        heap.push(node: startLab, cost: 0)

        let cap = ctx.maxPathMeters ?? .infinity
        var pops = 0
        var abort = "completed"
        let isHunt = ctx.maxPathMeters != nil || ctx.boundedSearch
        let huntStart = CFAbsoluteTimeGetCurrent()
        let popCap = isHunt ? (ctx.popCap ?? HopSearchPolicy.pass2PopCap) : 8_000_000
        let perSearchDeadline: Double? = isHunt
            ? huntStart + (ctx.timeCapSeconds ?? HopSearchPolicy.pass2TimeCapSeconds)
            : nil
        let deadline = ctx.calculationDeadline.map { min($0, perSearchDeadline ?? $0) } ?? perSearchDeadline

        resourceSearch: while let cur = heap.pop() {
            if let reason = RoutingWorkContext.stopReason { return .failure(.searchLimit(reason)) }
            pops += 1
            if pops > popCap { abort = "popCap"; break }
            if let deadline, (pops & 255) == 0, CFAbsoluteTimeGetCurrent() > deadline {
                abort = "timeCap"
                break
            }
            let currentLabel = labelStore[cur.node]
            if cur.cost != currentLabel.cost { continue }
            if profile == .balanced, (pops & 255) == 0,
               let incumbent = selectedResourceEnd(),
               (0..<B).allSatisfy({ bucket in
                    let row = labelStore[lab(endVirt, bucket)]
                    guard row.pathMeters.isFinite, row.pathMeters > 0 else { return true }
                    let ratio = row.dirtMeters / row.pathMeters
                    guard ratio >= HopSearchPolicy.balancedDirtLo,
                          ratio <= HopSearchPolicy.balancedDirtHi else { return true }
                    // Epsilon comparisons are not transitive. Require this
                    // incumbent to beat every current eligible end label as
                    // well as all future ones, rather than relying on min's
                    // fold order to define a total ranking.
                    let incumbentError = abs(incumbent.dirt / incumbent.len - 0.5)
                    let candidateError = abs(ratio - 0.5)
                    if abs(incumbentError - candidateError) > 0.005 {
                        return incumbentError < candidateError
                    }
                    if abs(incumbent.score - row.cost) > 50 { return incumbent.score < row.cost }
                    return incumbent.len <= row.pathMeters
               }),
               BalancedTerminationProof.canFinish(
                    dirtMeters: incumbent.dirt, pathMeters: incumbent.len,
                    selectionCost: incumbent.score, frontierMinimumCost: cur.cost) {
                // All remaining represented paths have nonnegative extensions.
                // This is an objective bound, not a timeout or no-path claim.
                abort = "balancedObjectiveBound"
                break
            }
            let metersSoFar = currentLabel.pathMeters
            if metersSoFar > cap { continue }
            let state = sid(cur.node)
            let node = turnState.graphNode(of: state)
            let dirtSoFar = currentLabel.dirtMeters

            if node < n {
                let arcStart = Int(pack.nodeOffsets[node])
                let arcEnd = Int(pack.nodeOffsets[node + 1])
                guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
                heap.recordExpansion(arcs: arcEnd - arcStart)
                for i in arcStart..<arcEnd {
                    let toNode = Int(pack.edgeTargets[i])
                    let ei = Int(pack.edgeUndirectedIndex[i])
                    guard ei >= 0, ei < pack.undirectedEdgeCount else { continue }
                    if ctx.noBacktrack,
                       isBacktrack(prevKind: currentLabel.predecessorKind, prevData: currentLabel.predecessorData, ei: ei, virt: virt) {
                        continue
                    }
                    if !pack.v4AccessAllowed(
                        ei: ei, from: node, to: toNode,
                        startEi: startEi, endEi: endEi,
                        allowUnknown: policyUnknown,
                        startEndpointKind: startEndpointKind,
                        endEndpointKind: endEndpointKind,
                        customerStartEdges: ctx.customerStartEdges, customerEndEdges: ctx.customerEndEdges
                    ) { continue }
                    let toState = turnState.transition(
                        state: state, outgoingEdge: ei, toNode: toNode
                    )
                    if toState < 0 { continue }
                    let attr = pack.edgeAttrs[ei]
                    let access = GraphV2Pack.unpackAccess(attr)
                    if pack.version < 4,
                       !accessAllowed(access, allowUnknown: policyUnknown, profile: profile) {
                        continue
                    }
                    if (try edgeBlockedByPavedOnly(ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi)) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
                    let toLL = coordinate(forNode: toNode)
                    if try hopBlocked(toLL, edgeFrom: coordinate(forNode: node), edgeIndex: ei, from: from, to: to, ctx: ctx) { continue }
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
                    let toLab = lab(toState, b)
                    func staticDirectedStep() throws -> Double {
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
                    var step = (try hopCostStep(
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
                        projectedOrigin: startSnap.projected,
                        startOnMajorHighway: startOnMajorHighway,
                        endOnMajorHighway: endOnMajorHighway,
                        policyUnknown: policyUnknown
                    ))
                    if shortDirtPenalized {
                        step *= HopSearchPolicy.dirtRidePavedPerKm
                    }
                    if !isFerry {
                        step *= settlementMult * urbanMult
                    }
                    return backtrackPenalized(step,edgeID: eid,ctx: ctx)
                    }
                    let directedStep = try directedStepMemo?.value(arc: i,make: staticDirectedStep) ?? (try staticDirectedStep())
                    let newScore = cur.cost + directedStep
                    let previousLabel = labelStore[toLab]
                    var action = HopSearchPolicy.considerRelax(
                        newCost: newScore,
                        oldCost: previousLabel.cost,
                        newEi: ei,
                        oldEi: previousLabel.predecessorData,
                        node: toState,
                        newIsDirt: addDirt > 0,
                        oldIsDirt: previousLabel.dirtMeters > (previousLabel.pathMeters.isFinite ? previousLabel.pathMeters * 0.4 : 0),
                        seed: ctx.sessionSeed,
                        variety: ctx.variety,
                        slotsUsed: Int(previousLabel.slots)
                    )
                    if action != .reject, retraces(cur.node, .init(edge: ei, lower: 0, upper: Double(pack.edgeMeters[ei]))) { action = .reject }
                    if action == .stealPred, createsLabelCycle(from: cur.node, through: toLab) {
                        action = .reject
                    }
                    if action != .reject {
                        if let failure = writeLabel(toLab, { row in
                            applySlots(action, to: &row)
                            row.predecessor = cur.node
                            row.predecessorKind = 0
                            row.predecessorData = ei
                            row.forward = true
                            if HopSearchPolicy.shouldPush(action) {
                                row.cost = newScore
                                row.pathMeters = newMeters
                                row.dirtMeters = newDirt
                            }
                        }) {
                            if labelMemoryExhausted, profile == .balanced,
                               RoutingWorkContext.stopReason == nil, selectedResourceEnd() != nil {
                                abort = "labelMemoryCap"
                                break resourceSearch
                            }
                            return .failure(failure)
                        }
                        if HopSearchPolicy.shouldPush(action) {
                            heap.push(node: toLab, cost: newScore)
                        }
                    }
                }
                if pack.version < 4, let siblings = coincidentSiblings[node] {
                    for toNode in siblings {
                        let bucket = HopSearchPolicy.dirtBucket(
                            dirtMeters: dirtSoFar,
                            pathMeters: metersSoFar
                        )
                        let toLab = lab(toNode, bucket)
                        if cur.cost < labelStore[toLab].cost {
                            if let failure = writeLabel(toLab, { row in
                                row.cost = cur.cost
                                row.pathMeters = metersSoFar
                                row.dirtMeters = dirtSoFar
                                row.predecessor = cur.node
                                row.predecessorKind = 2
                                row.predecessorData = -1
                                row.forward = true
                            }) {
                                if labelMemoryExhausted, profile == .balanced,
                                   RoutingWorkContext.stopReason == nil, selectedResourceEnd() != nil {
                                    abort = "labelMemoryCap"
                                    break resourceSearch
                                }
                                return .failure(failure)
                            }
                            heap.push(node: toLab, cost: cur.cost)
                        }
                    }
                }
            }

            if let vlist = virtAdj[node] {
                for item in vlist {
                    let v = virt[item.id]
                    let continuationState: Int?
                    if node == startVirt, importedArrival != nil, v.ei >= 0 {
                        let direction = virtualTraversalNodes(v, forward: item.forward, startSnap: startSnap, endSnap: endSnap)
                        let restored = continuationStartState(edge: v.ei, targetNode: direction.to,
                            movement: v.meters, turns: turnState)
                        if restored < 0 { continue }
                        continuationState = restored
                    } else { continuationState = nil }
                    if pack.version >= 4, v.ei >= 0, !(continuationState != nil && v.meters == 0) {
                        if item.to == endVirt, v.meters > 0,
                           !turnState.allowsExit(state: state, outgoingEdge: v.ei) {
                            continue
                        }
                        let edgeA = Int(pack.edgeFrom?[v.ei] ?? -1)
                        let edgeB = Int(pack.edgeTo?[v.ei] ?? -1)
                        let accessFrom: Int
                        let accessTo: Int
                        if node == startVirt, item.to < n {
                            accessTo = item.to
                            accessFrom = item.to == edgeA ? edgeB : edgeA
                        } else if node < n, item.to == endVirt {
                            accessFrom = node
                            accessTo = node == edgeA ? edgeB : edgeA
                        } else {
                            let alongForward = startSnap.distanceAlongM <= endSnap.distanceAlongM
                            accessFrom = alongForward ? edgeA : edgeB
                            accessTo = alongForward ? edgeB : edgeA
                        }
                        if !pack.v4AccessAllowed(
                            ei: v.ei, from: accessFrom, to: accessTo,
                            startEi: startEi, endEi: endEi,
                            allowUnknown: policyUnknown,
                            startEndpointKind: startEndpointKind,
                            endEndpointKind: endEndpointKind,
                        customerStartEdges: ctx.customerStartEdges, customerEndEdges: ctx.customerEndEdges
                        ) { continue }
                    }
                    if ctx.pavedOnly {
                        if v.junctionStitch { continue }
                        if v.ei >= 0,
                           (try edgeBlockedByPavedOnly(v.ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi)) {
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
                    if ctx.cityWall {
                        let blockedLL = item.to < n ? coordinate(forNode: item.to) : endSnap.projected
                        if try hopBlocked(blockedLL, edgeFrom: edgeFrom, edgeShape: v.coords, from: from, to: to, ctx: ctx) { continue }
                    }
                    let virtualEdgeID = v.junctionStitch
                        ? v.stitchEdgeId
                        : (v.ei >= 0 ? pack.edgeId(v.ei) : "")
                    let shortDirtPenalized = profile == .dirt
                        && ctx.shortDirtPenaltyEdgeIds.contains(virtualEdgeID)
                    let isFerry = v.ei >= 0 && GraphV2Pack.isFerryStructure(
                        GraphV2Pack.unpackStructure(pack.edgeAttrs[v.ei]))
                    let addDirt = !v.junctionStitch && v.ei >= 0 && !isFerry
                        && !shortDirtPenalized && edgeIsDirt(v.ei) ? v.meters : 0
                    let newDirt = dirtSoFar + addDirt
                    let b = HopSearchPolicy.dirtBucket(dirtMeters: newDirt, pathMeters: newMeters)
                    let toState = item.to < n && v.ei >= 0
                        ? (continuationState ?? turnState.stateForArrival(node: item.to, incomingEdge: v.ei))
                        : item.to
                    let toLab = lab(toState, b)
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
                    let virtualStep: Double
                    if isFerry {
                        virtualStep = (try fractionalFerryCost(edge: v.ei, meters: v.meters))
                    } else {
                        virtualStep = (v.meters / 1_000) * settlementMult * urbanMult
                            * (shortDirtPenalized ? HopSearchPolicy.dirtRidePavedPerKm : 1)
                    }
                    let newScore = cur.cost + backtrackPenalized(
                        (try preferenceStep(virtualStep, meters: v.meters, edge: v.ei)),
                        edgeID: virtualEdgeID,
                        ctx: ctx
                    )
                    if newScore < labelStore[toLab].cost, !retraces(cur.node, v.roadSpan) {
                        if let failure = writeLabel(toLab, { row in
                            row.cost = newScore
                            row.pathMeters = newMeters
                            row.dirtMeters = newDirt
                            row.predecessor = cur.node
                            row.predecessorKind = 1
                            row.predecessorData = item.id
                            row.forward = item.forward
                        }) {
                            if labelMemoryExhausted, profile == .balanced,
                               RoutingWorkContext.stopReason == nil, selectedResourceEnd() != nil {
                                abort = "labelMemoryCap"
                                break resourceSearch
                            }
                            return .failure(failure)
                        }
                        heap.push(node: toLab, cost: newScore)
                    }
                }
            }
        }

        let bestLab = selectedResourceEnd()?.lab
        guard let bestLab,
              labelStore[bestLab].cost.isFinite else {
            return .failure(RoutingWorkContext.stopReason.map(Failure.searchLimit) ?? (abort == "completed" ? .noPath : .searchLimit(abort)))
        }

        let geometryMeasurement = RoutingWorkContext.measurement
        let geometryPhase = geometryMeasurement?.begin(.geometry)
        defer { geometryMeasurement?.end(geometryPhase) }
        var legs: [Leg] = []
        var traversedSpans: [PathRetrace.Span] = []
        var label = bestLab
        var hops = 0
        while sid(label) != startVirt {
            hops += 1
            if hops > labels + 4 { return .failure(.noPath) }
            let labelRow = labelStore[label]
            let parent = labelRow.predecessor
            guard parent >= 0 else { return .failure(.noPath) }
            if let span = pathRecord(label) { traversedSpans.append(span) }
            if labelRow.predecessorKind == 1 {
                let v = virt[labelRow.predecessorData]
                let forward = labelRow.forward
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
                if coords.count >= 2, v.meters > (initialFuelApproach ? 0 : 0.5) {
                    legs.append(Leg(
                        coordinates: coords,
                        distanceMeters: v.meters,
                        surfaceName: surface,
                        edgeId: id,
                        accessName: accessNameForVirtualTraversal(v, forward: forward,
                            startSnap: startSnap, endSnap: endSnap),
                        roadClassName: v.junctionStitch ? "unknown" : roadClassNameForEdge(v.ei),
                        surfaceLeaf: v.junctionStitch || !pack.hasLeaves ? nil : (try pack.surfaceLeaf(v.ei,query: edgeDetailQuery)),
                        structureType: v.junctionStitch ? nil : structureTypeForEdge(v.ei),
                        structureLeaf: v.junctionStitch ? nil : (try structureLeafForEdge(v.ei)),
                        layer: v.junctionStitch ? 0 : (try layerForEdge(v.ei)),
                        crossingLabel: v.junctionStitch ? nil : (try crossingLabelForEdge(v.ei)),
                        waterCrossing: v.junctionStitch ? false : (try waterCrossingForEdge(v.ei)),
                        edgeIndex: v.junctionStitch ? nil : v.ei,
                        fromNode: v.junctionStitch ? nil : virtualTraversalNodes(v, forward: forward, startSnap: startSnap, endSnap: endSnap).from,
                        toNode: v.junctionStitch ? nil : virtualTraversalNodes(v, forward: forward, startSnap: startSnap, endSnap: endSnap).to
                    ))
                }
            } else if labelRow.predecessorKind == 2 {
                // Coincident duplicate-node stitch — no geometry.
            } else {
                let ei = labelRow.predecessorData
                let aNode = turnState.graphNode(of: sid(parent))
                let bNode = turnState.graphNode(of: sid(label))
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
                let shape = try edgePolyline(ei: ei, fromNode: aNode, toNode: bNode, fallback: [a, b])
                legs.append(Leg(
                    coordinates: shape,
                    distanceMeters: m,
                    surfaceName: surface,
                    edgeId: id,
                    accessName: accessNameForTraversal(ei, from: aNode, to: bNode),
                    roadClassName: roadClassNameForEdge(ei),
                    surfaceLeaf: pack.hasLeaves ? (try pack.surfaceLeaf(ei,query: edgeDetailQuery)) : nil,
                    structureType: structureTypeForEdge(ei),
                    structureLeaf: (try structureLeafForEdge(ei)),
                    layer: (try layerForEdge(ei)),
                    crossingLabel: (try crossingLabelForEdge(ei)),
                    waterCrossing: (try waterCrossingForEdge(ei)),
                    edgeIndex: ei,
                    fromNode: aNode,
                    toNode: bNode
                ))
            }
            label = parent
        }
        legs.reverse()
        if pack.version >= 4, PathRetrace.repeats(traversedSpans) { return .failure(.searchLimit("retrace_rejected")) }
        let customerIDs = Set(ctx.customerStartEdges.union(ctx.customerEndEdges).union([startEi, endEi]).filter {
            pack.version >= 4 && ($0 * 2 + 1) < pack.edgeAccess.count &&
                (pack.edgeAccess[$0 * 2] == 4 || pack.edgeAccess[$0 * 2 + 1] == 4)
        }.map { pack.edgeId($0) })
        guard CustomerEndpointAccess.validRuns(legs.map { ($0.edgeId, $0.distanceMeters) },
            customerIDs: customerIDs, start: startEndpointKind == "customers", end: endEndpointKind == "customers") else {
            return .failure(.searchLimit("customer_access_scope"))
        }
        if let stub = softStitchStub(tap: from, snap: startSnap, idSuffix: "start") {
            legs.insert(stub, at: 0)
        }
        if let stub = softStitchStub(tap: to, snap: endSnap, idSuffix: "end") {
            legs.append(stub)
        }
        var result = stampHunt(
            finalize(
                legs: legs,
                nodeFallback: [startSnap.projected, endSnap.projected],
                profile: profile,
                allowUnknown: policyUnknown
            ),
            pops: pops, abort: abort, started: huntStart, isHunt: isHunt
        )
        if abort == "labelMemoryCap" {
            // Road completion passed the same reconstruction/legal checks as
            // time-capped routes; riding selection remains incomplete.
            result.searchMeta.pass2Outcome = abort
            result.searchMeta.timedOut = true
        }
        result.searchMeta.resourceSelectionCost = labelStore[bestLab].cost
        result.searchMeta.resourceSelectionDirtMeters = labelStore[bestLab].dirtMeters
        return .success(result)
        } catch {
            return .failure(.searchLimit(RoutingWorkContext.stopReason ?? "routingDataUnavailable"))
        }
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
        startEi: Int, endEi: Int,
        profile: RouteProfile,
        policyUnknown: Bool,
        avoidEdgeIds: Set<String>,
        coincidentSiblings: [[Int]?]
    ) throws -> [Double] {
        let measurement = RoutingWorkContext.measurement
        let measuredPhase = measurement?.begin(.reverseGuidance)
        defer { measurement?.end(measuredPhase) }
        measurement?.increment(.labelsCreated, by: UInt64(total))
        var dist = [Double](repeating: .infinity, count: total)
        var heap = MinHeap()
        defer { heap.flushMeasurement() }
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
            try RoutingWorkContext.check()
            if cur.cost != dist[cur.node] { continue }
            if cur.cost > capMeters { continue }
            if cur.node < n {
                let arcStart = incomingOffsets[cur.node]
                let arcEnd = incomingOffsets[cur.node + 1]
                heap.recordExpansion(arcs: arcEnd - arcStart)
                for i in arcStart..<arcEnd {
                    let toNode = Int(incomingSources[i])
                    let ei = Int(incomingEdges[i])
                    guard ei >= 0, ei < pack.undirectedEdgeCount else { continue }
                    let attr = pack.edgeAttrs[ei]
                    let access = GraphV2Pack.unpackAccess(attr)
                    if pack.version >= 4, pack.legalTopology {
                        // Transpose lower bound: actual travel is toNode ->
                        // cur.node. Endpoint-only edges remain admissible here;
                        // the forward search proves exact endpoint intent.
                        let code = Int(pack.v4AccessCode(ei: ei, from: toNode, to: cur.node))
                        if code == 2 || code == 5 || (code == 1 && !policyUnknown) { continue }
                    } else if !accessAllowed(
                        access, allowUnknown: policyUnknown, profile: profile
                    ) {
                        continue
                    }
                    if (try edgeBlockedByPavedOnly(ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi)) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
                    let toLL = coordinate(forNode: toNode)
                    if try hopBlocked(toLL, edgeFrom: coordinate(forNode: cur.node), edgeIndex: ei, from: from, to: to, ctx: ctx) { continue }
                    let edgeM = Double(pack.edgeMeters[ei])
                    let cand = cur.cost + edgeM
                    if cand > capMeters { continue }
                    if cand < dist[toNode] {
                        dist[toNode] = cand
                        heap.push(node: toNode, cost: cand)
                    }
                }
                if pack.version < 4, let siblings = coincidentSiblings[cur.node] {
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
                        if try v.junctionStitch || (v.ei >= 0 && (try edgeBlockedByPavedOnly(v.ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi))) { continue }
                    }
                    let edgeFrom = cur.node < n
                        ? coordinate(forNode: cur.node)
                        : (cur.node == origin ? to : from)
                    if try hopBlocked(
                        item.to < n ? coordinate(forNode: item.to) : (item.to == origin ? to : from),
                        edgeFrom: edgeFrom,
                        edgeShape: v.coords, from: from, to: to, ctx: ctx
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
            if ei & 4095 == 0 { RoutingWorkContext.measurement?.sampleIfDue() }
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
        do {
        let measurement = RoutingWorkContext.measurement
        let measuredPhase = measurement?.begin(.search)
        defer { measurement?.end(measuredPhase) }
        let startEi = startSnap.edgeIndex
        let endEi = endSnap.edgeIndex
        let start = preferredNode(for: startSnap, toward: to)
        let end = preferredNode(for: endSnap, toward: from)
        if start == end {
            return .failure(.identicalEnds)
        }

        let n = pack.nodeCount
        measurement?.increment(.labelsCreated, by: UInt64(n))
        var dist = [Double](repeating: .infinity, count: n)
        var prev = [Int](repeating: -1, count: n)
        var prevEdge = [Int](repeating: -1, count: n)
        /// Negative prevEdge marks a junction stitch index into `stitches`.
        var prevStitch = [Int](repeating: -1, count: n)
        var heap = MinHeap()
        defer { heap.flushMeasurement() }

        dist[start] = 0
        heap.push(node: start, cost: 0)

        let policyUnknown = allowUnknown && profile != .cleanest
        let endLL = endSnap.projected
        let abMeters = meters(startSnap.projected, endLL)
        let startOnMajorHighway = (try snapIsMajorHighwayPin(startSnap, profile: profile))
        let endOnMajorHighway = (try snapIsMajorHighwayPin(endSnap, profile: profile))
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
            if let reason = RoutingWorkContext.stopReason { return .failure(.searchLimit(reason)) }
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
                    if !accessAllowed(access, allowUnknown: policyUnknown, profile: profile) { continue }
                    if (try edgeBlockedByPavedOnly(ei, ctx: ctx, allowSnapEdges: startEi, endEi: endEi)) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
                    if ctx.noBacktrack, prevEdge[cur.node] == ei { continue }
                    if pack.v4HopIllegal(
                        ei: ei, from: cur.node, to: toNode,
                        startEi: startEi, endEi: endEi,
                        incomingEi: prevEdge[cur.node]
                    ) { continue }
                    let toLL = coordinate(forNode: toNode)
                    if try hopBlocked(toLL, edgeFrom: coordinate(forNode: cur.node), edgeIndex: ei, from: from, to: to, ctx: ctx) {
                        continue
                    }

                    let surface = GraphV2Pack.unpackSurface(attr)
                    let roadClass = GraphV2Pack.unpackRoadClass(attr)
                    let confidence = GraphV2Pack.unpackConfidence(attr)
                    var step = (try hopCostStep(
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
                        projectedOrigin: startSnap.projected,
                        startOnMajorHighway: startOnMajorHighway,
                        endOnMajorHighway: endOnMajorHighway,
                        policyUnknown: policyUnknown
                    ))
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
                    if initialFuelApproach { step = Double(pack.edgeMeters[ei]) / 1_000 }
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
                    if initialFuelApproach { step = s.meters / 1_000 }
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

        if let reason = RoutingWorkContext.stopReason { return .failure(.searchLimit(reason)) }
        guard dist[end].isFinite else { return .failure(.noPath) }

        let geometryMeasurement = RoutingWorkContext.measurement
        let geometryPhase = geometryMeasurement?.begin(.geometry)
        defer { geometryMeasurement?.end(geometryPhase) }
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
                let shape = try edgePolyline(ei: ei, fromNode: parent, toNode: node, fallback: [a, b])
                legs.append(Leg(
                    coordinates: shape,
                    distanceMeters: m,
                    surfaceName: surface,
                    edgeId: id,
                    accessName: accessNameForTraversal(ei, from: parent, to: node),
                    roadClassName: roadClassNameForEdge(ei),
                    surfaceLeaf: pack.hasLeaves ? (try pack.surfaceLeaf(ei,query: edgeDetailQuery)) : nil,
                    structureType: structureTypeForEdge(ei),
                    structureLeaf: (try structureLeafForEdge(ei)),
                    layer: (try layerForEdge(ei)),
                    crossingLabel: (try crossingLabelForEdge(ei)),
                    waterCrossing: (try waterCrossingForEdge(ei)),
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
            allowUnknown: allowUnknown && profile != .cleanest
        ))
        } catch {
            return .failure(.searchLimit(RoutingWorkContext.stopReason ?? "routingDataUnavailable"))
        }
    }

    // MARK: - Finalize + geographic prune

    private func finalize(
        legs: [Leg],
        nodeFallback: [CLLocationCoordinate2D],
        profile: RouteProfile = .balanced,
        allowUnknown: Bool = false
    ) -> Result {
        let measurement = RoutingWorkContext.measurement
        let measuredPhase = measurement?.begin(.finalValidation)
        defer { measurement?.end(measuredPhase) }
        var worked = legs

        // Geographic loop pruning when legs carry real polyline geometry.
        // Clean+leaves lockstep: JS `pruneGeographicLoops` is a no-op on the NS
        // fixture routes; Swift's proximity-grid variant can drop short stubs and
        // break edge-id identity. Skip prune so both engines keep the Dijkstra list.
        let skipGeoPrune = profile == .cleanest && pack.hasLeaves
        let hasGeometry = worked.contains { $0.coordinates.count >= 3 }
            || pack.geometry != nil
        if pack.version < 4, hasGeometry, !worked.isEmpty, !skipGeoPrune {
            let pieces = worked.map {
                OnDevicePathPruning.EdgePiece(
                    edgeId: $0.edgeId,
                    coords: $0.coordinates,
                    meters: $0.distanceMeters,
                    surfaceName: $0.surfaceName
                )
            }
            let pruned = OnDevicePathPruning.pruneGeographicLoops(
                pieces,
                options: OnDevicePathPruning.Options(
                    cellMeters: 20,
                    matchMeters: 30,
                    minLoopMeters: 20
                )
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
            coordinates: idSuffix == "end" ? [snap.projected, tap] : [tap, snap.projected],
            distanceMeters: d,
            surfaceName: "access",
            edgeId: "soft-stitch-\(idSuffix)"
        )
    }

    // MARK: - Geometry helpers

    private func edgeGeometry(_ ei: Int) throws -> [CLLocationCoordinate2D]? {
        guard let geom = pack.geometry else { return nil }
        let poly = try geom.polyline(edgeIndex: ei)
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
    ) throws -> [CLLocationCoordinate2D] {
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
                let poly = try geom.polyline(edgeIndex: ei)
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
        let poly = try geom.polyline(edgeIndex: ei, forward: forward)
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

    /// Range queries repeat the same station matches. Reuse only the matching
    /// result; reachability distances still come from this request's search.
    private static let rangeSnapCache = RangeSnapCache()
    private nonisolated final class RangeSnapCache: @unchecked Sendable {
        private struct Key: Hashable {
            let latitude: Double
            let longitude: Double
            let profile: String
            let allowUnknown: Bool
        }
        private let lock = NSLock()
        private final class Entry {
            weak var owner: GraphV2Pack?
            weak var geometry: GeometryV1Pack?
            weak var index: ExactSnapIndex?
            var values: [Key: [EdgeSnap]] = [:]
            init(_ pack: GraphV2Pack) { owner = pack; geometry = pack.geometry; index = pack.exactSnapIndex }
        }
        private var entries: [Entry] = []

        private func key(pack: GraphV2Pack, point: CLLocationCoordinate2D,
                         profile: RouteProfile, allowUnknown: Bool) -> Key {
            let legalV4 = pack.version >= 4 && pack.legalTopology
            return Key(latitude: point.latitude, longitude: point.longitude,
                profile: legalV4 ? "legal-v4" : profile.rawValue,
                allowUnknown: allowUnknown && profile != .cleanest)
        }

        func cached(pack: GraphV2Pack, point: CLLocationCoordinate2D,
                    profile: RouteProfile, allowUnknown: Bool) throws -> [EdgeSnap]? {
            try RoutingWorkContext.check()
            let key = key(pack: pack, point: point, profile: profile, allowUnknown: allowUnknown)
            lock.lock()
            let result = entries.first(where: {
                $0.owner === pack && $0.geometry === pack.geometry && $0.index === pack.exactSnapIndex
            })?.values[key]
            lock.unlock()
            guard let result else {
                RoutingWorkContext.measurement?.increment(.rangeSnapCacheMisses)
                return nil
            }
            // Cached coordinates must not hide changed or unavailable backing files.
            if let index = pack.exactSnapIndex {
                try index.withBoundsQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { _ in
                    try pack.geometry?.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
                }
            } else {
                try pack.geometry?.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
            }
            try RoutingWorkContext.check()
            RoutingWorkContext.measurement?.increment(.rangeSnapCacheHits)
            return result
        }

        func snaps(pack: GraphV2Pack, point: CLLocationCoordinate2D,
                   profile: RouteProfile, allowUnknown: Bool,
                   make: () throws -> [EdgeSnap]) throws -> [EdgeSnap] {
            if let result = try cached(pack: pack, point: point, profile: profile, allowUnknown: allowUnknown) {
                return result
            }
            let key = key(pack: pack, point: point, profile: profile, allowUnknown: allowUnknown)
            let result = try make()
            lock.lock()
            entries.removeAll { $0.owner == nil || ($0.owner === pack && ($0.geometry !== pack.geometry || $0.index !== pack.exactSnapIndex)) }
            let entry: Entry
            if let existing = entries.first(where: { $0.owner === pack }) {
                entry = existing
            } else {
                if entries.count >= 2 { entries.removeFirst() }
                entry = Entry(pack)
                entries.append(entry)
            }
            // Same aggregate match bound as before, shared across two packs.
            // A border query must not evict every match when switching sides.
            if entry.values.count >= 4096 { entry.values.removeAll(keepingCapacity: true) }
            entry.values[key] = result
            lock.unlock()
            return result
        }
    }

    /// Snap a seam seed onto pack fabric (cross-pack hops). Wider than pin snap.
    static let seamSnapMeters: Double = 12_000

    func nearestRoadCoordinate(
        to point: CLLocationCoordinate2D,
        allowUnknown: Bool,
        profile: RouteProfile,
        maxMeters: Double = OnDeviceRouter.seamSnapMeters,
        osmCoreOnly: Bool = false
    ) throws -> CLLocationCoordinate2D? {
        try nearestEdgeSnaps(
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
    ) throws -> EdgeSnap? {
        try nearestEdgeSnaps(to: point, allowUnknown: allowUnknown, profile: profile).first
    }

    /// Closest eligible pack edges within `maxMeters`, nearest first (capped).
    /// Returns extra candidates so adventure re-sort + paved diversification still
    /// have yellow/white connectors available in dense track meshes.
    private func recordedNodeSnaps(node: Int, point: CLLocationCoordinate2D,
                                   profile: RouteProfile, allowUnknown: Bool) throws -> [EdgeSnap] {
        guard node >= 0, node < pack.nodeCount else { return [] }
        let coordinate = coordinate(forNode: node)
        // The accepted seam contract permits at most a two-metre join.
        guard meters(point, coordinate) <= 2 else { return [] }
        return try nearestEdgeSnaps(to: coordinate, allowUnknown: allowUnknown,
            profile: profile, maxMeters: 2).filter {
                $0.nodeA == node || $0.nodeB == node
            }.map { candidate in
                var snap = candidate
                snap.projected = coordinate
                snap.distanceMeters = meters(point, coordinate)
                let atStart = snap.nodeA == node
                snap.distanceAlongM = atStart ? 0 : Double(pack.edgeMeters[snap.edgeIndex])
                snap.segmentIndex = atStart ? 0 : max(0, (try edgeGeometry(snap.edgeIndex)?.count ?? 2) - 2)
                return snap
            }
    }

    private func nearestEdgeSnaps(
        to point: CLLocationCoordinate2D,
        allowUnknown: Bool,
        profile: RouteProfile,
        maxMeters: Double = OnDeviceRouter.maxSnapMeters,
        osmCoreOnly: Bool = false,
        headingDeg: Double? = nil,
        intentBearingDeg: Double? = nil
    ) throws -> [EdgeSnap] {
        var rejections: [String] = []
        return try nearestEdgeSnaps(
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
        rejections: inout [String],
        collectAllGeometricMatches: Bool = false
    ) throws -> [EdgeSnap] {
        let measurement = RoutingWorkContext.measurement
        let measuredPhase = measurement?.begin(.matching)
        var projectionSegments: UInt64 = 0, projectionCandidates: UInt64 = 0, constructedRoadSnaps: UInt64 = 0
        defer {
            measurement?.end(measuredPhase)
            measurement?.increment(.matchingGeometrySegments,by: projectionSegments)
            measurement?.increment(.matchingProjectionCandidates,by: projectionCandidates)
            measurement?.increment(.matchingRoadSnapsConstructed,by: constructedRoadSnaps)
        }
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
        let diskIndex: ExactSnapIndex?
        let legacyGrid: PackEdgeSpatialIndex?
        if pack.version >= 4, pack.legalTopology {
            guard let prepared = pack.exactSnapIndex else { throw ExactSnapIndex.Failure.invalidFormat }
            diskIndex = prepared; legacyGrid = nil
        } else {
            diskIndex = nil; legacyGrid = try PackEdgeSpatialIndex.shared.grid(for: pack)
        }
        func visitCandidates(_ radius: Int, _ query: ExactSnapIndex.BoundsQuery?, _ visit: (Int) throws -> Void) throws {
            if let diskIndex {
                try diskIndex.forEachEdge(nearLat: lat, lon: lon, radiusCells: radius,
                    query: query, cancelled: { RoutingWorkContext.stopReason != nil }, visit)
            } else if let legacyGrid {
                for edge in legacyGrid.edgeIndices(nearLat: lat, lon: lon, radiusCells: radius) { try visit(edge) }
            }
        }
        // ~1.1 km / cell at mid-latitudes. Scan the full requested radius:
        // stopping after the nearest hit misses through-roads across cell borders.
        let cellKm = PackEdgeSpatialIndex.cellDegrees * 111.0
        let maxRadius = max(2, Int(ceil(maxMeters / 1000.0 / cellKm)) + 2)

        func scanCandidates(_ boundsQuery: ExactSnapIndex.BoundsQuery?) throws {
        if usePackGeometryEnvelope, let boundsQuery,
           try !boundsQuery.mayContainMatch(latitude: lat, longitude: lon, meters: maxMeters) {
            RoutingWorkContext.measurement?.increment(.snapEnvelopeRejectedQueries)
            return
        }
        var checked = Set<Int>()
        for radius in 0...maxRadius {
            try visitCandidates(radius, boundsQuery) { ei in
                if checked.contains(ei) { return }
                checked.insert(ei)
                if let boundsQuery {
                    guard try boundsQuery.mayIntersect(edge: ei, latitude: lat, longitude: lon, meters: maxMeters) else { return }
                } else if let legacyGrid {
                    guard legacyGrid.mayIntersect(edge: ei, latitude: lat, longitude: lon, meters: maxMeters) else { return }
                }
                if pack.version < 4 || !pack.legalTopology {
                    let access = GraphV2Pack.unpackAccess(pack.edgeAttrs[ei])
                    guard accessAllowed(access, allowUnknown: policyUnknown, profile: profile) else { return }
                }
                if osmCoreOnly, !GraphV2Pack.isOsmCoreEdge(pack.edgeId(ei)) { return }
                let a = Int(fromArr[ei])
                let b = Int(toArr[ei])
                guard a >= 0, b >= 0, a < pack.nodeCount, b < pack.nodeCount else { return }
                let aLon = Double(pack.nodeCoords[a * 2])
                let aLat = Double(pack.nodeCoords[a * 2 + 1])
                let bLon = Double(pack.nodeCoords[b * 2])
                let bLat = Double(pack.nodeCoords[b * 2 + 1])

                let poly: [CLLocationCoordinate2D]
                if let g = geom {
                    let p = try g.polyline(edgeIndex: ei)
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
                var closest = ExactRoadProjectionChoice()
                for i in 1..<poly.count {
                    projectionSegments &+= 1
                    let segA = poly[i - 1]
                    let segB = poly[i]
                    let segM = meters(segA, segB)
                    let proj = projectOntoSegment(point: point, a: segA, b: segB)
                    let d = meters(point, proj.coord)
                    if d <= maxMeters { projectionCandidates &+= 1 }
                    closest.consider(distance: d,maximum: maxMeters,along: along + segM * proj.t,
                        segment: i-1,projected: proj.coord)
                    along += segM
                }
                if let selected = closest.value {
                    constructedRoadSnaps &+= 1
                    bestByEdge[ei] = EdgeSnap(edgeIndex: ei,nodeA: a,nodeB: b,
                        distanceMeters: selected.distance,projected: selected.projected,
                        distanceAlongM: selected.along,segmentIndex: selected.segment,
                        tangentDeg: bearingDeg(from: poly[selected.segment],to: poly[selected.segment+1]))
                }
            }
        }
        }
        if let diskIndex {
            try diskIndex.withBoundsQuery(reusing: roadBoundsQuery,
                cancelled: { RoutingWorkContext.stopReason != nil }) {
                try scanCandidates($0)
            }
        } else { try scanCandidates(nil) }

        let ranked = bestByEdge.values.sorted { $0.distanceMeters < $1.distanceMeters }
        if collectAllGeometricMatches { return ranked }
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
            if ei & 4095 == 0 { RoutingWorkContext.measurement?.sampleIfDue() }
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

    /// Report the same directed legal decision used by V4 search. Coarse access
    /// attributes describe legacy classification and can disagree with this code.
    private func accessNameForTraversal(_ ei: Int, from: Int, to: Int) -> String {
        guard pack.version >= 4, pack.legalTopology else { return accessNameForEdge(ei) }
        return v4AccessClassName(Int(pack.v4AccessCode(ei: ei, from: from, to: to)))
    }

    private func continuationStartState(edge: Int, targetNode: Int, movement: Double,
                                        turns: GraphV2Pack.V4TurnStateSpace) -> Int {
        guard let imported = importedArrival else { return -1 }
        switch imported.location {
        case .node:
            if movement == 0, targetNode == imported.toNode { return imported.stateAtParentEnd }
            let a = Int(pack.edgeFrom?[edge] ?? -1), b = Int(pack.edgeTo?[edge] ?? -1)
            let sourceNode = targetNode == a ? b : a
            guard sourceNode == imported.toNode else { return -1 }
            return turns.transition(state: imported.stateAtParentEnd, outgoingEdge: edge, toNode: targetNode)
        case .edge:
            // There is no mapped turn junction in the middle of this parent.
            // Continue its directed remainder; do not restart its automaton.
            guard edge == imported.incomingEdge else { return -1 }
            if targetNode == imported.toNode { return imported.stateAtParentEnd }
            // Reversing on the same two-way road creates no new connection.
            // Only admit the case with no restriction context to discard;
            // active via-way or adjacent turn context remains explicit unknown.
            guard targetNode == imported.fromNode,
                  incomingContinuation?.restrictionContext.isEmpty == true,
                  incomingContinuation?.activeRestrictions.isEmpty == true,
                  pack.hasDirectedArc(from: imported.toNode, to: imported.fromNode, edge: edge)
            else { return -1 }
            return turns.stateForArrival(node: imported.fromNode, incomingEdge: edge)
        }
    }

    private func virtualTraversalNodes(_ edge: VirtEdge, forward: Bool,
                                       startSnap: EdgeSnap, endSnap: EdgeSnap) -> (from: Int, to: Int) {
        let from = forward ? edge.a : edge.b, to = forward ? edge.b : edge.a
        let a = Int(pack.edgeFrom?[edge.ei] ?? -1), b = Int(pack.edgeTo?[edge.ei] ?? -1)
        if from < pack.nodeCount { return (from, from == a ? b : a) }
        if to < pack.nodeCount { return (to == a ? b : a, to) }
        let storedForward = startSnap.distanceAlongM <= endSnap.distanceAlongM
        let alongForward = forward ? storedForward : !storedForward
        return (alongForward ? a : b, alongForward ? b : a)
    }

    private func continuationParentSnap(edge: Int, fromNode: Int, fraction: Double,
                                        point: CLLocationCoordinate2D) throws -> EdgeSnap? {
        guard let from = pack.edgeFrom, let to = pack.edgeTo, from.indices.contains(edge),
              pack.osmNodeIds.indices.contains(Int(from[edge])),
              pack.osmNodeIds.indices.contains(Int(to[edge])) else { return nil }
        let poly = try edgeGeometry(edge) ?? [coordinate(forNode: Int(from[edge])), coordinate(forNode: Int(to[edge]))]
        guard poly.count >= 2 else { return nil }
        let a = Int(from[edge]), b = Int(to[edge])
        let total = lineMeters(poly)
        guard total > 0, fraction.isFinite, (0...1).contains(fraction) else { return nil }
        let along = total * (fromNode == a ? fraction : 1 - fraction)
        var walked = 0.0
        for index in 1..<poly.count {
            let segment = meters(poly[index - 1], poly[index])
            if walked + segment >= along || index == poly.count - 1 {
                let t = segment > 0 ? max(0, min(1, (along - walked) / segment)) : 0
                let projected = CLLocationCoordinate2D(
                    latitude: poly[index - 1].latitude + t * (poly[index].latitude - poly[index - 1].latitude),
                    longitude: poly[index - 1].longitude + t * (poly[index].longitude - poly[index - 1].longitude))
                return EdgeSnap(edgeIndex: edge, nodeA: a, nodeB: b,
                    distanceMeters: meters(point, projected), projected: projected,
                    distanceAlongM: along, segmentIndex: index - 1,
                    tangentDeg: bearingDeg(from: poly[index - 1], to: poly[index]))
            }
            walked += segment
        }
        return nil
    }

    private func terminalContinuation(for result: Result,
                                      turns: GraphV2Pack.V4TurnStateSpace) throws -> NativeRoutingContinuation {
        var state = importedArrival?.stateAtParentEnd
        var previousEdge = importedArrival?.incomingEdge
        var previousFrom = importedArrival?.fromNode
        var previousTo = importedArrival?.toNode
        var first = true
        var lastLeg: Leg?
        for leg in result.legs {
            if leg.edgeId.hasPrefix("soft-stitch") { continue }
            guard let edge = leg.edgeIndex, let from = leg.fromNode, let to = leg.toNode,
                  pack.hasDirectedArc(from: from, to: to, edge: edge) else {
                throw NativeRoutingContinuationError.unavailableLegalState
            }
            if first, let imported = importedArrival, case .edge = imported.location {
                guard edge == imported.incomingEdge,
                      (from == imported.fromNode && to == imported.toNode)
                        || (from == imported.toNode && to == imported.fromNode) else {
                    throw NativeRoutingContinuationError.illegalDirection
                }
                let resumed = continuationStartState(edge: edge, targetNode: to,
                    movement: leg.distanceMeters, turns: turns)
                guard resumed >= 0 else { throw NativeRoutingContinuationError.illegalDirection }
                state = resumed
                // Same direction resumes the already-entered parent. A proven
                // unrestricted reversal carries its new directed arrival.
            } else if let priorState = state {
                if !first && edge == previousEdge && from == previousFrom && to == previousTo {
                    // Consecutive geometry fragments of the same directed parent.
                } else {
                    guard from == previousTo else { throw NativeRoutingContinuationError.unavailableLegalState }
                    state = turns.transition(state: priorState, outgoingEdge: edge, toNode: to)
                }
            } else {
                state = turns.stateForArrival(node: to, incomingEdge: edge)
            }
            guard let current = state, current >= 0 else { throw NativeRoutingContinuationError.unavailableLegalState }
            previousEdge = edge; previousFrom = from; previousTo = to
            first = false
            lastLeg = leg
        }
        guard let last = lastLeg, let edge = last.edgeIndex, let from = last.fromNode,
              let to = last.toNode, let state, let endpoint = last.coordinates.last else {
            if let incomingContinuation { return incomingContinuation }
            throw NativeRoutingContinuationError.unavailableLegalState
        }
        let location: NativeRoutingContinuation.Location
        if let recordedEndNode {
            guard recordedEndNode == to else { throw NativeRoutingContinuationError.invalidLocation }
            location = .node(pack.osmNodeIds[to])
        } else {
            let poly = try edgeGeometry(edge) ?? [coordinate(forNode: from), coordinate(forNode: to)]
            guard poly.count >= 2 else { throw NativeRoutingContinuationError.unavailableRoad }
            var walked = 0.0, nearest = Double.infinity, bestAlong = 0.0
            for index in 1..<poly.count {
                let length = meters(poly[index - 1], poly[index])
                let projection = projectOntoSegment(point: endpoint, a: poly[index - 1], b: poly[index])
                let distance = meters(endpoint, projection.coord)
                if distance < nearest { nearest = distance; bestAlong = walked + projection.t * length }
                walked += length
            }
            guard walked > 0 else { throw NativeRoutingContinuationError.invalidLocation }
            let fraction = max(0, min(1, from == Int(pack.edgeFrom?[edge] ?? -1)
                ? bestAlong / walked : 1 - bestAlong / walked))
            location = fraction == 1 ? .node(pack.osmNodeIds[to]) : .edge(fraction: fraction)
        }
        return try turns.exportContinuation(state: state, incomingEdge: edge, arrivedFromNode: from,
            pack: pack, location: location)
    }

    private func accessNameForVirtualTraversal(
        _ edge: VirtEdge, forward: Bool, startSnap: EdgeSnap, endSnap: EdgeSnap
    ) -> String {
        if edge.junctionStitch { return "motorized_permissive" }
        guard pack.version >= 4, pack.legalTopology else { return accessNameForEdge(edge.ei) }
        let from = forward ? edge.a : edge.b
        let to = forward ? edge.b : edge.a
        let edgeA = Int(pack.edgeFrom?[edge.ei] ?? -1)
        let edgeB = Int(pack.edgeTo?[edge.ei] ?? -1)
        // A virtual endpoint retains its parent road's orientation. Do not infer
        // direction from nearby coordinates (which may belong to another layer).
        if from < pack.nodeCount {
            return accessNameForTraversal(edge.ei, from: from, to: from == edgeA ? edgeB : edgeA)
        }
        if to < pack.nodeCount {
            return accessNameForTraversal(edge.ei, from: to == edgeA ? edgeB : edgeA, to: to)
        }
        let storedForward = startSnap.distanceAlongM <= endSnap.distanceAlongM
        let alongForward = forward ? storedForward : !storedForward
        return accessNameForTraversal(edge.ei, from: alongForward ? edgeA : edgeB,
            to: alongForward ? edgeB : edgeA)
    }

    private func accessNameForEdge(_ ei: Int) -> String {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return "motorized_unknown" }
        let name = accessName(GraphV2Pack.unpackAccess(pack.edgeAttrs[ei]))
        return name.isEmpty ? "motorized_unknown" : name
    }

    private func snapIsMajorHighwayPin(_ snap: EdgeSnap, profile: RouteProfile) throws -> Bool {
        guard snap.distanceMeters < OnDeviceProfileCosts.majorHighwayPinMeters else { return false }
        if profile == .cleanest, pack.hasLeaves {
            let tier = (try pack.roadTier(snap.edgeIndex,query: edgeDetailQuery))
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

    private func structureLeafForEdge(_ ei: Int) throws -> String? {
        guard ei >= 0, ei < pack.undirectedEdgeCount, pack.hasLeaves else { return nil }
        if let leaf = (try pack.structureLeaf(ei,query: edgeDetailQuery)), leaf != "n/a", !leaf.isEmpty {
            return leaf
        }
        return nil
    }

    private func layerForEdge(_ ei: Int) throws -> Int {
        guard ei >= 0, ei < pack.undirectedEdgeCount, pack.hasLeaves else { return 0 }
        return (try pack.layer(ei,query: edgeDetailQuery))
    }

    private func crossingLabelForEdge(_ ei: Int) throws -> String? {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return nil }
        let code = GraphV2Pack.unpackStructure(pack.edgeAttrs[ei])
        return OnDeviceProfileCosts.structureCrossingLabel(
            structureCode: code,
            structureLeaf: (try structureLeafForEdge(ei)),
            layer: (try layerForEdge(ei))
        )
    }

    private func waterCrossingForEdge(_ ei: Int) throws -> Bool {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return false }
        return OnDeviceProfileCosts.isWaterCrossing(
            structureCode: GraphV2Pack.unpackStructure(pack.edgeAttrs[ei]),
            structureLeaf: (try structureLeafForEdge(ei))
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
    private func edgeBlockedForCleanPavement(_ ei: Int) throws -> Bool {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return true }
        if pack.hasLeaves {
            return RoadTierStats.isBlockedForCleanLeaf(
                family: (try pack.surfaceFamily(ei,query: edgeDetailQuery)),
                tier: (try pack.roadTier(ei,query: edgeDetailQuery)),
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
    ) throws -> Bool {
        if ei == startEi || ei == endEi || ctx.customerStartEdges.contains(ei) || ctx.customerEndEdges.contains(ei) { return false }
        if pack.hasLeaves, ctx.profile == .cleanest {
            return RoadTierStats.isBlockedForCleanLeaf(
                family: (try pack.surfaceFamily(ei,query: edgeDetailQuery)),
                tier: (try pack.roadTier(ei,query: edgeDetailQuery)),
                pavedOnly: ctx.pavedOnly,
                isEndpointEdge: false
            )
        }
        guard ctx.pavedOnly else { return false }
        return (try edgeBlockedForCleanPavement(ei))
    }

    /// Pack duplicate nodes within `cleanCoincidentNodeMeters` share a place.
    private func coincidentSiblingLists() -> [[Int]?] {
        if pack.version >= 4 {
            // V4 connects only verified source nodes, never coordinate siblings.
            // Call sites skip legacy stitching, so no node-sized nil table is needed.
            return []
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
        edgeIndex: Int? = nil,
        edgeShape: [CLLocationCoordinate2D]? = nil,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        ctx: HopSearchContext
    ) throws -> Bool {
        if useSharedRoadLegality {
            let exactBounds: ((Int,UrbanCore.Box) throws -> Bool)? = pack.exactSnapIndex.map { index in
                { edge,box in
                    let radius = 110_000 * max((box.maxLat-box.minLat)/2,(box.maxLon-box.minLon)/2)
                    return try index.mayIntersect(edge: edge,
                        latitude: (box.minLat+box.maxLat)/2,longitude: (box.minLon+box.maxLon)/2,
                        meters: radius,query: roadBoundsQuery,cancelled: { RoutingWorkContext.stopReason != nil })
                }
            }
            return try NativeRoadBlockPolicy.blocked(point,edgeFrom: edgeFrom,edgeIndex: edgeIndex,
                edgeShape: edgeShape,from: from,to: to,ctx: ctx,sourceIdentity: pack,
                hasGeometry: pack.geometry != nil,urbanCores: { packUrbanCores },settlements: { packSettlements },
                boundsMayIntersect: exactBounds,geometryForEdge: { try edgeGeometry($0) })
        }
        if ctx.cityWall, !packUrbanCores.isEmpty {
            let memo = ctx.urbanEdgeMemo.flatMap {
                $0.matches(owner: pack,from: from,to: to) ? $0 : nil
            }
            let boxes = memo?.boxes ?? packUrbanCores.filter { !$0.contains(from) && !$0.contains(to) }
            if !boxes.isEmpty {
                var fullGeometryProof = true
                func urbanBlocked() throws -> Bool {
                var couldCross = true
                if let edgeIndex, let index = pack.exactSnapIndex {
                    couldCross = try boxes.contains { box in
                        // This padded rectangle encloses the complete urban
                        // box at every latitude. Exact source edge bounds only
                        // skip geometry that cannot touch it.
                        let radius = 110_000 * max((box.maxLat - box.minLat) / 2, (box.maxLon - box.minLon) / 2)
                        return try index.mayIntersect(edge: edgeIndex,
                            latitude: (box.minLat + box.maxLat) / 2,
                            longitude: (box.minLon + box.maxLon) / 2, meters: radius,
                            query: roadBoundsQuery, cancelled: { RoutingWorkContext.stopReason != nil })
                    }
                }
                if couldCross {
                    let geometry: [CLLocationCoordinate2D]
                    if let edgeShape { geometry = edgeShape }
                    else if let edgeIndex, let stored = try edgeGeometry(edgeIndex) { geometry = stored }
                    else { fullGeometryProof = false; geometry = edgeFrom.map { [$0, point] } ?? [point] }
                    if geometry.count == 1, UrbanCore.blocks(point: geometry[0], start: from, end: to, boxes: boxes) { return true }
                    for i in geometry.indices.dropFirst() {
                        if UrbanCore.blocks(segmentFrom: geometry[i - 1], segmentTo: geometry[i],
                            start: from, end: to, boxes: boxes) { return true }
                    }
                }
                return false
                }
                // Only native full-edge reads participate. Virtual/partial
                // shapes and missing geometry retain their original checks.
                let blocked: Bool
                if let memo,let edgeIndex,edgeShape == nil,pack.geometry != nil {
                    blocked = try memo.value(edge: edgeIndex,shouldStore: { fullGeometryProof },compute: urbanBlocked)
                } else { blocked = try urbanBlocked() }
                if blocked { return true }
            }
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

    private func preferenceStep(_ base: Double, meters: Double, edge: Int) throws -> Double {
        guard let preferences = activeRidePreferences else { return base }
        let roadClass = edge >= 0 ? ((try pack.roadClassLeaf(edge,query: edgeDetailQuery)) ?? roadClassNameForEdge(edge)) : "unknown"
        return NativeRidePreferenceCosts.edgeCost(base: base, meters: meters,
            roadClass: roadClass, preferences: preferences)
    }

    private func preferenceRouteCost(_ route: Result, preferences: RidePreferences) throws -> Double {
        try route.legs.reduce(0) { sum, leg in
            let base: Double
            if leg.structureType == "ferry", let edge = leg.edgeIndex {
                base = (try fractionalFerryCost(edge: edge, meters: leg.distanceMeters))
            } else {
                let surface = leg.surfaceName
                let knownDirt = leg.edgeIndex.map { edgeIsDirt($0) } ?? false
                let factor = !knownDirt ? HopSearchPolicy.dirtRidePavedPerKm
                    : (surface == "gravel" ? HopSearchPolicy.dirtRideGravelPerKm
                    : (["access", "resource", "track"].contains(surface) ? HopSearchPolicy.dirtRideResourcePerKm
                    : HopSearchPolicy.dirtRideUnknownTrackPerKm))
                base = leg.distanceMeters / 1_000 * factor
            }
            return sum + NativeRidePreferenceCosts.edgeCost(base: base, meters: leg.distanceMeters,
                roadClass: try leg.edgeIndex.flatMap { (try pack.roadClassLeaf($0,query: edgeDetailQuery)) } ?? leg.roadClassName,
                preferences: preferences)
        }
    }

    private func backtrackPenalized(
        _ cost: Double,
        edgeID: String,
        ctx: HopSearchContext
    ) -> Double {
        guard !edgeID.isEmpty else { return cost }
        if edgeID == ctx.arrivalEdgeId { return cost * 12 }
        if ctx.priorEdgeIds.contains(edgeID) {
            return cost * max(activeRidePreferences?.preferDifferentRoads == true ? 16 : 1, ctx.backtrackFactor)
        }
        return cost
    }

    private func fractionalFerryCost(edge: Int, meters: Double) throws -> Double {
        OnDeviceProfileCosts.fractionalFerryRelaxStepCost(
            traversedMeters: meters, parentMeters: Double(pack.edgeMeters[edge]),
            storedSeconds: (try pack.crossingSeconds(edge,query: edgeDetailQuery)))
    }

    /// Full-real-road pricing shared with a future connected-pack consumer.
    /// Legality, turns, virtual stubs, length feasibility and label relaxation
    /// stay in the caller. Lazy predecessor tier resolution preserves the exact
    /// throwing-read order and can resolve a predecessor owned by another pack.
    func fullRealRoadStep(meters edgeM: Double, edgeIndex ei: Int, attributes attr: UInt16,
        edgeID eid: String, surface: Int, roadClass: Int, access: Int, confidence: Int,
        profile: RouteProfile, ctx: HopSearchContext, toLL: CLLocationCoordinate2D,
        edgeFrom: CLLocationCoordinate2D, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
        endLL: CLLocationCoordinate2D, projectedOrigin: CLLocationCoordinate2D, abMeters: Double,
        startOnMajorHighway: Bool, endOnMajorHighway: Bool, policyUnknown: Bool,
        awayExtraMeters: Double?, applySoftCorridor: Bool,
        predecessorTier: () throws -> RoadTier?) throws -> Double {
        if useSharedFullRoadPolicy {
            return try NativeFullRoadPolicy.step(baseCost: {
                try hopCostStep(
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
            projectedOrigin: projectedOrigin,
            startOnMajorHighway: startOnMajorHighway,
            endOnMajorHighway: endOnMajorHighway,
            policyUnknown: policyUnknown
                )
            }, meters: edgeM, attributes: attr, profile: profile, ctx: ctx,
                toLL: toLL, edgeFrom: edgeFrom, from: from, to: to, endLL: endLL,
                projectedOrigin: projectedOrigin, startOnMajorHighway: startOnMajorHighway,
                endOnMajorHighway: endOnMajorHighway, awayExtraMeters: awayExtraMeters,
                applySoftCorridor: applySoftCorridor, hasLeaves: pack.hasLeaves,
                initialFuelApproach: initialFuelApproach, urbanCores: { packUrbanCores },
                settlementBoxes: { settlementBoxes(for: profile) },
                backtrack: { backtrackPenalized($0,edgeID: eid,ctx: ctx) },
                currentTier: { try pack.roadTier(ei,query: edgeDetailQuery) },
                predecessorTier: predecessorTier)
        }
        var step = (try hopCostStep(
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
            projectedOrigin: projectedOrigin,
            startOnMajorHighway: startOnMajorHighway,
            endOnMajorHighway: endOnMajorHighway,
            policyUnknown: policyUnknown
        ))
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
        if let away = awayExtraMeters {
            step += ctx.costMode == .pavement ? away * 10 : away
            if applySoftCorridor {
                step += OnDeviceProfileCosts.corridorCrossTrackExtra(
                    profile: profile,
                    point: toLL,
                    lineFrom: projectedOrigin,
                    lineTo: endLL,
                    edgeMeters: edgeM
                )
            }
        }
        step = backtrackPenalized(step, edgeID: eid, ctx: ctx)
        let isFerry = GraphV2Pack.isFerryStructure(GraphV2Pack.unpackStructure(attr))
        if !isFerry, profile == .cleanest, pack.hasLeaves, ctx.avoidMotorways,
           let resolvedPredecessorTier = try predecessorTier() {
            step += RoadTierStats.e4MajorHighwayEntryCost(
                fromTier: resolvedPredecessorTier,
                toTier: (try pack.roadTier(ei,query: edgeDetailQuery)),
                enabled: true,
                metersFromStart: meters(toLL, projectedOrigin),
                metersToDestination: meters(toLL, endLL),
                startOnHighway: startOnMajorHighway,
                endOnHighway: endOnMajorHighway
            )
        }
        // Initial refill ranks physical routed metres. Override all
        // recreational penalties, including ferry-time pricing.
        if initialFuelApproach { step = edgeM / 1_000 }
        return step
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
        projectedOrigin: CLLocationCoordinate2D,
        startOnMajorHighway: Bool,
        endOnMajorHighway: Bool,
        policyUnknown: Bool
    ) throws -> Double {
        if useSharedCleanPolicyReads, profile == .cleanest, ctx.costMode == .profile,
           pack.hasLeaves, ei >= 0 {
            return try NativeCleanProfileStep.cost(read: ArrayCleanPolicyReadAccess(pack: pack,query: edgeDetailQuery),
                edge: ei,attributes: pack.edgeAttrs[ei],meters: edgeMeters,ctx: ctx,
                toLL: toLL,endLL: endLL,projectedOrigin: projectedOrigin,
                startOnMajorHighway: startOnMajorHighway,endOnMajorHighway: endOnMajorHighway,
                activePreferences: activeRidePreferences)
        }
        if ei >= 0, GraphV2Pack.isFerryStructure(GraphV2Pack.unpackStructure(pack.edgeAttrs[ei])) {
            let sec = OnDeviceProfileCosts.ferryCrossingSeconds(
                distanceMeters: edgeMeters,
                storedSeconds: (try pack.crossingSeconds(ei,query: edgeDetailQuery))
            )
            return (try preferenceStep(OnDeviceProfileCosts.ferryRelaxStepCost(crossingSeconds: sec), meters: edgeMeters, edge: ei))
        }
        let km = edgeMeters / 1000.0
        switch ctx.costMode {
        case .distance, .balancedResource:
            return (try preferenceStep(km, meters: edgeMeters, edge: ei))
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
                metersFromStart: meters(toLL, projectedOrigin),
                metersToDestination: meters(toLL, endLL),
                startOnMajorHighway: startOnMajorHighway,
                endOnMajorHighway: endOnMajorHighway,
                avoidMajorHighways: !pack.hasLeaves && ctx.avoidMotorways
            )
            if profile == .cleanest, pack.hasLeaves, ei >= 0, ctx.avoidMotorways || ctx.preferBackRoads {
                step *= RoadTierStats.e4LeafCostMult(
                    tier: (try pack.roadTier(ei,query: edgeDetailQuery)),
                    avoidMotorways: ctx.avoidMotorways,
                    preferBackRoads: ctx.preferBackRoads,
                    metersFromStart: meters(toLL, projectedOrigin),
                    metersToDestination: meters(toLL, endLL),
                    startOnHighway: startOnMajorHighway,
                    endOnHighway: endOnMajorHighway
                )
            }
            return (try preferenceStep(step, meters: edgeMeters, edge: ei))
        case .profile:
            // Phase E2: Clean + leaves → road-tier × surface-family costs only.
            if profile == .cleanest, pack.hasLeaves, ei >= 0 {
                let tier = (try pack.roadTier(ei,query: edgeDetailQuery))
                let family = (try pack.surfaceFamily(ei,query: edgeDetailQuery))
                var step = km * RoadTierStats.cleanLeafCostMult(tier: tier, family: family)
                step *= RoadTierStats.e4LeafCostMult(
                    tier: tier,
                    avoidMotorways: ctx.avoidMotorways,
                    preferBackRoads: ctx.preferBackRoads,
                    metersFromStart: meters(toLL, projectedOrigin),
                    metersToDestination: meters(toLL, endLL),
                    startOnHighway: startOnMajorHighway,
                    endOnHighway: endOnMajorHighway
                )
                return (try preferenceStep(step, meters: edgeMeters, edge: ei))
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
                metersFromStart: meters(toLL, projectedOrigin),
                metersToDestination: meters(toLL, endLL),
                startOnMajorHighway: startOnMajorHighway,
                endOnMajorHighway: endOnMajorHighway,
                avoidMajorHighways: !pack.hasLeaves && ctx.avoidMotorways
            )
            if profile == .cleanest, pack.hasLeaves, ei >= 0, ctx.avoidMotorways || ctx.preferBackRoads {
                step *= RoadTierStats.e4LeafCostMult(
                    tier: (try pack.roadTier(ei,query: edgeDetailQuery)),
                    avoidMotorways: ctx.avoidMotorways,
                    preferBackRoads: ctx.preferBackRoads,
                    metersFromStart: meters(toLL, projectedOrigin),
                    metersToDestination: meters(toLL, endLL),
                    startOnHighway: startOnMajorHighway,
                    endOnHighway: endOnMajorHighway
                )
            }
            return (try preferenceStep(step, meters: edgeMeters, edge: ei))
        }
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
    var count: Int { items.count }
    private var items: [(node: Int, cost: Double)] = []
    private let measurement = RoutingWorkContext.measurement
    private var pendingPushes: UInt64 = 0
    private var pendingPops: UInt64 = 0
    private var pendingStates: UInt64 = 0
    private var pendingArcs: UInt64 = 0

    mutating func recordExpansion(arcs: Int) {
        guard measurement != nil else { return }
        pendingStates += 1
        pendingArcs += UInt64(max(0, arcs))
    }

    mutating func flushMeasurement() {
        guard let measurement else { return }
        measurement.increment(.queuePushes, by: pendingPushes)
        measurement.increment(.queuePops, by: pendingPops)
        measurement.increment(.examinedStates, by: pendingStates)
        measurement.increment(.examinedArcs, by: pendingArcs)
        pendingPushes = 0
        pendingPops = 0
        pendingStates = 0
        pendingArcs = 0
        measurement.sampleIfDue()
    }

    mutating func push(node: Int, cost: Double) {
        if measurement != nil { pendingPushes += 1 }
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
        if measurement != nil {
            pendingPops += 1
            if pendingPops >= 1_024 { flushMeasurement() }
        }
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

    private struct Bounds {
        let minLon: Double, maxLon: Double, minLat: Double, maxLat: Double
    }
    private let buckets: [Int64: [Int]]
    private let bounds: [Bounds?]

    init(pack: GraphV2Pack) throws {
        let measurement = RoutingWorkContext.measurement
        let measuredPhase = measurement?.begin(.indexing)
        defer { measurement?.end(measuredPhase) }
        var map: [Int64: [Int]] = [:]
        var boxes = [Bounds?](repeating: nil, count: pack.undirectedEdgeCount)
        guard let fromArr = pack.edgeFrom, let toArr = pack.edgeTo else {
            buckets = [:]
            bounds = boxes
            return
        }
        let cell = Self.cellDegrees
        for ei in 0..<pack.undirectedEdgeCount {
            if ei & 4095 == 0 { RoutingWorkContext.measurement?.sampleIfDue() }
            let a = Int(fromArr[ei])
            let b = Int(toArr[ei])
            guard a >= 0, b >= 0, a < pack.nodeCount, b < pack.nodeCount else { continue }
            let aLon = Double(pack.nodeCoords[a * 2])
            let aLat = Double(pack.nodeCoords[a * 2 + 1])
            let bLon = Double(pack.nodeCoords[b * 2])
            let bLat = Double(pack.nodeCoords[b * 2 + 1])
            // Full geometry bounds only reject edges whose geometry cannot
            // reach the requested radius. Existing grid membership and exact
            // projection/snap ordering remain unchanged.
            let polyline = try pack.geometry?.polyline(edgeIndex: ei) ?? []
            var minLon = min(aLon, bLon), maxLon = max(aLon, bLon)
            var minLat = min(aLat, bLat), maxLat = max(aLat, bLat)
            for point in polyline {
                minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
                minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            }
            boxes[ei] = Bounds(minLon: minLon, maxLon: maxLon, minLat: minLat, maxLat: maxLat)
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
        bounds = boxes
        if pack.geometry != nil {
            measurement?.increment(.geometryEdgesRead, by: UInt64(pack.undirectedEdgeCount))
        }
    }

    func mayIntersect(edge: Int, latitude: Double, longitude: Double, meters: Double) -> Bool {
        guard bounds.indices.contains(edge), let box = bounds[edge] else { return true }
        // Conservative WGS84 envelope; exact geodesic projection still decides.
        let latPad = max(0, meters) / 110_000
        if box.maxLat < latitude - latPad || box.minLat > latitude + latPad { return false }
        let polarLatitude = min(90, abs(latitude) + latPad)
        let lonPad = latPad / max(0.000001, cos(polarLatitude * .pi / 180))
        if lonPad >= 180 || abs(longitude) + lonPad >= 180 || box.maxLon - box.minLon >= 180 { return true }
        return box.maxLon >= longitude - lonPad && box.minLon <= longitude + lonPad
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
    private final class Entry {
        weak var pack: GraphV2Pack?
        let grid: PackEdgeSpatialIndex
        let geometry: GeometryV1Pack?
        init(pack: GraphV2Pack, grid: PackEdgeSpatialIndex) {
            self.pack = pack; self.grid = grid; self.geometry = pack.geometry
        }
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func grid(for pack: GraphV2Pack) throws -> PackEdgeSpatialIndex {
        lock.lock()
        if let existing = entries.first(where: { $0.pack === pack && $0.geometry === pack.geometry }) {
            lock.unlock()
            return existing.grid
        }
        lock.unlock()
        let built = try PackEdgeSpatialIndex(pack: pack)
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries.first(where: { $0.pack === pack && $0.geometry === pack.geometry }) { return existing.grid }
        entries.removeAll { $0.pack == nil || ($0.pack === pack && $0.geometry !== pack.geometry) }
        if entries.count >= 2 { entries.removeFirst() }
        entries.append(Entry(pack: pack, grid: built))
        return built
    }
}

// Unactivated exact-recorded-node Clean-pass bridge. Matching/customer scopes
// and fallback orchestration remain explicit unsupported prototype inputs.
extension OnDeviceRouter {
    func connectedCleanRoadAllowed(edge: Int, fromNode: Int, toNode: Int,
        originEdge: Int, destinationEdge: Int, origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D, avoidEdgeIDs: Set<String>, context: HopSearchContext) throws -> Bool {
        guard pack.version >= 4, pack.legalTopology, pack.hasLeaves else {
            throw ConnectedCleanStage.Failure.unsupported("V4 leaf policy required")
        }
        if !pack.v4AccessAllowed(ei: edge, from: fromNode, to: toNode,
            startEi: originEdge, endEi: destinationEdge, allowUnknown: false,
            startEndpointKind: nil, endEndpointKind: nil,
            customerStartEdges: context.customerStartEdges, customerEndEdges: context.customerEndEdges, useSharedPolicy: useSharedRoadLegality) { return false }
        if try edgeBlockedByPavedOnly(edge, ctx: context, allowSnapEdges: originEdge, endEi: destinationEdge) { return false }
        let edgeID = pack.edgeId(edge)
        if !edgeID.isEmpty, avoidEdgeIDs.contains(edgeID) { return false }
        return try !hopBlocked(coordinate(forNode: toNode), edgeFrom: coordinate(forNode: fromNode),
            edgeIndex: edge, from: origin, to: destination, ctx: context)
    }
    func connectedCleanRoadCost(edge: Int, fromNode: Int, toNode: Int,
        origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D,
        originOnHighway: Bool, destinationOnHighway: Bool,
        predecessorTier: () throws -> RoadTier?, context: HopSearchContext) throws -> Double {
        let attr = pack.edgeAttrs[edge], toLL = coordinate(forNode: toNode)
        let ab = meters(origin, destination)
        let applyAway = context.costMode == .profile || context.costMode == .pavement
        let away = applyAway ? OnDeviceProfileCosts.approachAwayExtra(profile: .cleanest,
            dFromMeters: meters(coordinate(forNode: fromNode),destination), dToMeters: meters(toLL,destination),
            abMeters: ab, regionId: pack.regionId) : nil
        return try fullRealRoadStep(meters: Double(pack.edgeMeters[edge]), edgeIndex: edge,
            attributes: attr, edgeID: pack.edgeId(edge), surface: GraphV2Pack.unpackSurface(attr),
            roadClass: GraphV2Pack.unpackRoadClass(attr), access: GraphV2Pack.unpackAccess(attr),
            confidence: GraphV2Pack.unpackConfidence(attr), profile: .cleanest, ctx: context,
            toLL: toLL, edgeFrom: coordinate(forNode: fromNode), from: origin, to: destination,
            endLL: destination, projectedOrigin: origin, abMeters: ab,
            startOnMajorHighway: originOnHighway, endOnMajorHighway: destinationOnHighway,
            policyUnknown: false, awayExtraMeters: away, applySoftCorridor: false,
            predecessorTier: predecessorTier)
    }
    func connectedRoadCoordinates(edge: Int, fromNode: Int) throws -> [CLLocationCoordinate2D] {
        guard let geometry = try edgeGeometry(edge), geometry.count >= 2 else {
            throw ConnectedCleanStage.Failure.incomplete("geometryUnavailable")
        }
        return Int(pack.edgeFrom?[edge] ?? -1) == fromNode ? geometry : Array(geometry.reversed())
    }
}
