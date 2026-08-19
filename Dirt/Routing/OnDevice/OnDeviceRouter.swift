import CoreLocation
import Foundation

/// On-device Dijkstra over a loaded `graph.v2` pack.
///
/// Costing mirrors pack-fabric `profile-costs` surface weights.
/// Snap is nearest **edge** (geometry polyline when available, else node chord).
/// Mid-edge snaps route via both endpoints through virtual nodes (find-path-v2),
/// same-edge taps return the along-edge span, and soft-stitch stubs paint
/// tap/GPS→road projection within `preferredMatchMeters` (camp / driveway approach).
/// Junction repairs mirror live `router.js`: permissive tip joins when Allow is OFF
/// (OSM+NSTDB near-misses), and unknown-island → through-giant stitches when Allow
/// is ON. Geographic loop pruning runs after reconstruction when legs have geometry.
/// Opted out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` so search can run on
/// `Task.detached` without freezing toast paint / map gestures.
nonisolated struct OnDeviceRouter {
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
        var dirtPercent: Int
        var pavedPercent: Int
        var unknownAccessPercent: Int
        var debugNote: String = ""
    }

    enum Failure: Error, Equatable, Sendable {
        case cannotSnapStart
        case cannotSnapEnd
        case identicalEnds
        case noPath
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
    /// Balanced ratio-seeking: scale paved km cost. Direct/Dirt/Clean stay 1.
    var pavedBias: Double = 1
    /// Planning-session seed for controlled variety. New process → new seed.
    var sessionSeed: UInt64 = 0

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
        sessionSeed: UInt64? = nil
    ) -> Result? {
        switch routeDetailed(
            from: from,
            to: to,
            profile: profile,
            allowUnknown: allowUnknown,
            avoidEdgeIds: avoidEdgeIds,
            sessionSeed: sessionSeed
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
        sessionSeed: UInt64? = nil
    ) -> Swift.Result<Result, Failure> {
        return routeDetailedOnce(
            from: from, to: to, profile: profile,
            allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds,
            sessionSeed: sessionSeed ?? self.sessionSeed
        )
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
        guard let snap = nearestEdgeSnap(to: from, allowUnknown: allowUnknown, profile: profile) else {
            return nil
        }
        let n = pack.nodeCount
        guard n > 0, snap.edgeIndex >= 0, snap.edgeIndex < pack.undirectedEdgeCount else { return nil }
        var dist = [Double](repeating: .infinity, count: n)
        var prevEdge = [Int](repeating: -1, count: n)
        var heap = MinHeap()
        let edgeM = Double(pack.edgeMeters[snap.edgeIndex])
        let mA = max(0, snap.distanceAlongM)
        let mB = max(0, edgeM - mA)
        if snap.nodeA >= 0, snap.nodeA < n, mA <= maxMeters {
            dist[snap.nodeA] = mA
            heap.push(node: snap.nodeA, cost: mA)
        }
        if snap.nodeB >= 0, snap.nodeB < n, mB <= maxMeters {
            dist[snap.nodeB] = mB
            heap.push(node: snap.nodeB, cost: mB)
        }
        let policyUnknown = allowUnknown && profile != .cleanest
        while let cur = heap.pop() {
            if cur.cost != dist[cur.node] { continue }
            if cur.cost > maxMeters { break }
            let arcStart = Int(pack.nodeOffsets[cur.node])
            let arcEnd = Int(pack.nodeOffsets[cur.node + 1])
            guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
            for i in arcStart..<arcEnd {
                let toNode = Int(pack.edgeTargets[i])
                let ei = Int(pack.edgeUndirectedIndex[i])
                guard ei >= 0, ei < pack.undirectedEdgeCount, toNode >= 0, toNode < n else { continue }
                if prevEdge[cur.node] == ei { continue }
                let attr = pack.edgeAttrs[ei]
                let access = GraphV2Pack.unpackAccess(attr)
                if !accessAllowed(access, allowUnknown: policyUnknown, profile: profile) { continue }
                let toLL = coordinate(forNode: toNode)
                if cityWall, UrbanCore.blocks(point: toLL, start: from, end: toward) {
                    continue
                }
                if HopSearchPolicy.outsideCorridor(
                    point: toLL, start: from, end: toward,
                    widthMeters: HopSearchPolicy.corridorMeters(for: profile)
                ) {
                    continue
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
        allowUnknown: Bool
    ) -> Double? {
        guard let snap = nearestEdgeSnap(to: point, allowUnknown: allowUnknown, profile: profile) else {
            return nil
        }
        var best = Double.infinity
        if snap.nodeA >= 0, snap.nodeA < dist.count { best = min(best, dist[snap.nodeA]) }
        if snap.nodeB >= 0, snap.nodeB < dist.count { best = min(best, dist[snap.nodeB]) }
        guard best.isFinite else { return nil }
        return best + snap.distanceMeters
    }

    func reachableGraphMeters(
        from: CLLocationCoordinate2D,
        toward: CLLocationCoordinate2D,
        pumps: [POIFeature],
        maxMeters: Double,
        profile: RouteProfile,
        allowUnknown: Bool
    ) -> [String: Double] {
        let wall = profile != .cleanest
        guard let dist = exploreNodeMeters(
            from: from, toward: toward, maxMeters: maxMeters, profile: profile,
            allowUnknown: allowUnknown, cityWall: wall
        ) else { return [:] }
        var out: [String: Double] = [:]
        for pump in pumps {
            let ll = CLLocationCoordinate2D(latitude: pump.latitude, longitude: pump.longitude)
            if let m = graphMeters(to: ll, dist: dist, profile: profile, allowUnknown: allowUnknown),
               m <= maxMeters {
                out[pump.id] = m
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
        let wall = profile != .cleanest
        guard let dist = exploreNodeMeters(
            from: from, toward: to, maxMeters: maxMeters, profile: profile,
            allowUnknown: allowUnknown, cityWall: wall
        ) else { return nil }
        return graphMeters(to: to, dist: dist, profile: profile, allowUnknown: allowUnknown)
    }

    private func routeDetailedOnce(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: Set<String>,
        sessionSeed: UInt64
    ) -> Swift.Result<Result, Failure> {
        // Snap only onto edges the profile can traverse.
        // Otherwise Banjo Mike–style camps lock onto NSTDB TRACK (motorized_unknown),
        // then Dijkstra with Allow off reports "no route on the eligible graph"
        // while the basemap still draws a continuous white road.
        let startRaw = nearestEdgeSnaps(
            to: from, allowUnknown: allowUnknown, profile: profile
        ).filter { $0.distanceMeters <= Self.preferredMatchMeters }
        let endRaw = nearestEdgeSnaps(
            to: to, allowUnknown: allowUnknown, profile: profile
        ).filter { $0.distanceMeters <= Self.preferredMatchMeters }
        guard !startRaw.isEmpty else { return .failure(.cannotSnapStart) }
        guard !endRaw.isEmpty else { return .failure(.cannotSnapEnd) }

        let tapSeparation = meters(from, to)
        if tapSeparation < Self.identicalEndsMeters {
            return .failure(.identicalEnds)
        }

        // Prefer through-roads (deg ≥ 2) at BOTH ends. House GPS and basemap-snapped
        // B often lock onto NSTDB / OSM dead-end tips that never join the fabric.
        // Adventure profiles: among through candidates, prefer track/resource over
        // freeway snaps so Dirt/Balanced actually enter the new OSM capillary.
        // Dense purple meshes can crowd yellow paved connectors out of the top of
        // that list — diversify keeps a paved through-road in the attempt set.
        let adventureStarts = diversifySnapCandidates(
            preferred: throughPreferredSnaps(startRaw, profile: profile, role: .start),
            distanceOrdered: startRaw
        )
        let adventureEnds = diversifySnapCandidates(
            preferred: throughPreferredSnaps(endRaw, profile: profile, role: .end),
            distanceOrdered: endRaw
        )

        var lastFailure: Failure = .noPath
        func attempt(
            starts: [EdgeSnap],
            ends: [EdgeSnap],
            ctx: HopSearchContext
        ) -> Swift.Result<Result, Failure>? {
            for (startSnap, endSnap) in snapAttemptPairs(starts: starts, ends: ends) {
                switch routeWithSnaps(
                    from: from,
                    to: to,
                    startSnap: startSnap,
                    endSnap: endSnap,
                    profile: profile,
                    allowUnknown: allowUnknown,
                    avoidEdgeIds: avoidEdgeIds,
                    ctx: ctx
                ) {
                case .success(let result):
                    return .success(result)
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
            if profile == .dirt || profile == .balanced {
                let bridgeStarts = diversifySnapCandidates(
                    preferred: throughPreferredSnaps(startRaw, profile: .direct, role: .start),
                    distanceOrdered: startRaw
                )
                let bridgeEnds = diversifySnapCandidates(
                    preferred: throughPreferredSnaps(endRaw, profile: .direct, role: .end),
                    distanceOrdered: endRaw
                )
                if let hit = attempt(starts: bridgeStarts, ends: bridgeEnds, ctx: ctx) {
                    return hit
                }
            }
            return .failure(lastFailure)
        }

        var ctx = HopSearchContext.forProfile(profile, seed: sessionSeed)

        // Direct: min pavement inside a 15 km A→B corridor — not a % stretch cap.
        if profile == .direct {
            ctx.costMode = .pavement
            ctx.variety = true
            return annotateCorridor(runProfile(ctx), from: from, to: to, profile: profile)
        }

        if profile == .balanced {
            var shortCtx = ctx
            shortCtx.costMode = .distance
            shortCtx.variety = false
            let shortest = runProfile(shortCtx)
            guard case .success(let short) = shortest else {
                return annotateCorridor(shortest, from: from, to: to, profile: profile)
            }
            var mixCtx = ctx
            mixCtx.costMode = .balancedResource
            mixCtx.shortestMeters = short.distanceMeters
            // Compute prune only — corridor (40 km) is the geographic safety ceiling.
            mixCtx.maxPathMeters = short.distanceMeters * HopSearchPolicy.balancedStretch
            mixCtx.variety = true
            switch runProfile(mixCtx) {
            case .success(var mix):
                mix.debugNote =
                    "balanced resource dirt%=\(mix.dirtPercent) stretch="
                    + String(format: "%.2f", short.distanceMeters > 0 ? mix.distanceMeters / short.distanceMeters : 1)
                return annotateCorridor(.success(mix), from: from, to: to, profile: profile)
            case .failure:
                return annotateCorridor(shortest, from: from, to: to, profile: profile)
            }
        }

        return annotateCorridor(runProfile(ctx), from: from, to: to, profile: profile)
    }

    private func annotateCorridor(
        _ result: Swift.Result<Result, Failure>,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile
    ) -> Swift.Result<Result, Failure> {
        guard case .success(var route) = result else { return result }
        let maxXT = HopSearchPolicy.maxCrossTrackMeters(
            coordinates: route.coordinates, start: from, end: to
        )
        let cap = HopSearchPolicy.corridorMeters(for: profile)
        let capTxt = cap.map { "\(Int($0 / 1000))km" } ?? "none"
        let note = "maxXT=\(Int(maxXT))m cap=\(capTxt)"
        route.debugNote = route.debugNote.isEmpty ? note : route.debugNote + " " + note
        return .success(route)
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

        if OnDeviceProfileCosts.isMajorHighway(roadName),
           snap.distanceMeters < OnDeviceProfileCosts.majorHighwayPinMeters {
            return snap.distanceMeters
        }

        switch (profile, role) {
        case (.cleanest, _):
            if surfaceName == "paved" { score -= 30 }
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
        case (.direct, .end):
            break // pure distance
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
        ctx: HopSearchContext
    ) -> Swift.Result<Result, Failure> {
        // Same snapped edge: paint the along-edge span (find-path-v2 vBetween).
        if startSnap.edgeIndex >= 0,
           startSnap.edgeIndex == endSnap.edgeIndex,
           abs(startSnap.distanceAlongM - endSnap.distanceAlongM) > 1 {
            if let same = sameEdgeResult(from: from, to: to, startSnap: startSnap, endSnap: endSnap) {
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
                ctx: ctx
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
            roadClassName: roadClassNameForEdge(ei)
        ))
        if let stub = softStitchStub(tap: to, snap: endSnap, idSuffix: "end") {
            legs.append(stub)
        }

        return finalize(legs: legs, nodeFallback: between)
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
        ctx: HopSearchContext
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
        let startOnMajorHighway = snapIsMajorHighwayPin(startSnap)
        let endOnMajorHighway = snapIsMajorHighwayPin(endSnap)

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
        func linkVirt(_ id: Int) {
            let v = virt[id]
            virtAdj[v.a, default: []].append((to: v.b, id: id, forward: true))
            virtAdj[v.b, default: []].append((to: v.a, id: id, forward: false))
        }
        linkVirt(vStartA)
        linkVirt(vStartB)
        linkVirt(vEndA)
        linkVirt(vEndB)
        if vBetween >= 0 { linkVirt(vBetween) }

        // Join near-miss fabric tips so Allow OFF works
        // on NS OSM+NSTDB packs (Farm Road / driveway → public road).
        let stitches = junctionStitches(
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
                ctx: ctx
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

        dist[startVirt] = 0
        pathMeters[startVirt] = 0
        heap.push(node: startVirt, cost: 0)

        let applyAway = ctx.costMode == .profile && profile != .cleanest
        let applySoftCorridor = applyAway && ctx.corridorMeters == nil
        var pops = 0
        let popCap = min(8_000_000, total * (HopSearchPolicy.varietySlots + 2) * 8)

        while let cur = heap.pop() {
            if cur.cost != dist[cur.node] { continue }
            pops += 1
            if pops > popCap { break }
            if cur.node == endVirt { break }

            if cur.node < n {
                let arcStart = Int(pack.nodeOffsets[cur.node])
                let arcEnd = Int(pack.nodeOffsets[cur.node + 1])
                guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }

                for i in arcStart..<arcEnd {
                    let toNode = Int(pack.edgeTargets[i])
                    let ei = Int(pack.edgeUndirectedIndex[i])
                    guard ei >= 0, ei < pack.undirectedEdgeCount else { continue }
                    if ctx.noBacktrack, isBacktrack(prevKind: prevKind[cur.node], prevData: prevData[cur.node], ei: ei, virt: virt) {
                        continue
                    }
                    let attr = pack.edgeAttrs[ei]
                    let access = GraphV2Pack.unpackAccess(attr)
                    if !accessAllowed(access, allowUnknown: policyUnknown, profile: profile) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }

                    let toLL = coordinate(forNode: toNode)
                    if hopBlocked(toLL, from: from, to: to, ctx: ctx) {
                        continue
                    }

                    let edgeM = Double(pack.edgeMeters[ei])
                    let newMeters = pathMeters[cur.node] + edgeM
                    if let cap = ctx.maxPathMeters, newMeters > cap { continue }

                    let surface = GraphV2Pack.unpackSurface(attr)
                    let roadClass = GraphV2Pack.unpackRoadClass(attr)
                    let confidence = GraphV2Pack.unpackConfidence(attr)
                    var step = hopCostStep(
                        meters: edgeM,
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
                    if applyAway {
                        step += awayExtra(fromNode: cur.node, toNode: toNode)
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
                    if ctx.noBacktrack, v.ei >= 0,
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
                    if hopBlocked(toLL, from: from, to: to, ctx: ctx) {
                        continue
                    }
                    let newMeters = pathMeters[cur.node] + v.meters
                    if let cap = ctx.maxPathMeters, newMeters > cap { continue }
                    var step = v.meters / 1000.0
                    if v.junctionStitch { step *= Self.junctionStitchCostPremium }
                    if applyAway {
                        step += awayExtra(fromNode: cur.node, toNode: item.to)
                    }
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

        guard dist[endVirt].isFinite else { return .failure(.noPath) }

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
                        roadClassName: v.junctionStitch ? "unknown" : roadClassNameForEdge(v.ei)
                    ))
                }
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
                    roadClassName: roadClassNameForEdge(ei)
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
        return .success(finalize(legs: legs, nodeFallback: fallback))
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
        ctx: HopSearchContext
    ) -> Swift.Result<Result, Failure> {
        let B = HopSearchPolicy.balancedBuckets
        let totalNodes = n + 2
        let labels = totalNodes * B
        let shortest = ctx.shortestMeters ?? 1
        func lab(_ node: Int, _ bucket: Int) -> Int { node * B + bucket }
        func nid(_ label: Int) -> Int { label / B }

        var dist = [Double](repeating: .infinity, count: labels)
        var dirtAt = [Double](repeating: 0, count: labels)
        var prev = [Int](repeating: -1, count: labels)
        var prevKind = [UInt8](repeating: 0, count: labels)
        var prevData = [Int](repeating: -1, count: labels)
        var prevForward = [Bool](repeating: true, count: labels)
        var slots = [UInt8](repeating: 0, count: labels)
        var heap = MinHeap()

        let startLab = lab(startVirt, 0)
        dist[startLab] = 0
        heap.push(node: startLab, cost: 0)

        let cap = ctx.maxPathMeters ?? (shortest * HopSearchPolicy.balancedStretch)
        var pops = 0
        let popCap = 8_000_000

        while let cur = heap.pop() {
            pops += 1
            if pops > popCap { break }
            if cur.cost != dist[cur.node] { continue }
            if cur.cost > cap { continue }
            let node = nid(cur.node)
            let dirtSoFar = dirtAt[cur.node]

            if node < n {
                let arcStart = Int(pack.nodeOffsets[node])
                let arcEnd = Int(pack.nodeOffsets[node + 1])
                guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
                for i in arcStart..<arcEnd {
                    let toNode = Int(pack.edgeTargets[i])
                    let ei = Int(pack.edgeUndirectedIndex[i])
                    guard ei >= 0, ei < pack.undirectedEdgeCount else { continue }
                    if ctx.noBacktrack,
                       isBacktrack(prevKind: prevKind[cur.node], prevData: prevData[cur.node], ei: ei, virt: virt) {
                        continue
                    }
                    let attr = pack.edgeAttrs[ei]
                    let access = GraphV2Pack.unpackAccess(attr)
                    if !accessAllowed(access, allowUnknown: policyUnknown, profile: profile) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
                    let toLL = coordinate(forNode: toNode)
                    if hopBlocked(toLL, from: from, to: to, ctx: ctx) { continue }
                    let edgeM = Double(pack.edgeMeters[ei])
                    let newMeters = cur.cost + edgeM
                    if newMeters > cap { continue }
                    let addDirt = edgeIsDirt(ei) ? edgeM : 0
                    let newDirt = dirtSoFar + addDirt
                    let b = HopSearchPolicy.dirtBucket(dirtMeters: newDirt, shortestMeters: shortest)
                    let toLab = lab(toNode, b)
                    var action = HopSearchPolicy.considerRelax(
                        newCost: newMeters,
                        oldCost: dist[toLab],
                        newEi: ei,
                        oldEi: prevData[toLab],
                        node: toNode,
                        newIsDirt: addDirt > 0,
                        oldIsDirt: dirtAt[toLab] > (dist[toLab].isFinite ? dist[toLab] * 0.4 : 0),
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
                            dist[toLab] = newMeters
                            dirtAt[toLab] = newDirt
                            heap.push(node: toLab, cost: newMeters)
                        }
                    }
                }
            }

            if let vlist = virtAdj[node] {
                for item in vlist {
                    let v = virt[item.id]
                    let newMeters = cur.cost + v.meters
                    if newMeters > cap { continue }
                    if ctx.cityWall || ctx.corridorMeters != nil, item.to < n {
                        let toLL = coordinate(forNode: item.to)
                        if hopBlocked(toLL, from: from, to: to, ctx: ctx) { continue }
                    }
                    let b = HopSearchPolicy.dirtBucket(dirtMeters: dirtSoFar, shortestMeters: shortest)
                    let toLab = lab(item.to, b)
                    if newMeters < dist[toLab] {
                        dist[toLab] = newMeters
                        dirtAt[toLab] = dirtSoFar
                        prev[toLab] = cur.node
                        prevKind[toLab] = 1
                        prevData[toLab] = item.id
                        prevForward[toLab] = item.forward
                        heap.push(node: toLab, cost: newMeters)
                    }
                }
            }
        }

        var bestLab = -1
        var bestLen = Double.infinity
        var bestRatioDelta = Double.infinity
        var inBand: [(lab: Int, len: Double, dirt: Double)] = []
        for b in 0..<B {
            let endLab = lab(endVirt, b)
            let len = dist[endLab]
            guard len.isFinite, len > 0 else { continue }
            let ratio = dirtAt[endLab] / len
            if ratio >= HopSearchPolicy.balancedDirtLo, ratio <= HopSearchPolicy.balancedDirtHi {
                inBand.append((endLab, len, dirtAt[endLab]))
            }
            let delta = abs(ratio - 0.50)
            if delta < bestRatioDelta || (abs(delta - bestRatioDelta) < 1e-6 && len < bestLen) {
                bestRatioDelta = delta
                bestLen = len
                bestLab = endLab
            }
        }
        if !inBand.isEmpty {
            let minLen = inBand.map(\.len).min() ?? bestLen
            let near = inBand.filter { $0.len <= minLen * (1 + HopSearchPolicy.varietyMargin) }
            let chosen = near.max { a, b in
                let ha = HopSearchPolicy.hash(ctx.sessionSeed, nid(a.lab), a.lab)
                let hb = HopSearchPolicy.hash(ctx.sessionSeed, nid(b.lab), b.lab)
                if ha != hb { return ha > hb }
                return a.dirt < b.dirt
            }
            if let chosen { bestLab = chosen.lab }
        }
        guard bestLab >= 0, dist[bestLab].isFinite else { return .failure(.noPath) }

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
                        roadClassName: v.junctionStitch ? "unknown" : roadClassNameForEdge(v.ei)
                    ))
                }
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
                    roadClassName: roadClassNameForEdge(ei)
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
        return .success(finalize(legs: legs, nodeFallback: [startSnap.projected, endSnap.projected]))
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
            var direct = Set<Int>()
            let arcStart = Int(pack.nodeOffsets[tip])
            let arcEnd = Int(pack.nodeOffsets[tip + 1])
            if arcStart >= 0, arcEnd <= pack.edgeTargets.count {
                for i in arcStart..<arcEnd {
                    direct.insert(Int(pack.edgeTargets[i]))
                }
            }
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
        let startOnMajorHighway = snapIsMajorHighwayPin(startSnap)
        let endOnMajorHighway = snapIsMajorHighwayPin(endSnap)
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
                    if !accessAllowed(access, allowUnknown: policyUnknown, profile: profile) { continue }
                    let eid = pack.edgeId(ei)
                    if !eid.isEmpty, avoidEdgeIds.contains(eid) { continue }
                    if ctx.noBacktrack, prevEdge[cur.node] == ei { continue }
                    let toLL = coordinate(forNode: toNode)
                    if hopBlocked(toLL, from: from, to: to, ctx: ctx) {
                        continue
                    }

                    let surface = GraphV2Pack.unpackSurface(attr)
                    let roadClass = GraphV2Pack.unpackRoadClass(attr)
                    let confidence = GraphV2Pack.unpackConfidence(attr)
                    var step = (Double(pack.edgeMeters[ei]) / 1000.0)
                        * OnDeviceProfileCosts.edgeCostPerKm(
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
                        endOnMajorHighway: endOnMajorHighway
                    )

                    if policyUnknown {
                        // Allow unlocks unknown; passableQualityMult already prefers
                        // real FSR/track over speculative unknown connectors.
                        let accessName = accessName(access)
                        if accessName == "motorized_unknown", profile == .direct {
                            step *= 0.92
                        }
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
                    let s = stitches[link.idx]
                    var step = (s.meters / 1000.0) * Self.junctionStitchCostPremium
                    if profile != .cleanest {
                        let fromLL = coordinate(forNode: cur.node)
                        let toLL = coordinate(forNode: link.to)
                        step += OnDeviceProfileCosts.approachAwayExtra(
                            profile: profile,
                            dFromMeters: meters(fromLL, endLL),
                            dToMeters: meters(toLL, endLL),
                            abMeters: abMeters,
                            regionId: pack.regionId
                        )
                    }
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
                    roadClassName: roadClassNameForEdge(ei)
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
            nodeFallback: [startSnap.projected, endSnap.projected]
        ))
    }

    // MARK: - Finalize + geographic prune

    private func finalize(
        legs: [Leg],
        nodeFallback: [CLLocationCoordinate2D]
    ) -> Result {
        var worked = legs

        // Geographic loop pruning when legs carry real polyline geometry.
        let hasGeometry = worked.contains { $0.coordinates.count >= 3 }
            || pack.geometry != nil
        if hasGeometry, !worked.isEmpty {
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
                    roadClassName: prior?.roadClassName ?? "unknown"
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
                    roadClassName: prior?.roadClassName ?? "unknown"
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

        return Result(
            coordinates: coords,
            distanceMeters: meters,
            edgeIds: edgeIds,
            legs: worked,
            dirtPercent: dirtPct,
            pavedPercent: pavedPct,
            unknownAccessPercent: unknownPct
        )
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
        osmCoreOnly: Bool = false
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
                        segmentIndex: 0
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
        // ~1.1 km / cell at mid-latitudes; expand until best is inside the ring.
        let cellKm = PackEdgeSpatialIndex.cellDegrees * 111.0
        let maxRadius = max(2, Int(ceil(maxMeters / 1000.0 / cellKm)) + 2)

        var bestDistance = Double.infinity
        var checked = Set<Int>()
        for radius in 0...maxRadius {
            for ei in grid.edgeIndices(nearLat: lat, lon: lon, radiusCells: radius) {
                if checked.contains(ei) { continue }
                checked.insert(ei)
                let access = GraphV2Pack.unpackAccess(pack.edgeAttrs[ei])
                guard accessAllowed(access, allowUnknown: policyUnknown, profile: profile) else { continue }
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
                            segmentIndex: i - 1
                        )
                        if let existing = bestByEdge[ei] {
                            if d < existing.distanceMeters {
                                bestByEdge[ei] = candidate
                            }
                        } else {
                            bestByEdge[ei] = candidate
                        }
                        bestDistance = min(bestDistance, d)
                    }
                    along += segM
                }
            }
            // Absolute nearest is settled once the search ring is farther than it.
            if bestDistance.isFinite, Double(radius + 1) * cellKm * 1000 >= bestDistance {
                break
            }
        }

        return bestByEdge.values
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .prefix(Self.maxStartSnapCandidates * 2)
            .map { $0 }
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
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return "motorized_permissive" }
        let name = accessName(GraphV2Pack.unpackAccess(pack.edgeAttrs[ei]))
        return name.isEmpty ? "motorized_permissive" : name
    }

    private func snapIsMajorHighwayPin(_ snap: EdgeSnap) -> Bool {
        guard snap.distanceMeters < OnDeviceProfileCosts.majorHighwayPinMeters else { return false }
        return OnDeviceProfileCosts.isMajorHighway(roadClassNameForEdge(snap.edgeIndex))
    }

    private func roadClassNameForEdge(_ ei: Int) -> String {
        guard ei >= 0, ei < pack.undirectedEdgeCount else { return "unknown" }
        return GraphV2Pack.roadClassName(GraphV2Pack.unpackRoadClass(pack.edgeAttrs[ei]))
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

    private func hopBlocked(
        _ point: CLLocationCoordinate2D,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        ctx: HopSearchContext
    ) -> Bool {
        if ctx.cityWall, UrbanCore.blocks(point: point, start: from, end: to) { return true }
        return HopSearchPolicy.outsideCorridor(
            point: point, start: from, end: to, widthMeters: ctx.corridorMeters
        )
    }

    private func hopCostStep(
        meters edgeMeters: Double,
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
            var step = dirt ? km * 0.02 : km
            step *= OnDeviceProfileCosts.majorHighwayAvoidMult(
                profile: profile,
                roadClassCode: roadClass,
                metersFromStart: meters(toLL, startSnap.projected),
                metersToDestination: meters(toLL, endLL),
                startOnMajorHighway: startOnMajorHighway,
                endOnMajorHighway: endOnMajorHighway
            )
            return step
        case .profile:
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
                endOnMajorHighway: endOnMajorHighway
            )
            if policyUnknown {
                let accessName = accessName(access)
                if accessName == "motorized_unknown", profile == .direct {
                    step *= 0.92
                }
            }
            return step
        }
    }

    private func accessAllowed(_ code: Int, allowUnknown: Bool, profile: RouteProfile) -> Bool {
        let name = accessName(code)
        if name == "motorized_restricted" || name == "motorized_excluded" { return false }
        if name == "motorized_unknown" { return allowUnknown && profile != .cleanest }
        return true
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
    private var grids: [ObjectIdentifier: PackEdgeSpatialIndex] = [:]

    func grid(for pack: GraphV2Pack) -> PackEdgeSpatialIndex {
        let key = ObjectIdentifier(pack)
        lock.lock()
        defer { lock.unlock() }
        if let existing = grids[key] { return existing }
        let built = PackEdgeSpatialIndex(pack: pack)
        grids[key] = built
        return built
    }
}
