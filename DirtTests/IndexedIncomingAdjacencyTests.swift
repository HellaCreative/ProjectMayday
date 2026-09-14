import Foundation
import Testing
@testable import Dirt

@Suite("Bounded indexed incoming topology", .serialized)
struct IndexedIncomingAdjacencyTests {
    private func fixture(unknown: Bool = false,
        _ body: (GraphV2Pack,ExactSnapIndex,URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let pack = try GraphV2Pack(data: Data(contentsOf: directory.appendingPathComponent("indexed-incoming.graph.v4.bin")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index")
        let identity = ExactSnapIndex.Identity(graphSHA256: "incoming-fixture",graphBytes: 1,
            geometrySHA256: "incoming-fixture",geometryBytes: 1)
        try ExactSnapIndexBuilder.build(to: url,identity: identity,edgeCount: pack.undirectedEdgeCount) { edge in
            if unknown && edge == 0 { return nil }
            let a = Int(pack.edgeFrom![edge]), b = Int(pack.edgeTo![edge])
            let ax = Double(pack.nodeCoords[a*2]), ay = Double(pack.nodeCoords[a*2+1])
            let bx = Double(pack.nodeCoords[b*2]), by = Double(pack.nodeCoords[b*2+1])
            return .init(aLon: ax,aLat: ay,bLon: bx,bLat: by,minLon: min(ax,bx),
                maxLon: max(ax,bx),minLat: min(ay,by),maxLat: max(ay,by))
        }
        let index = try ExactSnapIndex(url: url,identity: identity)
        pack.exactSnapIndex = index
        try body(pack,index,url)
    }
    @Test func everyOriginalDirectedArcIncludingParallelAndSelfLoopIsPreserved() throws {
        try fixture { pack,index,_ in
            var expected = [[IndexedIncomingAdjacency.Incoming]](repeating: [],count: pack.nodeCount)
            for source in 0..<pack.nodeCount {
                for arc in Int(pack.nodeOffsets[source])..<Int(pack.nodeOffsets[source+1]) {
                    expected[Int(pack.edgeTargets[arc])].append(.init(source: source,
                        edge: Int(pack.edgeUndirectedIndex[arc]),originalArc: arc))
                }
            }
            let a = try #require(pack.osmNodeIds.firstIndex(of: 1)), b = try #require(pack.osmNodeIds.firstIndex(of: 2))
            #expect(expected[b].filter { $0.source == a }.count == 2)
            #expect(expected[a].filter { $0.source == b }.count == 1)
            #expect(expected[a].filter { $0.source == a }.count == 2)
            try index.withBoundsQuery { (query: ExactSnapIndex.BoundsQuery) throws -> Void in
                let iterator = try IndexedIncomingAdjacency(pack: pack,index: index,query: query)
                for _ in 0..<2 {
                    for node in 0..<pack.nodeCount {
                        var actual: [IndexedIncomingAdjacency.Incoming] = []
                        try iterator.forEachIncoming(to: node) { actual.append($0) }
                        #expect(actual == expected[node])
                    }
                }
                #expect(iterator.statistics.peakPayloadBytes <= 512*1024)
            }
            #expect(index.statistics.leaseCount == 0)
        }
    }
    @Test func unknownBoundsAndWorkCapsNeverReturnIncompleteAdjacency() throws {
        try fixture(unknown: true) { pack,index,_ in
            try index.withBoundsQuery { (query: ExactSnapIndex.BoundsQuery) throws -> Void in
                #expect(throws: IndexedIncomingAdjacency.Failure.incompleteIndex) {
                    _ = try IndexedIncomingAdjacency(pack: pack,index: index,query: query)
                }
            }
        }
        try fixture { pack,index,_ in
            try index.withBoundsQuery { (query: ExactSnapIndex.BoundsQuery) throws -> Void in
                var limits = IndexedIncomingAdjacency.Limits(); limits.maximumCellArcs = 1
                let iterator = try IndexedIncomingAdjacency(pack: pack,index: index,query: query,limits: limits)
                var visits = 0
                #expect(throws: IndexedIncomingAdjacency.Failure.workLimit) {
                    try iterator.forEachIncoming(to: 0) { _ in visits += 1 }
                }
                #expect(visits == 0)
                #expect(iterator.statistics.livePayloadBytes == 0)
                #expect(iterator.statistics.cachedCells == 0)
            }
        }
    }
    @Test func evictedButVisitedCellRemainsChargedAndClosedQueryCannotReuseCache() throws {
        try fixture { pack,index,_ in
            var retained: IndexedIncomingAdjacency?
            try index.withBoundsQuery { (query: ExactSnapIndex.BoundsQuery) throws -> Void in
                var limits = IndexedIncomingAdjacency.Limits()
                limits.maximumCellArcs = 8; limits.maximumPayloadBytes = 256
                let iterator = try IndexedIncomingAdjacency(pack: pack,index: index,query: query,limits: limits)
                retained = iterator
                #expect(throws: IndexedIncomingAdjacency.Failure.memoryLimit) {
                    try iterator.forEachIncoming(to: 0) { _ in
                        try iterator.forEachIncoming(to: 1) { _ in }
                    }
                }
                #expect(iterator.statistics.peakPayloadBytes <= 256)
                iterator.removeCachedCells()
                #expect(iterator.statistics.livePayloadBytes == 0)
                try iterator.forEachIncoming(to: 0) { _ in }
            }
            #expect(throws: RoutingPageError.closed) { try retained?.forEachIncoming(to: 0) { _ in } }
            retained?.removeCachedCells()
            #expect(retained?.statistics.livePayloadBytes == 0)
        }
    }
    @Test func cancellationAndChangedSourcePreventQualifiedResults() throws {
        try fixture { pack,index,url in
            var published = false
            #expect(throws: (any Error).self) {
                try index.withBoundsQuery { (query: ExactSnapIndex.BoundsQuery) throws -> Void in
                    var cancelled = false
                    let iterator = try IndexedIncomingAdjacency(pack: pack,index: index,query: query,cancelled: { cancelled })
                    try iterator.forEachIncoming(to: 0) { _ in }
                    cancelled = true
                    #expect(throws: RoutingPageError.cancelled) { try iterator.forEachIncoming(to: 0) { _ in } }
                    cancelled = false
                    let writer = try FileHandle(forWritingTo: url)
                    try writer.truncate(atOffset: 1); try writer.close()
                    // Cached rows remain provisional until the outer source check.
                    try iterator.forEachIncoming(to: 0) { _ in }
                }
                published = true
            }
            #expect(!published)
            #expect(index.statistics.leaseCount == 0)
        }
    }
}
