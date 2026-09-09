import Foundation
import Testing
@testable import Dirt

@Suite struct LoopPlanTests {
    @Test func candidatesCloseAndFollowSelectedDirection() {
        let start = RouteCoordinate(longitude: -63, latitude: 44)
        let north = RouteCoordinate(longitude: -63, latitude: 45)
        for variant in 0..<3 {
            let points = LoopPlan.anchors(start: start, direction: north, targetMeters: 100_000, variant: variant)
            #expect(points.count == 4)
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
}
