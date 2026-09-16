import Foundation
import Testing
@testable import Dirt

@Suite struct LoopPlanTests {
    @Test func compassChoicesFollowClockwiseBearingsFromNorth() {
        let start = RouteCoordinate(longitude: -63.33, latitude: 44.76)
        #expect(LoopDirection.allCases.map(\.rawValue) == ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"])
        for (index, direction) in LoopDirection.allCases.enumerated() {
            let guide = direction.guide(from: start)
            let bearing = LoopPlan.bearing(from: start, toward: guide)
            let expected = Double(index) * Double.pi / 4
            #expect(abs(atan2(sin(bearing - expected), cos(bearing - expected))) < 0.000001)
        }
    }

    @Test func generatedLoopKeepsTwoRiderWaypointsAndTheReturnPin() {
        let start = RouteCoordinate(longitude: -63.33, latitude: 44.76)
        let far = LoopPlan.point(from: start, meters: 80_000, bearing: 0)
        let itinerary = reduce(RiderItinerary(), .replaceAll(
            waypoints: [start, far, start], profile: .dirt, allowUnknown: false,
            avoidMotorways: false, preferBackRoads: false)).itinerary
        #expect(itinerary.waypoints.count == 3)
        #expect(itinerary.waypoints.first?.coordinate == start)
        #expect(itinerary.waypoints.last?.coordinate == start)
        #expect(itinerary.waypoints[1].coordinate == far)
        #expect(itinerary.legs.count == 2)
        #expect(itinerary.legs.allSatisfy { $0.profile == .dirt })
        #expect(Set(itinerary.waypoints.map(\.id)).count == 3)
    }
}
