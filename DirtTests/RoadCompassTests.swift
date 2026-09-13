import Foundation
import Testing
@testable import Dirt

@Suite("Legal road-distance compass")
struct RoadCompassTests {
    @Test("retrace rejects overlap but preserves disjoint partial edge spans")
    func roadSpans() {
        let rows: [PathRetrace.Span?] = [nil, .init(edge: 7, lower: 0, upper: 25), .init(edge: 8, lower: 0, upper: 100)]
        let previous = [-1,0,1]
        #expect(PathRetrace.contains(node: 2, span: .init(edge: 7, lower: 20, upper: 80), previous: { previous[$0] }, record: { rows[$0] }))
        #expect(!PathRetrace.contains(node: 2, span: .init(edge: 7, lower: 25, upper: 80), previous: { previous[$0] }, record: { rows[$0] }))
        #expect(!PathRetrace.repeats(rows.compactMap { $0 } + [.init(edge: 7, lower: 25, upper: 80)]))
        #expect(PathRetrace.repeats(rows.compactMap { $0 } + [.init(edge: 7, lower: 0, upper: 25)]))
    }

    @Test("a dead-end becomes farther by road even when it is nearer on the map")
    func deadEnd() {
        let arcs: [[RoadCompass.Arc]] = [
            [.init(to: 1, edge: 0, meters: 10), .init(to: 2, edge: 1, meters: 10)],
            [.init(to: 0, edge: 0, meters: 10)], [.init(to: 3, edge: 2, meters: 50)], []
        ]
        let result = RoadCompass.build(stateCount: 4, destination: 3) { state, visit in
            for arc in arcs[state] { visit(arc) }
        }
        #expect(result.status == "complete")
        #expect(result.remaining == [60,70,50,0])
        #expect(result.nextState == [2,0,3,-1])
    }

    @Test("forward discovery respects one-way arcs instead of reversing access")
    func forwardDistances() {
        let arcs: [[RoadCompass.Arc]] = [
            [.init(to: 1, edge: 0, meters: 10)], [.init(to: 2, edge: 1, meters: 20)], []]
        let forward = RoadCompass.build(stateCount: 3, destination: 0, reverse: false) { state, visit in
            arcs[state].forEach(visit)
        }
        let unreachable = RoadCompass.build(stateCount: 3, destination: 2, reverse: false) { state, visit in
            arcs[state].forEach(visit)
        }
        #expect(forward.remaining == [0, 10, 30])
        #expect(unreachable.remaining[0] == .infinity)
    }

    @Test("incoming via-way state changes remaining legal road metres")
    func turnState() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let data = try Data(contentsOf: base.appendingPathComponent("legal-topology-restrictions.graph.v4.bin"))
        let identity = try GraphV4Pack(data: data)
        let pack = try GraphV2Pack(data: data)
        func node(_ id: Int64) throws -> Int { try #require(identity.osmNodeIds.firstIndex(of: id)) }
        func edge(_ id: Int64) throws -> Int { try #require(pack.osmWayIds.firstIndex(of: id)) }
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        let result = RoadCompass.build(stateCount: turns.stateCount, destination: try node(5)) { state, visit in
            let from = turns.graphNode(of: state)
            if from >= pack.nodeCount { return }
            for arc in Int(pack.nodeOffsets[from])..<Int(pack.nodeOffsets[from + 1]) {
                let ei = Int(pack.edgeUndirectedIndex[arc]), to = Int(pack.edgeTargets[arc])
                if !pack.v4AccessAllowed(ei: ei, from: from, to: to, startEi: -1, endEi: -1, allowUnknown: false) { continue }
                let next = turns.transition(state: state, outgoingEdge: ei, toNode: to)
                if next >= 0 { visit(.init(to: next, edge: ei, meters: Double(pack.edgeMeters[ei]))) }
            }
        }
        let two = try node(2), three = try node(3), four = try node(4)
        let via = pack.osmWayIds.indices.filter { pack.osmWayIds[$0] == 11 }
        let first = try #require(via.first { Int(pack.edgeFrom?[$0] ?? -1) == two || Int(pack.edgeTo?[$0] ?? -1) == two })
        let second = try #require(via.first { $0 != first })
        var state = turns.stateForArrival(node: two, incomingEdge: try edge(10))
        state = turns.transition(state: state, outgoingEdge: first, toNode: three)
        state = turns.transition(state: state, outgoingEdge: second, toNode: four)
        #expect(result.status == "complete")
        #expect(result.remaining[state] == 333)
        #expect(result.remaining[four] == 111)
        #expect(result.nextEdge[state] != Int32(try edge(12)))
    }

    @Test("cancellation never exposes an unfinished distance table")
    func cancelled() {
        let result = RoadCompass.build(stateCount: 4, destination: 3, cancelled: { true }) { _, _ in }
        #expect(result.status == "cancelled")
        #expect(result.remaining.isEmpty)
    }
}
