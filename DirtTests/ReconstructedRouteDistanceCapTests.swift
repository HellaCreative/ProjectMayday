import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct ReconstructedRouteDistanceCapTests {
    @Test func ancestorRewriteInvalidatesDescendantBudgetButCannotProveDisconnection() throws {
        let labels = try DemandSearchLabels(stateCount: 4,maxPayloadBytes: 4_096)
        try labels.mutate(0) { $0.pathMeters = 0 }
        try labels.mutate(1) { $0.predecessor = 0; $0.predecessorData = 0; $0.pathMeters = 40 }
        try labels.mutate(2) { $0.predecessor = 1; $0.predecessorData = 1; $0.pathMeters = 90 }
        try labels.mutate(3) { $0.predecessor = 0; $0.predecessorData = 3; $0.pathMeters = 80 }
        // Both prefixes fit 200 m. Existing stealPred changes ancestry without
        // changing the descendant's or rewritten label's stored path distance.
        try labels.mutate(1) { $0.predecessor = 3; $0.predecessorData = 2 }
        let physicalEdgeMeters = [40.0,50,100,80]
        var node = 2, actual = 0.0
        while labels[node].predecessor >= 0 {
            let row = labels[node]
            actual += physicalEdgeMeters[row.predecessorData]
            node = row.predecessor
        }
        #expect(labels[2].pathMeters == 90)
        #expect(actual == 230)
        #expect(OnDeviceRouter.reconstructedDistanceFailure(resultMeters: actual,maximumMeters: 200)
            == .searchLimit("reconstructedDistanceExceedsCap"))
        #expect(OnDeviceRouter.reconstructedDistanceFailure(resultMeters: actual,maximumMeters: actual) == nil)
        #expect(OnDeviceRouter.reconstructedDistanceFailure(resultMeters: actual,maximumMeters: nil) == nil)
        #expect(OnDeviceRouter.reconstructedDistanceFailure(resultMeters: actual,maximumMeters: .infinity) == nil)
        #expect(OnDeviceRouter.reconstructedDistanceFailure(resultMeters: actual.nextUp,maximumMeters: actual)
            == .searchLimit("reconstructedDistanceExceedsCap"))
    }
    /// Actual native boundary coverage; this does not claim the fixture itself
    /// triggers the ancestor rewrite reproduced above.
    @Test(arguments: [RouteProfile.dirt,.balanced,.cleanest])
    func nativeSelectedRouteNeverReturnsSuccessBeyondCallerCap(profile: RouteProfile) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let pack = try GraphV2Pack(data: Data(contentsOf: root.appendingPathComponent("initial-distance-plain.graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: root.appendingPathComponent("initial-distance-plain.geometry.v1.bin")))
        var router = try fixtureRouter(pack: pack)
        router.matchLimitMeters = 20
        router.ridePreferences = RidePreferences(wander: 0,avoidCities: true,avoidHighways: true)
        let from = CLLocationCoordinate2D(latitude: 0,longitude: -0.005)
        let to = CLLocationCoordinate2D(latitude: 0,longitude: 0.025)
        guard case .success(let reference) = router.routeDetailed(from: from,to: to,profile: profile,
            allowUnknown: true,sessionSeed: 0) else { Issue.record("Connected fixture needs a reference ride"); return }
        #expect(reference.distanceMeters > 0)
        for cap in [reference.distanceMeters/2,reference.distanceMeters+1] {
            let result = router.routeDetailed(from: from,to: to,profile: profile,allowUnknown: true,
                sessionSeed: 0,maxRouteMeters: cap)
            if case .success(let route) = result {
                #expect(route.distanceMeters <= cap)
                #expect(abs(route.distanceMeters-route.legs.reduce(0) { $0+$1.distanceMeters }) < 0.000001)
            } else if cap > reference.distanceMeters {
                Issue.record("Sufficient fixture cap should still produce a ride: \(result)")
            }
        }
    }
    @Test func actualFractionalApproachResultIncludesBothProjectionStubs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let pack = try GraphV2Pack(data: Data(contentsOf: root.appendingPathComponent("legal-topology-forecourt.graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: root.appendingPathComponent("legal-topology-forecourt.geometry.v1.bin")))
        var router = try fixtureRouter(pack: pack)
        router.initialFuelApproach = true; router.matchLimitMeters = 80
        let from = CLLocationCoordinate2D(latitude: 44.9997,longitude: -64.004)
        let to = CLLocationCoordinate2D(latitude: 44.9997,longitude: -63.996)
        guard case .success(let result) = router.routeDetailed(from: from,to: to,profile: .cleanest,
            allowUnknown: false,sessionSeed: 0) else { Issue.record("Expected fractional mapped-road approach"); return }
        let stubs = result.legs.filter { $0.edgeId.hasPrefix("soft-stitch") }
        #expect(stubs.count == 2)
        #expect(stubs.allSatisfy { $0.distanceMeters > 0 })
        #expect(abs(result.distanceMeters-result.legs.reduce(0) { $0+$1.distanceMeters }) < 0.000001)
        #expect(OnDeviceRouter.reconstructedDistanceFailure(resultMeters: result.distanceMeters,
            maximumMeters: result.distanceMeters-stubs.reduce(0) { $0+$1.distanceMeters })
            == .searchLimit("reconstructedDistanceExceedsCap"))
    }

}
