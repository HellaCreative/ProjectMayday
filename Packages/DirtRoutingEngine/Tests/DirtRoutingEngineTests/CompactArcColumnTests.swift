import Testing
@testable import DirtRoutingEngine

struct CompactArcColumnTests {
    @Test func boundariesSentinelAndPromotionPreserveSignedIndices() {
        let values: [Int32] = [-1, 0, 1, 255, 256, 65535, 65536, 0xFFFFFE]
        var column = CompactArcColumn()
        column.reserveCapacity(values.count)
        for value in values { column.append(value) }
        #expect(column.indices.map { column[$0] } == values)
        #expect(column.ownedBytes == values.count * 3)
        let copy = column
        for value: Int32 in [0xFFFFFF, 0x1000000, .max, .min, -2] {
            column.append(value)
            #expect(column[column.count - 1] == value)
            #expect(column.ownedBytes == column.count * 4)
            #expect(values.indices.map { column[$0] } == values)
        }
        #expect(copy.indices.map { copy[$0] } == values)
        #expect(copy.ownedBytes == values.count * 3)
        column[0] = 0x1000001
        #expect(copy[0] == -1)
        #expect(column[0] == 0x1000001)
    }

    @Test func reverseLookupWritesAndCopiesPreserveEverySlot() {
        var compact = CompactArcColumn(repeating: -1, count: 4096, maximumValue: 0xFFFFFE)
        var wide = CompactArcColumn(repeating: -1, count: 4096, maximumValue: .max)
        let untouched = compact
        for i in (0..<4096).reversed() {
            let value = Int32((i * 7919) % 0xFFFFFE)
            compact[i] = value; wide[i] = value
        }
        #expect(compact == wide)
        #expect(compact.ownedBytes == 4096 * 3)
        #expect(untouched.indices.allSatisfy { untouched[$0] == -1 })
        let copy = compact
        compact[2048] = .min
        #expect(compact[2048] == .min)
        #expect(copy == wide)
        for i in compact.indices where i != 2048 { #expect(compact[i] == wide[i]) }
        #expect(CompactArcColumn().count == 0)
    }

    @Test func invalidTargetSentinelsStayOutOfReverseAdjacency() throws {
        let arcs = try ArcIndex(nodeCount: 3, budget: .init()) { node in
            guard node == 0 else { return [] }
            return [RoadArc(target: 1, edge: 0, forward: true, meters: 10),
                    RoadArc(target: -1, edge: 0xFFFFFF, forward: false, meters: 11),
                    RoadArc(target: 3, edge: 0x1000000, forward: false, meters: 12)]
        }
        #expect(arcs.inStart == [0, 0, 1, 1])
        #expect(arcs.inArcs.count == 1)
        #expect(arcs.inArcs[0] == 0)
        #expect(arcs.targets[1] == -1 && arcs.targets[2] == -1)
        #expect(arcs.outEdge[1] == 0xFFFFFF && arcs.outEdge[2] == 0x1000000)
        #expect(arcs.source(2) == 0 && !arcs.forward(2) && arcs.distance(2) == 12)
    }
}
