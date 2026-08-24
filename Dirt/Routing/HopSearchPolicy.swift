import CoreLocation
import Foundation

/// Shared hop-search constants. Lockstep: `scripts/pack-fabric/routing/lib/hop-search.js`.
nonisolated enum HopSearchPolicy {
    /// Balanced: compute prune only (resource labels). Corridor is the geographic ceiling.
    static let balancedStretch: Double = 1.40
    static let dirtCorridorMeters: Double = 60_000
    /// Safety ceiling only — Balanced shaping is the 45–55% dirt ratio.
    static let balancedCorridorMeters: Double = 40_000
    /// Clean has no corridor product rule (soft forward fan only).
    /// Pack duplicate nodes within this radius are treated as one place for Clean.
    static let cleanCoincidentNodeMeters: Double = 2
    /// Choice set: paths within this fraction of the incumbent score (5–10% band).
    static let varietyMargin: Double = 0.08
    /// Max near-equal labels expanded per node. Bounds heap growth when the
    /// window allows a slightly worse cost (the deploy-1 crash was unbounded).
    static let varietySlots: Int = 3
    static let balancedDirtLo: Double = 0.45
    static let balancedDirtHi: Double = 0.55
    /// Ratio buckets (5% each). Meter-span buckets were coarser than the 10-point band.
    static let balancedBuckets: Int = 20
    /// Numbered waypoint on a packed pump. Lockstep: fuel-chain.js WAYPOINT_FUEL_SNAP_METERS.
    static let fuelWaypointSnapMeters: Double = 150
    static let fuelComfortLo: Double = 0.50
    static let fuelComfortHi: Double = 0.80
    /// Too-early below this. Dijkstra reachability still uses fuelMaxTank = 1.0.
    static let fuelMinTank: Double = 0.50
    /// Midpoint of the comfort window (ranking uses the window, not this target).
    static let fuelPreferTank: Double = 0.65
    /// The rider-entered range is already the safety limit; do not silently shave 5%.
    static let fuelMaxTank: Double = 1.0

    /// 0 = comfort [0.50, 0.80], 1 = too-early <0.50, 2 = desperation >0.80.
    /// Desperation is last so a slightly-early stop beats the tank wall.
    static func tankCommitBand(graphMeters: Double, tankMeters: Double) -> Int {
        guard tankMeters > 0, graphMeters.isFinite else { return 1 }
        let frac = graphMeters / tankMeters
        if frac >= fuelComfortLo && frac <= fuelComfortHi { return 0 }
        if frac < fuelComfortLo { return 1 }
        return 2
    }
    /// Finish to B only when the destination is inside the configured tank range.
    static let fuelSkipIfWithin: Double = 1.0
    /// Pass 2 (profile / pavement / balanced) must finish well under a minute.
    /// Long hops were hitting the 8M pop cap (~2 min) and silently returning shortest.
    static let pass2TimeCapSeconds: Double = 18
    static let pass2PopCap: Int = 400_000
    static let dirtCandidateTimeCapSeconds: Double = 7
    static let dirtCandidatePopCap: Int = 200_000
    static let dirtRidePavedPerKm: Double = 150
    static let dirtRideGravelPerKm: Double = 0.7
    static let dirtRideResourcePerKm: Double = 0.5
    static let dirtRideUnknownTrackPerKm: Double = 0.9

    enum CostMode: Sendable {
        /// Existing profile weight tables (Clean and legacy/fallback searches).
        case profile
        /// Physical meters — shortest path / fuel reach.
        case distance
        /// Minimize pavement meters (adventure pass 2).
        case pavement
        /// Length cost + dirt resource labels (Balanced, Dirt).
        case balancedResource
    }

    static func hash(_ seed: UInt64, _ node: Int, _ ei: Int) -> UInt64 {
        var x = seed &* 6_364_136_223_846_793_005 &+ UInt64(truncatingIfNeeded: node) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(truncatingIfNeeded: ei) &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 30
        x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27
        x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return x
    }

    /// Bucket by running dirt ratio so a longer same-dirt path is not dominated
    /// by a shorter dirtier one in the same meter-span bin.
    static func dirtBucket(dirtMeters: Double, pathMeters: Double) -> Int {
        guard pathMeters > 1 else { return 0 }
        let r = min(1, max(0, dirtMeters / pathMeters))
        let b = Int(r * Double(balancedBuckets))
        return min(balancedBuckets - 1, max(0, b))
    }

    /// Among dest labels, prefer in-band 45–55%; inside that (or overall if none)
    /// pick closer to 50%, then shorter, then session seed.
    static func pickResourceEnd(
        labels: [(lab: Int, len: Double, dirt: Double)],
        profile: RouteProfile,
        seed: UInt64
    ) -> Int? {
        guard !labels.isEmpty else { return nil }
        func ratio(_ x: (lab: Int, len: Double, dirt: Double)) -> Double {
            x.len > 0 ? x.dirt / x.len : 0
        }
        if profile == .dirt {
            return labels.min { a, b in
                let ra = ratio(a)
                let rb = ratio(b)
                if abs(ra - rb) > 0.005 { return ra > rb }
                let pavedA = a.len - a.dirt
                let pavedB = b.len - b.dirt
                if abs(pavedA - pavedB) > 50 { return pavedA < pavedB }
                if abs(a.len - b.len) > 50 { return a.len < b.len }
                return hash(seed, a.lab, 0) < hash(seed, b.lab, 0)
            }?.lab
        }
        let inBand = labels.filter {
            let r = ratio($0)
            return r >= balancedDirtLo && r <= balancedDirtHi
        }
        let pool = inBand.isEmpty ? labels : inBand
        return pool.min { a, b in
            let da = abs(ratio(a) - 0.5)
            let db = abs(ratio(b) - 0.5)
            if abs(da - db) > 0.005 { return da < db }
            if abs(a.len - b.len) > 50 { return a.len < b.len }
            return hash(seed, a.lab, 0) < hash(seed, b.lab, 0)
        }?.lab
    }

    enum RelaxAction: Equatable {
        case reject
        /// Clearly better (or first visit). Reset slots; update dist and push.
        case acceptReset
        /// Inside the window and cheaper. Count a slot; update dist and push.
        case acceptImprove
        /// Inside the window, not cheaper, seed prefers it. Record prev only —
        /// do not push. Re-expanding worse costs is what 500'd live.
        case stealPred
    }

    /// Among costs within `varietyMargin` of the incumbent, pick by session seed.
    /// Slightly worse costs can steal the recorded predecessor (variety) but are
    /// not re-expanded. Each node may only do `varietySlots` window takes.
    static func considerRelax(
        newCost: Double,
        oldCost: Double,
        newEi: Int,
        oldEi: Int,
        node: Int,
        newIsDirt: Bool,
        oldIsDirt: Bool,
        seed: UInt64,
        variety: Bool,
        slotsUsed: Int
    ) -> RelaxAction {
        if !oldCost.isFinite { return .acceptReset }
        if !variety { return newCost < oldCost ? .acceptReset : .reject }
        if newCost < oldCost * (1 - varietyMargin) { return .acceptReset }
        if newCost > oldCost * (1 + varietyMargin) { return .reject }
        if slotsUsed >= varietySlots { return .reject }
        if !prefersNew(
            newCost: newCost, oldCost: oldCost, newEi: newEi, oldEi: oldEi,
            node: node, newIsDirt: newIsDirt, oldIsDirt: oldIsDirt, seed: seed
        ) {
            return .reject
        }
        return newCost < oldCost ? .acceptImprove : .stealPred
    }

    static func prefersNew(
        newCost: Double,
        oldCost: Double,
        newEi: Int,
        oldEi: Int,
        node: Int,
        newIsDirt: Bool,
        oldIsDirt: Bool,
        seed: UInt64
    ) -> Bool {
        let hn = hash(seed, node, newEi)
        let ho = hash(seed, node, oldEi)
        if hn != ho { return hn < ho }
        if newIsDirt != oldIsDirt { return newIsDirt }
        return newCost < oldCost
    }

    static func apply(_ action: RelaxAction, slots: inout [UInt8], at index: Int) -> Bool {
        switch action {
        case .reject:
            return false
        case .acceptReset:
            slots[index] = 1
            return true
        case .acceptImprove, .stealPred:
            if slots[index] < 255 { slots[index] += 1 }
            return true
        }
    }

    static func shouldPush(_ action: RelaxAction) -> Bool {
        action == .acceptReset || action == .acceptImprove
    }

    static func createsCycle(prev: [Int], from: Int, through node: Int) -> Bool {
        var n = from
        var hops = 0
        let cap = prev.count + 2
        while n >= 0, hops < cap {
            if n == node { return true }
            n = prev[n]
            hops += 1
        }
        return hops >= cap
    }

    static func corridorMeters(for profile: RouteProfile) -> Double? {
        switch profile {
        case .dirt: return dirtCorridorMeters
        case .balanced: return balancedCorridorMeters
        case .cleanest: return nil
        }
    }

    static func extraBudget(shortestMeters: Double, for profile: RouteProfile) -> Double? {
        guard let extra = corridorMeters(for: profile) else { return nil }
        return shortestMeters + extra
    }

    static func maxCrossTrackMeters(
        coordinates: [CLLocationCoordinate2D],
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> Double {
        coordinates.reduce(0) { best, p in
            max(best, abs(GeoMath.crossTrackMeters(point: p, lineFrom: start, to: end)))
        }
    }

    static func routeShape(
        coordinates: [CLLocationCoordinate2D],
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> (routeMeters: Double, backwardMeters: Double) {
        guard coordinates.count > 1 else { return (0, 0) }
        let a = RouteCoordinate(longitude: start.longitude, latitude: start.latitude)
        let b = RouteCoordinate(longitude: end.longitude, latitude: end.latitude)
        var routeMeters = 0.0
        var backwardMeters = 0.0
        for index in 1..<coordinates.count {
            let prior = coordinates[index - 1]
            let current = coordinates[index]
            let meters = GeoMath.meters(prior, current)
            guard meters > 0 else { continue }
            routeMeters += meters
            let p0 = RouteCoordinate(longitude: prior.longitude, latitude: prior.latitude)
            let p1 = RouteCoordinate(longitude: current.longitude, latitude: current.latitude)
            if GeoMath.progressAlongAB(from: a, to: b, point: p1)
                < GeoMath.progressAlongAB(from: a, to: b, point: p0) {
                backwardMeters += meters
            }
        }
        return (routeMeters, backwardMeters)
    }
}

nonisolated struct HopSearchContext: Sendable {
    var sessionSeed: UInt64
    var profile: RouteProfile
    var costMode: HopSearchPolicy.CostMode
    var maxPathMeters: Double?
    var shortestMeters: Double?
    var cityWall: Bool
    /// Clean's first search admits only edges that paint as paved.
    var pavedOnly: Bool
    /// Emergency Clean search: keep the wall geometrically passable but make
    /// every metre inside it prohibitively expensive.
    var urbanCoreFallback: Bool
    /// Smaller OSM city/town avoidance. Normal searches use a strong scored
    /// penalty; the wall flag exists only for explicit diagnostic comparisons.
    var settlementWall: Bool
    var settlementFallback: Bool
    var noBacktrack: Bool
    var variety: Bool
    var corridorMeters: Double?
    var hardCorridor: Bool
    var boundedSearch: Bool
    var timeCapSeconds: Double?
    var popCap: Int?
    /// Soft continuity signal from already-built itinerary legs. Never a wall.
    var priorEdgeIds: Set<String>
    var arrivalEdgeId: String?
    var backtrackFactor: Double
    /// DEBUG ONLY. Clean urban-core multiplier override (1…20). Nil → ×120.
    var cleanMetroMultiplier: Double?
    /// Phase E4: strong soft-avoid motorway + trunk (roadClassLeaf). Default off.
    var avoidMotorways: Bool
    /// Phase E4: penalize arterial / prefer collector — never delete. Default off.
    var preferBackRoads: Bool

    static func forProfile(_ profile: RouteProfile, seed: UInt64) -> HopSearchContext {
        HopSearchContext(
            sessionSeed: seed,
            profile: profile,
            costMode: .profile,
            maxPathMeters: nil,
            shortestMeters: nil,
            cityWall: true,
            pavedOnly: false,
            urbanCoreFallback: false,
            settlementWall: false,
            settlementFallback: true,
            noBacktrack: true,
            variety: profile != .cleanest,
            corridorMeters: HopSearchPolicy.corridorMeters(for: profile),
            hardCorridor: false,
            boundedSearch: false,
            timeCapSeconds: nil,
            popCap: nil,
            priorEdgeIds: [],
            arrivalEdgeId: nil,
            backtrackFactor: 4,
            cleanMetroMultiplier: nil,
            avoidMotorways: false,
            preferBackRoads: false
        )
    }
}
