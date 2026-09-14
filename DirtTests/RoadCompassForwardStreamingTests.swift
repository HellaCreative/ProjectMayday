import Foundation
import Testing
@testable import Dirt

struct RoadCompassForwardStreamingTests {
    private var arcs: [[RoadCompass.Arc]] {
        [
            [.init(to: 2, edge: 10, meters: 3), .init(to: 1, edge: 11, meters: 1),
             .init(to: 1, edge: 12, meters: 1), .init(to: 0, edge: 13, meters: 0)],
            [.init(to: 2, edge: 14, meters: 1), .init(to: 3, edge: 15, meters: 3)],
            [.init(to: 3, edge: 16, meters: 2)], [],
            [.init(to: 4, edge: 17, meters: 0)]
        ]
    }

    @Test func exactDistancesPredecessorsTieOrderAndQueueWork() {
        for record in [false, true] {
            let legacy = RoadCompass.build(stateCount: arcs.count, destination: 0,
                reverse: false, recordSuccessors: record, streamForward: false) { node, visit in
                arcs[node].forEach(visit)
            }
            var visited: [Int] = []
            let streamed = RoadCompass.build(stateCount: arcs.count, destination: 0,
                reverse: false, recordSuccessors: record) { node, visit in
                visited.append(node); arcs[node].forEach(visit)
            }
            #expect(streamed.status == "complete")
            #expect(streamed.remaining == [0, 1, 2, 4, .infinity])
            #expect(streamed.remaining.map(\.bitPattern) == legacy.remaining.map(\.bitPattern))
            #expect(streamed.nextState == legacy.nextState)
            #expect(streamed.nextEdge == legacy.nextEdge)
            #expect(streamed.pops == legacy.pops)
            #expect(visited == [0, 1, 2, 3])
            if record { #expect(streamed.nextEdge == [-1, 11, 14, 15, -1]) }
        }
    }

    @Test func reverseStillUsesOriginalPreparation() {
        var calls = 0
        let result = RoadCompass.build(stateCount: arcs.count, destination: 3,
            reverse: true, maximumOutgoingArcs: 1) { node, visit in
            calls += 1; arcs[node].forEach(visit)
        }
        #expect(result.status == "complete")
        #expect(calls == arcs.count * 2)
    }

    @Test func boundedOutgoingFailureNeverReturnsPartialProof() {
        let limited = RoadCompass.build(stateCount: arcs.count, destination: 0,
            reverse: false, maximumOutgoingArcs: 3) { node, visit in arcs[node].forEach(visit) }
        #expect(limited.status == "resourceLimit" && limited.remaining.isEmpty)
        let exact = RoadCompass.build(stateCount: arcs.count, destination: 0,
            reverse: false, maximumOutgoingArcs: 4) { node, visit in arcs[node].forEach(visit) }
        #expect(exact.status == "complete")
    }

    @Test func cancellationDuringProducerAndExpiredWindowReturnNoPartialField() {
        var cancel = false
        let result = RoadCompass.build(stateCount: arcs.count, destination: 0,
            reverse: false, cancelled: { cancel }) { node, visit in
            arcs[node].forEach(visit); cancel = true
        }
        #expect(result.status == "cancelled" && result.remaining.isEmpty)
        let expired = RoadCompass.build(stateCount: 1, destination: 0, reverse: false,
            deadline: .distantPast) { _, _ in Issue.record("Expired field read graph") }
        #expect(expired.status == "timeCap" && expired.remaining.isEmpty)
    }
}
