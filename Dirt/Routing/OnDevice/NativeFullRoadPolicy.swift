import CoreLocation
import Foundation

/// Native full-real-road outer policy, unchanged operation order. Callers own
/// topology/legality, matching, search state and source validation. Lazy reads
/// preserve the original first failure and avoid reading unneeded leaf fields.
nonisolated enum NativeFullRoadPolicy {
    static func step(baseCost: () throws -> Double, meters edgeM: Double, attributes attr: UInt16,
        profile: RouteProfile, ctx: HopSearchContext, toLL: CLLocationCoordinate2D,
        edgeFrom: CLLocationCoordinate2D, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
        endLL: CLLocationCoordinate2D, projectedOrigin: CLLocationCoordinate2D,
        startOnMajorHighway: Bool, endOnMajorHighway: Bool,
        awayExtraMeters: Double?, applySoftCorridor: Bool, hasLeaves: Bool, initialFuelApproach: Bool,
        urbanCores: () -> [UrbanCore.Box], settlementBoxes: () -> [UrbanCore.Box],
        backtrack: (Double) -> Double, currentTier: () throws -> RoadTier,
        predecessorTier: () throws -> RoadTier?) throws -> Double {
        func meters(_ a: CLLocationCoordinate2D,_ b: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: a.latitude,longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude,longitude: b.longitude))
        }
        var step = try baseCost()
        step *= UrbanCore.fallbackMultiplier(
            point: toLL,
            start: from,
            end: to,
            boxes: urbanCores(),
            edgeFrom: edgeFrom,
            penalty: UrbanCore.resolveCleanMetroPenalty(
                profile: profile,
                override: ctx.cleanMetroMultiplier,
                avoidMajorHighways: ctx.avoidMotorways
            )
        )
        if ctx.settlementFallback {
            step *= UrbanCore.settlementFallbackMultiplier(
                point: toLL, start: from, end: to, boxes: settlementBoxes(),
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
        step = backtrack(step)
        let isFerry = GraphV2Pack.isFerryStructure(GraphV2Pack.unpackStructure(attr))
        if !isFerry, profile == .cleanest, hasLeaves, ctx.avoidMotorways,
           let resolvedPredecessorTier = try predecessorTier() {
            step += RoadTierStats.e4MajorHighwayEntryCost(
                fromTier: resolvedPredecessorTier,
                toTier: (try currentTier()),
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
}
