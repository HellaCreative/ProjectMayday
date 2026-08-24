import Testing
@testable import Dirt

struct RouteBuildCameraTests {
    @Test func routeBuildCameraPreservesEveryCompletedLegInOrder() throws {
        let map = MapState()
        let start = RouteCoordinate(longitude: -63.34, latitude: 44.76)
        let fuel = RouteCoordinate(longitude: -64.56, latitude: 44.31)
        let destination = RouteCoordinate(longitude: -65.64, latitude: 43.61)

        map.beginRouteBuildCamera(at: start)
        map.appendCompletedRouteBuildLeg([start, fuel])
        map.appendCompletedRouteBuildLeg([fuel, destination])

        let sequence = try #require(map.routeBuildCameraSequence)
        #expect(sequence.steps.count == 3)
        guard case .start(let framedStart) = sequence.steps[0] else {
            Issue.record("First camera step must focus the route start")
            return
        }
        #expect(framedStart == start)
        guard case .completedLeg(let firstLeg) = sequence.steps[1],
              case .completedLeg(let secondLeg) = sequence.steps[2]
        else {
            Issue.record("Completed legs must retain build order")
            return
        }
        #expect(firstLeg == [start, fuel])
        #expect(secondLeg == [fuel, destination])
    }

    @Test func deliberateCameraControlCancelsRouteBuildPlayback() {
        let map = MapState()
        let start = RouteCoordinate(longitude: -63.34, latitude: 44.76)
        let destination = RouteCoordinate(longitude: -65.64, latitude: 43.61)

        map.beginRouteBuildCamera(at: start)
        map.appendCompletedRouteBuildLeg([start, destination])
        map.fit([start, destination])

        #expect(map.routeBuildCameraSequence == nil)
    }
}
