import Foundation
import CryptoKit
import Testing
@testable import Dirt

struct PagedV4ContinuationTests {
    private func fixture(_ name: String = "legal-topology-restrictions.graph.v4.bin") throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/"+name))
    }
    private func withPrepared(_ data: Data,_ body: (PagedV4Core,OriginalIDIndex) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paged-continuation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let graph = dir.appendingPathComponent("graph.bin"),ids = dir.appendingPathComponent("ids.bin")
        try data.write(to: graph)
        let hash = SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
        try OriginalIDIndex.prepare(graphURL: graph,to: ids,identity: .init(graphSHA256: hash,graphBytes: data.count))
        let index = try OriginalIDIndex(url: ids,graphURL: graph,identity: .init(graphSHA256: hash,graphBytes: data.count))
        let core = try PagedV4Core(url: graph,identity: .init(sha256: hash,bytes: data.count))
        try body(core,index)
    }
    @Test func nodeAndViaWayProgressTokensMatchArrayReference() throws {
        let data = try fixture(),pack = try GraphV2Pack(data: data)
        try withPrepared(data) { core,index in
            try core.withQuery { query in try core.withLegalQuery { legal in
                let paged = try PagedV4ContinuationSpace.prepare(core: core,query: query,legal: legal,index: index)
                let importedOnly = try PagedV4ContinuationSpace.prepare(core: core,query: query,legal: legal,index: index)
                let reference = try GraphV2Pack.V4TurnStateSpace.build(topology: ArrayV4TurnTopology(pack: pack,limits: .init()),startNode: pack.nodeCount,endNode: pack.nodeCount+1)
                #expect(paged.stateCount == pack.nodeCount+2)
                var visited = Set<Int>(),queue = (0..<pack.nodeCount).map { ($0,$0) },cursor = 0
                var compared = 0,activeTokens = 0
                while cursor < queue.count {
                    let (state,referenceState) = queue[cursor];cursor += 1
                    if !visited.insert(state).inserted { continue }
                    let node = paged.graphNode(of: state)
                    try query.outgoing(node) { arc in
                        let next = try paged.transition(state: state,outgoingEdge: arc.edge,toNode: arc.target,core: core,query: query)
                        let expectedNext = reference.transition(state: referenceState,outgoingEdge: arc.edge,toNode: arc.target)
                        #expect((next >= 0) == (expectedNext >= 0))
                        guard next >= 0 else { return }
                        queue.append((next,expectedNext))
                        for location in [NativeRoutingContinuation.Location.node(try query.node(arc.target).osmID),.edge(fraction: 0.4)] {
                            let expected = try reference.exportContinuation(state: expectedNext,incomingEdge: arc.edge,arrivedFromNode: node,pack: pack,location: location)
                            let actual = try paged.exportContinuation(state: next,incomingEdge: arc.edge,arrivedFromNode: node,core: core,query: query,index: index,location: location)
                            #expect(actual == expected);compared += 1
                            if !actual.activeRestrictions.isEmpty { activeTokens += 1 }
                            let fresh = try importedOnly.importContinuation(actual,core: core,query: query,index: index)
                            #expect(try importedOnly.exportContinuation(state: fresh.stateAtParentEnd,incomingEdge: fresh.incomingEdge,
                                arrivedFromNode: fresh.fromNode,core: core,query: query,index: index,location: location) == actual)
                            let imported = try paged.importContinuation(actual,core: core,query: query,index: index)
                            let original = try reference.importContinuation(actual,pack: pack)
                            #expect(paged.graphNode(of: imported.stateAtParentEnd) == reference.graphNode(of: original.stateAtParentEnd))
                            #expect(imported.incomingEdge == original.incomingEdge && imported.fromNode == original.fromNode && imported.toNode == original.toNode)
                            #expect(imported.location == location)
                            let incompatible = NativeRoutingContinuation(version: actual.version,sourceEpoch: "different-source",incoming: actual.incoming,location: actual.location,restrictionContext: actual.restrictionContext,activeRestrictions: actual.activeRestrictions)
                            #expect(throws: NativeRoutingContinuationError.incompatibleSourceEpoch) {
                                try paged.importContinuation(incompatible,core: core,query: query,index: index)
                            }
                            if !actual.restrictionContext.isEmpty {
                                let missing = NativeRoutingContinuation(version: actual.version,sourceEpoch: actual.sourceEpoch,incoming: actual.incoming,location: actual.location,restrictionContext: [],activeRestrictions: actual.activeRestrictions)
                                #expect(throws: NativeRoutingContinuationError.incompatibleRestrictionContext) {
                                    try paged.importContinuation(missing,core: core,query: query,index: index)
                                }
                            }
                        }
                    }
                }
                #expect(compared > 0 && activeTokens > 0)
            } }
        }
    }
    @Test func indexFromDifferentSourceCannotPrepareTurnSpace() throws {
        let data = try fixture()
        var other = data;other[other.count-1] ^= 1
        try withPrepared(data) { _,index in
            try withPrepared(other) { core,_ in
                try core.withQuery { query in try core.withLegalQuery { legal in
                    #expect(throws: PagedV4Core.Failure.identityMismatch) {
                        try PagedV4ContinuationSpace.prepare(core: core,query: query,legal: legal,index: index)
                    }
                } }
            }
        }
    }
    @Test func closedQueryCannotExportEvenFromPreparedState() throws {
        let data = try fixture()
        try withPrepared(data) { core,index in
            var saved: PagedV4Core.Query?,space: PagedV4ContinuationSpace?
            try core.withQuery { query in try core.withLegalQuery { legal in
                saved = query;space = try PagedV4ContinuationSpace.prepare(core: core,query: query,legal: legal,index: index)
            } }
            let query = try #require(saved),prepared = try #require(space)
            #expect(throws: (any Error).self) {
                try prepared.transition(state: 0,outgoingEdge: 0,toNode: 1,core: core,query: query)
            }
            #expect(throws: (any Error).self) {
                try prepared.exportContinuation(state: 0,incomingEdge: 0,arrivedFromNode: 1,core: core,query: query,index: index)
            }
        }
    }
    @Test func demandTurnBudgetStopsExplicitlyWithoutEvictingExistingStates() throws {
        let data = try fixture(),pack = try GraphV2Pack(data: data)
        var state = try GraphV2Pack.V4TurnStateSpace.build(topology: ArrayV4TurnTopology(pack: pack,limits: .init()),
            startNode: pack.nodeCount,endNode: pack.nodeCount+1,demandDriven: true)
        #expect(state.seedScannedNodes == 0 && state.seedScannedArcs == 0)
        var limits = V4TurnPreparationLimits(); limits.maximumTransitions = 1
        let budget = try V4TurnPreparationBudget(limits: limits)
        try budget.reserve(state.preparationReservedBytes)
        let stateful = Set(pack.restrictions.filter { $0.vehicleMask & 1 != 0 }.map(\.fromEdge))
        var arcs: [(Int,Int,Int)] = []
        for node in 0..<pack.nodeCount {
            for arc in Int(pack.nodeOffsets[node])..<Int(pack.nodeOffsets[node+1]) {
                if stateful.contains(Int(pack.edgeUndirectedIndex[arc])) {
                    arcs.append((node,Int(pack.edgeUndirectedIndex[arc]),Int(pack.edgeTargets[arc])))
                }
            }
        }
        let a = try #require(arcs.first),b = try #require(arcs.dropFirst().first)
        let committed = try state.demandTransition(state: a.0,outgoingEdge: a.1,toNode: a.2,budget: budget)
        #expect(throws: V4TurnPreparationError.resourceLimit) {
            try state.demandTransition(state: b.0,outgoingEdge: b.1,toNode: b.2,budget: budget)
        }
        #expect(try state.demandTransition(state: a.0,outgoingEdge: a.1,toNode: a.2,budget: budget) == committed)
        #expect(state.graphNode(of: committed) == a.2)
    }

}
