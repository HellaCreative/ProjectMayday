import CoreLocation
import Foundation

/// Shared hop-search constants. Lockstep: `scripts/pack-fabric/routing/lib/hop-search.js`.
nonisolated enum HopSearchPolicy {
    /// Unused for Direct shaping — corridor width replaced stretch-factor.
    static let directStretch: Double = 1.20
    /// Balanced: compute prune only (resource labels). Corridor is the geographic ceiling.
    static let balancedStretch: Double = 1.40
    /// Hard lateral cap from the A→B great circle (metres). Trail networks
    /// are a physical size — not a percentage of trip length.
    static let directCorridorMeters: Double = 15_000
    static let dirtCorridorMeters: Double = 50_000
    /// Safety ceiling only — Balanced shaping is the 45–55% dirt ratio.
    static let balancedCorridorMeters: Double = 40_000
    /// Choice set: paths within this fraction of the incumbent score (5–10% band).
    static let varietyMargin: Double = 0.08
    /// Max near-equal labels expanded per node. Bounds heap growth when the
    /// window allows a slightly worse cost (the deploy-1 crash was unbounded).
    static let varietySlots: Int = 3
    static let balancedDirtLo: Double = 0.45
    static let balancedDirtHi: Double = 0.55
    static let balancedBuckets: Int = 8
    /// Fuel: prefer a pump around this fraction of tank on the hop.
    static let fuelPreferTank: Double = 0.82
    static let fuelMinTank: Double = 0.40
    static let fuelMaxTank: Double = 0.95
    /// Finish to B rather than stuffing a pump on the doorstep.
    static let fuelSkipIfWithin: Double = 1.15

    enum CostMode: Sendable {
        /// Existing profile weight tables (Dirt, Clean).
        case profile
        /// Physical meters — shortest path / fuel reach.
        case distance
        /// Minimize pavement meters (Direct pass 2).
        case pavement
        /// Length cost + dirt resource labels (Balanced).
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

    static func dirtBucket(dirtMeters: Double, shortestMeters: Double) -> Int {
        let span = max(shortestMeters * 0.12, 8_000)
        let b = Int(dirtMeters / span)
        return min(balancedBuckets - 1, max(0, b))
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

    static func corridorMeters(for profile: RouteProfile) -> Double? {
        switch profile {
        case .direct: return directCorridorMeters
        case .dirt: return dirtCorridorMeters
        case .balanced: return balancedCorridorMeters
        case .cleanest: return nil
        }
    }

    /// True when `point` is farther from the A→B great circle than `widthMeters`.
    static func outsideCorridor(
        point: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        widthMeters: Double?
    ) -> Bool {
        guard let width = widthMeters, width > 0 else { return false }
        return abs(GeoMath.crossTrackMeters(point: point, lineFrom: start, to: end)) > width
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
}

nonisolated struct HopSearchContext: Sendable {
    var sessionSeed: UInt64
    var costMode: HopSearchPolicy.CostMode
    var maxPathMeters: Double?
    var shortestMeters: Double?
    var cityWall: Bool
    var noBacktrack: Bool
    var variety: Bool
    var corridorMeters: Double?

    static func forProfile(_ profile: RouteProfile, seed: UInt64) -> HopSearchContext {
        HopSearchContext(
            sessionSeed: seed,
            costMode: .profile,
            maxPathMeters: nil,
            shortestMeters: nil,
            cityWall: profile != .cleanest,
            noBacktrack: true,
            variety: profile != .cleanest,
            corridorMeters: HopSearchPolicy.corridorMeters(for: profile)
        )
    }
}
