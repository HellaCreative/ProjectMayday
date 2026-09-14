import CoreLocation
import Testing
@testable import Dirt

struct ExactRoadProjectionChoiceTests {
    @Test func projectionSelectionMatchesPreviousStrictPerSegmentMinimum() {
        let distances: [[Double]] = [[800,40,40,60,20,20,80], [20,20,20], [551,552],
            [550,550], [Double.nan,10,Double.infinity,5], [0,0,1]]
        for row in distances {
            var optimized = ExactRoadProjectionChoice()
            var old: (distance: Double,along: Double,segment: Int,projected: CLLocationCoordinate2D)?
            for (index,distance) in row.enumerated() {
                let point = CLLocationCoordinate2D(latitude: Double(index)/100,longitude: -63+Double(index)/1_000)
                let along = Double(index)*21.37+0.125
                // Literal prior selection order: radius filter, then strict
                // distance improvement. Every projection component must survive.
                if distance <= 550 {
                    let candidate = (distance,along,index,point)
                    if let previous = old {
                        if distance < previous.distance { old = candidate }
                    } else { old = candidate }
                }
                optimized.consider(distance: distance,maximum: 550,along: along,segment: index,projected: point)
            }
            #expect((optimized.value == nil) == (old == nil))
            if let actual = optimized.value, let expected = old {
                #expect(actual.distance == expected.distance)
                #expect(actual.along == expected.along)
                #expect(actual.segment == expected.segment)
                #expect(actual.projected.latitude == expected.projected.latitude)
                #expect(actual.projected.longitude == expected.projected.longitude)
            }
        }
    }
    @Test func equalDistanceRetainsFirstProjectionAndFraction() {
        var choice = ExactRoadProjectionChoice()
        choice.consider(distance: 0,maximum: 550,along: 23.75,segment: 1,projected: .init(latitude: 45,longitude: -63))
        choice.consider(distance: 0,maximum: 550,along: 90,segment: 7,projected: .init(latitude: 45.001,longitude: -63.001))
        #expect(choice.value?.segment == 1)
        #expect(choice.value?.along == 23.75)
        #expect(choice.value?.projected.latitude == 45)
    }
}
