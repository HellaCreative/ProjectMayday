import Foundation
import Testing
@testable import Dirt

@Suite struct LoopPlanTests {
    @Test func compassChoicesGenerateClosedCircuitsFromCurrentStart() {
        let start = RouteCoordinate(longitude: -63.33, latitude: 44.76)
        #expect(LoopDirection.allCases.map(\.rawValue) == ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"])
        for (index, direction) in LoopDirection.allCases.enumerated() {
            let guide = direction.guide(from: start)
            let bearing = LoopPlan.bearing(from: start, toward: guide)
            let expected = Double(index) * Double.pi / 4
            #expect(abs(atan2(sin(bearing - expected), cos(bearing - expected))) < 0.000001)
            let circuit = LoopPlan.anchors(start: start, direction: guide, targetMeters: 100_000, variant: 0)
            #expect(circuit.first == start && circuit.last == start)
        }
    }

    @Test func candidatesCloseAndFollowSelectedDirection() {
        let start = RouteCoordinate(longitude: -63, latitude: 44)
        let north = RouteCoordinate(longitude: -63, latitude: 45)
        for variant in 0..<6 {
            let points = LoopPlan.anchors(start: start, direction: north, targetMeters: 100_000, variant: variant)
            #expect(points.count == 5)
            #expect(points.first == points.last)
            #expect(points[1].latitude > start.latitude)
            #expect(points[2].latitude > start.latitude)
            #expect(points[1] != points[2])
        }
    }

    @Test func detectsReversedRoadAndPrefersDistinctCircuit() {
        let a = RouteCoordinate(longitude: -63, latitude: 44)
        let b = RouteCoordinate(longitude: -63, latitude: 44.01)
        let outward = LoopPlan.repeatedMeters(paths: [[a, b]])
        let returning = LoopPlan.repeatedMeters(paths: [[a, b], [b, a]])
        #expect(outward == 0)
        #expect(returning > 900)
        #expect(LoopPlan.score(distance: 105_000, repeated: 1000, target: 100_000, reusedStops: 0)
                < LoopPlan.score(distance: 100_000, repeated: 30_000, target: 100_000, reusedStops: 1))
    }

    @Test func distanceScalesCandidates() {
        let a = RouteCoordinate(longitude: -63, latitude: 44)
        let b = RouteCoordinate(longitude: -62, latitude: 44)
        let small = LoopPlan.anchors(start: a, direction: b, targetMeters: 100_000, variant: 0)
        let large = LoopPlan.anchors(start: a, direction: b, targetMeters: 500_000, variant: 0)
        #expect(large[1].longitude > small[1].longitude)
    }
    @Test func rejectsFoldedCircuitsAndAllowsShortSharedAccess() {
        let a = RouteCoordinate(longitude: -63, latitude: 44)
        let b = RouteCoordinate(longitude: -63, latitude: 44.1)
        let c = RouteCoordinate(longitude: -62.9, latitude: 44.1)
        let d = RouteCoordinate(longitude: -62.9, latitude: 44)
        #expect(LoopPlan.circuitFill(paths: [[a,b,c,d,a]]) > 0.99)
        #expect(LoopPlan.circuitFill(paths: [[a,c,b,d,a]]) < 0.01)
        #expect(!LoopPlan.acceptable(distance: 100_000, repeated: 30_000, fill: 0.8))
        #expect(!LoopPlan.acceptable(distance: 100_000, repeated: 0, fill: 0.1))
        #expect(LoopPlan.acceptable(distance: 100_000, repeated: 2000, fill: 0.8))
        #expect(!LoopPlan.acceptable(distance: 200_000, repeated: 0, fill: 1, target: 100_000))
        #expect(LoopPlan.score(distance: 110_000, repeated: 0, target: 100_000, reusedStops: 0, fill: 0.9)
            < LoopPlan.score(distance: 100_000, repeated: 12_000, target: 100_000, reusedStops: 1, fill: 0.4))
    }

}
