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
                let reference = try GraphV2Pack.V4TurnStateSpace.build(topology: ArrayV4TurnTopology(pack: pack,limits: .init()),startNode: pack.nodeCount,endNode: pack.nodeCount+1)
                #expect(paged.stateCount == reference.stateCount)
                var visited = Set<Int>(),queue = Array(0..<pack.nodeCount),cursor = 0
                var compared = 0,activeTokens = 0
                while cursor < queue.count {
                    let state = queue[cursor];cursor += 1
                    if !visited.insert(state).inserted { continue }
                    let node = paged.graphNode(of: state)
                    try query.outgoing(node) { arc in
                        let next = paged.transition(state: state,outgoingEdge: arc.edge,toNode: arc.target)
                        #expect(next == reference.transition(state: state,outgoingEdge: arc.edge,toNode: arc.target))
                        guard next >= 0 else { return }
                        queue.append(next)
                        for location in [NativeRoutingContinuation.Location.node(try query.node(arc.target).osmID),.edge(fraction: 0.4)] {
                            let expected = try reference.exportContinuation(state: next,incomingEdge: arc.edge,arrivedFromNode: node,pack: pack,location: location)
                            let actual = try paged.exportContinuation(state: next,incomingEdge: arc.edge,arrivedFromNode: node,core: core,query: query,index: index,location: location)
                            #expect(actual == expected);compared += 1
                            if !actual.activeRestrictions.isEmpty { activeTokens += 1 }
                            let imported = try paged.importContinuation(actual,core: core,query: query,index: index)
                            let original = try reference.importContinuation(actual,pack: pack)
                            #expect(imported.stateAtParentEnd == original.stateAtParentEnd)
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
                try prepared.exportContinuation(state: 0,incomingEdge: 0,arrivedFromNode: 1,core: core,query: query,index: index)
            }
        }
    }
}
