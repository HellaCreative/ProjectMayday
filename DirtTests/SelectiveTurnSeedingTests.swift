import Foundation
import Testing
@testable import Dirt

struct SelectiveTurnSeedingTests {
    private func read(_ data: Data, _ at: Int) -> Int {
        data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
    }
    private func put(_ data: inout Data, _ at: Int, _ value: Int) {
        var value = UInt32(value).littleEndian
        Swift.withUnsafeBytes(of: &value) { data.replaceSubrange(at..<at+4, with: $0) }
    }
    private func append<T>(_ values: [T], to data: inout Data) -> Int {
        while data.count % 8 != 0 { data.append(0) }
        let offset = data.count
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        return offset
    }
    private func fixture(nodeRestriction: Bool = false, tail: Int = 0,
                         duplicate: Bool = false, removeDirection: Bool = false) throws -> GraphV2Pack {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-restrictions.graph.v4.bin")
        var bytes = try Data(contentsOf: url)
        if nodeRestriction {
            let restriction = read(bytes,120)+4
            bytes[restriction+10] = 0; bytes[restriction+11] = 0
            put(&bytes,restriction+16,1)
        }
        let old = try GraphV2Pack(data: bytes)
        let stateful = try #require(old.restrictions.first?.fromEdge)
        var offsets: [Int32] = [0], targets: [Int32] = [], edges: [Int32] = []
        var removed = false, duplicated = false
        for node in 0..<old.nodeCount {
            for arc in Int(old.nodeOffsets[node])..<Int(old.nodeOffsets[node+1]) {
                let edge = old.edgeUndirectedIndex[arc], target = old.edgeTargets[arc]
                if removeDirection, !removed, Int(edge) == stateful { removed = true; continue }
                targets.append(target); edges.append(edge)
                if duplicate, !duplicated, Int(edge) == stateful {
                    targets.append(target); edges.append(edge); duplicated = true
                }
            }
            offsets.append(Int32(edges.count))
        }
        offsets.append(contentsOf: repeatElement(Int32(edges.count),count: tail))
        var coords = old.nodeCoords, osmNodes = old.osmNodeIds
        for i in 0..<tail { coords.append(contentsOf: [0,0]); osmNodes.append(Int64(100_000+i)) }
        put(&bytes,8,old.nodeCount+tail); put(&bytes,16,edges.count)
        let offsetsAt = append(offsets,to: &bytes), targetsAt = append(targets,to: &bytes)
        let edgesAt = append(edges,to: &bytes), coordsAt = append(coords,to: &bytes)
        let nodesAt = append(osmNodes,to: &bytes)
        put(&bytes,24,offsetsAt); put(&bytes,28,targetsAt); put(&bytes,32,edgesAt)
        put(&bytes,44,coordsAt); put(&bytes,104,nodesAt)
        return try GraphV2Pack(data: bytes)
    }
    private func compare(_ pack: GraphV2Pack) throws {
        let fast = GraphV2Pack.V4TurnStateSpace.build(pack: pack,startNode: pack.nodeCount,endNode: pack.nodeCount+1)
        let old = GraphV2Pack.V4TurnStateSpace.build(pack: pack,startNode: pack.nodeCount,endNode: pack.nodeCount+1,selectiveSeeding: false)
        #expect(fast.stateCount == old.stateCount)
        #expect(fast.usedSelectiveSeeding)
        #expect(pack.hasVerifiedCSREndpoints)
        #expect(pack.csrValidationScannedArcs == pack.directedArcCount)
        #expect(fast.seedScannedNodes < old.seedScannedNodes)
        #expect(fast.seedScannedArcs <= old.seedScannedArcs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // All expanded states, not just direct arrivals: includes via-way progress.
        for state in 0..<old.stateCount {
            let node = old.graphNode(of: state)
            #expect(fast.graphNode(of: state) == node)
            guard node >= 0, node < pack.nodeCount else { continue }
            for arc in Int(pack.nodeOffsets[node])..<Int(pack.nodeOffsets[node+1]) {
                let edge = Int(pack.edgeUndirectedIndex[arc]), to = Int(pack.edgeTargets[arc])
                let a = fast.transition(state: state,outgoingEdge: edge,toNode: to)
                let b = old.transition(state: state,outgoingEdge: edge,toNode: to)
                #expect(a == b)
                #expect(fast.allowsExit(state: state,outgoingEdge: edge) == old.allowsExit(state: state,outgoingEdge: edge))
                guard a >= 0 else { continue }
                let ta = try fast.exportContinuation(state: a,incomingEdge: edge,arrivedFromNode: node,pack: pack)
                let tb = try old.exportContinuation(state: b,incomingEdge: edge,arrivedFromNode: node,pack: pack)
                #expect(try encoder.encode(ta) == encoder.encode(tb))
                let ia = try fast.importContinuation(tb,pack: pack), ib = try old.importContinuation(ta,pack: pack)
                #expect(ia.stateAtParentEnd == ib.stateAtParentEnd)
                #expect(ia.incomingEdge == ib.incomingEdge && ia.toNode == ib.toNode)
            }
        }
        for node in 0..<pack.nodeCount {
            for edge in pack.restrictions.map(\.fromEdge) {
                #expect(fast.stateForArrival(node: node,incomingEdge: edge) == old.stateForArrival(node: node,incomingEdge: edge))
            }
        }
    }
    @Test func viaWaySeedOrderAndTokensRemainExact() throws { try compare(fixture()) }
    @Test func nodeRestrictionSeedOrderAndTokensRemainExact() throws { try compare(fixture(nodeRestriction: true)) }
    @Test func missingDirectionIsNotInvented() throws { try compare(fixture(removeDirection: true)) }
    @Test func duplicateCSRRetainsStateOrder() throws { try compare(fixture(duplicate: true)) }
    @Test func unusedTailDoesNotRequireWholeNodeScan() throws {
        let pack = try fixture(tail: 4096)
        try compare(pack)
        let fast = GraphV2Pack.V4TurnStateSpace.build(pack: pack,startNode: pack.nodeCount,endNode: pack.nodeCount+1)
        #expect(fast.seedScannedNodes <= pack.restrictions.count * 2)
        #expect(fast.seedScannedNodes < 16)
    }
    @Test func missingOptionalEndpointsKeepsOriginalSeedScan() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-restrictions.graph.v4.bin")
        var bytes = try Data(contentsOf: url)
        bytes[6] &= ~UInt8(1) // Remove optional edgeFrom/edgeTo flag only.
        let pack = try GraphV2Pack(data: bytes)
        #expect(pack.edgeFrom == nil && pack.edgeTo == nil)
        let fast = GraphV2Pack.V4TurnStateSpace.build(pack: pack,startNode: pack.nodeCount,endNode: pack.nodeCount+1)
        let old = GraphV2Pack.V4TurnStateSpace.build(pack: pack,startNode: pack.nodeCount,endNode: pack.nodeCount+1,selectiveSeeding: false)
        #expect(!fast.usedSelectiveSeeding)
        #expect(fast.seedScannedNodes == old.seedScannedNodes)
        #expect(fast.seedScannedArcs == old.seedScannedArcs)
        #expect(fast.stateCount == old.stateCount)
        for state in 0..<old.stateCount {
            let node = old.graphNode(of: state)
            guard node >= 0, node < pack.nodeCount else { continue }
            for arc in Int(pack.nodeOffsets[node])..<Int(pack.nodeOffsets[node+1]) {
                let edge = Int(pack.edgeUndirectedIndex[arc]), to = Int(pack.edgeTargets[arc])
                #expect(fast.transition(state: state,outgoingEdge: edge,toNode: to)
                    == old.transition(state: state,outgoingEdge: edge,toNode: to))
            }
        }
    }

    @Test func malformedCSRRejectsBeforeSelectiveSeedProof() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-restrictions.graph.v4.bin")
        let original = try Data(contentsOf: url)
        let pack = try GraphV2Pack(data: original)
        let edge = try #require(pack.restrictions.first?.fromEdge)
        let from = Int(try #require(pack.edgeFrom?[edge])), to = Int(try #require(pack.edgeTo?[edge]))
        let unrelated = try #require((0..<pack.nodeCount).first {
            $0 != from && $0 != to && pack.nodeOffsets[$0] < pack.nodeOffsets[$0+1]
        })
        let arc = Int(pack.nodeOffsets[unrelated])
        let mutations: [(Int,Int)] = [
            (read(original,32)+arc*4,edge), // Stateful road in unrelated source CSR row.
            (read(original,28),pack.nodeCount), // Out-of-bounds target.
            (read(original,32),pack.undirectedEdgeCount), // Out-of-bounds edge.
            (read(original,24)+4,pack.directedArcCount+1), // Invalid offset range.
            (read(original,24),1) // First CSR row silently omits an arc.
        ]
        for (offset,value) in mutations {
            var malformed = original; put(&malformed,offset,value)
            do {
                _ = try GraphV2Pack(data: malformed)
                Issue.record("Malformed CSR acquired a decoder proof")
            } catch GraphV2Pack.PackError.invalidTopology {
                // This is invalid source data, never an exhausted routing search.
            } catch { Issue.record("Unexpected malformed-data error: \(error)") }
        }
    }

}
