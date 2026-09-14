import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct NativeFullRoadPolicyTests {
    private enum Failure: Error { case unavailable }
    private let start = CLLocationCoordinate2D(latitude: 44,longitude: -65)
    private let end = CLLocationCoordinate2D(latitude: 46,longitude: -63)
    @Test func nativeOuterPolicyMatchesReferenceAcrossInteractions() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-city.graph.v4.bin")
        let pack = try GraphV2Pack(data: Data(contentsOf: url))
        let edge = 0, attr = pack.edgeAttrs[edge], eid = pack.edgeId(edge)
        let box = try #require(pack.urbanCores.first ?? UrbanCore.boxes.first)
        let middle = CLLocationCoordinate2D(latitude: (box.minLat+box.maxLat)/2,longitude: (box.minLon+box.maxLon)/2)
        var different: Set<UInt64> = []
        for profile in [RouteProfile.cleanest,.dirt,.balanced] {
            for mode in [HopSearchPolicy.CostMode.profile,.pavement,.distance,.balancedResource] {
                for initial in [false,true] {
                    for avoid in [false,true] {
                        for arrival in [false,true] {
                            var ctx = HopSearchContext.forProfile(profile,seed: 17)
                            ctx.costMode = mode; ctx.settlementFallback = true; ctx.urbanCoreFallback = true
                            ctx.avoidMotorways = avoid; ctx.preferBackRoads = avoid
                            ctx.priorEdgeIds = [eid]; ctx.arrivalEdgeId = arrival ? eid : nil
                            ctx.backtrackFactor = 7
                            var old = OnDeviceRouter(pack: pack)
                            old.initialFuelApproach = initial; old.useSharedFullRoadPolicy = false
                            old.useSharedCleanPolicyReads = true
                            var preferences = RidePreferences(); preferences.preferDifferentRoads = true
                            old.ridePreferences = preferences
                            var new = old; new.useSharedFullRoadPolicy = true
                            func step(_ router: OnDeviceRouter) throws -> Double {
                                try router.fullRealRoadStep(meters: 1234,edgeIndex: edge,attributes: attr,edgeID: eid,
                                    surface: GraphV2Pack.unpackSurface(attr),roadClass: GraphV2Pack.unpackRoadClass(attr),
                                    access: GraphV2Pack.unpackAccess(attr),confidence: GraphV2Pack.unpackConfidence(attr),
                                    profile: profile,ctx: ctx,toLL: middle,edgeFrom: start,from: start,to: end,endLL: end,
                                    projectedOrigin: start,abMeters: 250_000,startOnMajorHighway: false,endOnMajorHighway: false,
                                    policyUnknown: false,awayExtraMeters: 0.003,applySoftCorridor: true,predecessorTier: { .localPaved })
                            }
                            let a = try step(old), b = try step(new)
                            #expect(a.bitPattern == b.bitPattern)
                            if initial { #expect(b.bitPattern == (1234.0/1000).bitPattern) }
                            different.insert(a.bitPattern)
                        }
                    }
                }
            }
        }
        #expect(different.count > 4)
    }
    @Test func lazySequenceAndFirstErrorArePreservedEvenForInitialFuel() throws {
        var calls: [String] = []
        var ctx = HopSearchContext.forProfile(.cleanest,seed: 17)
        ctx.avoidMotorways = true; ctx.settlementFallback = true
        func run(failure: String? = nil,initial: Bool = false,ferry: Bool = false,hasPrior: Bool = true) throws -> Double {
            try NativeFullRoadPolicy.step(baseCost: {
                calls.append("base"); if failure == "base" { throw Failure.unavailable }; return 2
            },meters: 1000,attributes: ferry ? 4 << 6 : 0,profile: .cleanest,ctx: ctx,toLL: end,
                edgeFrom: start,from: start,to: end,endLL: end,projectedOrigin: start,
                startOnMajorHighway: false,endOnMajorHighway: false,awayExtraMeters: 3,
                applySoftCorridor: false,hasLeaves: true,initialFuelApproach: initial,
                urbanCores: { calls.append("urban"); return [] },settlementBoxes: { calls.append("settlement"); return [] },
                backtrack: { calls.append("backtrack"); return $0*12 },
                currentTier: { calls.append("current"); if failure == "current" { throw Failure.unavailable }; return .localPaved },
                predecessorTier: { calls.append("previous"); if failure == "previous" { throw Failure.unavailable }; return hasPrior ? .localPaved : nil })
        }
        #expect(try run() == 60)
        #expect(calls == ["base","urban","settlement","backtrack","previous","current"])
        calls = []; #expect(try run(initial: true) == 1)
        #expect(calls == ["base","urban","settlement","backtrack","previous","current"])
        calls = []; _ = try run(ferry: true)
        #expect(calls == ["base","urban","settlement","backtrack"])
        calls = []; _ = try run(hasPrior: false)
        #expect(calls == ["base","urban","settlement","backtrack","previous"])
        calls = []
        #expect(throws: Failure.self) { try run(failure: "base",initial: true) }
        #expect(calls == ["base"])
        calls = []
        #expect(throws: Failure.self) { try run(failure: "previous",initial: true) }
        #expect(calls == ["base","urban","settlement","backtrack","previous"])
    }
}
