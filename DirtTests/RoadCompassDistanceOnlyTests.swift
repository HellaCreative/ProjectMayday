import Testing
@testable import Dirt

struct RoadCompassDistanceOnlyTests {
    @Test func omittingUnusedSuccessorsPreservesExactDistancesAndQueueWork() {
        let arcs: [[RoadCompass.Arc]] = [
            [.init(to: 1, edge: 0, meters: 0), .init(to: 1, edge: 0, meters: 0),
             .init(to: 2, edge: 1, meters: 5)],
            [.init(to: 1, edge: 2, meters: 0), .init(to: 2, edge: 3, meters: 2)],
            [.init(to: 0, edge: 4, meters: 3)], []
        ]
        for reverse in [false, true] {
            let complete = RoadCompass.build(stateCount: arcs.count, destination: 0, reverse: reverse) { state, visit in
                arcs[state].forEach(visit)
            }
            let distances = RoadCompass.build(stateCount: arcs.count, destination: 0, reverse: reverse,
                recordSuccessors: false) { state, visit in arcs[state].forEach(visit) }
            #expect(complete.status == distances.status)
            #expect(complete.remaining.map(\.bitPattern) == distances.remaining.map(\.bitPattern))
            #expect(complete.pops == distances.pops)
            #expect(distances.nextState.isEmpty && distances.nextEdge.isEmpty)
            #expect(complete.nextState.count == arcs.count && complete.nextEdge.count == arcs.count)
        }
        let cancelled = RoadCompass.build(stateCount: arcs.count, destination: 0,
            recordSuccessors: false, cancelled: { true }) { _, _ in Issue.record("Cancelled field examined arcs") }
        #expect(cancelled.status == "cancelled" && cancelled.remaining.isEmpty)
    }
}
