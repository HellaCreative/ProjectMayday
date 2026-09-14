import Foundation
import Testing
@testable import Dirt

@Suite("Bounded forward range proof")
struct BoundedForwardFuelFieldTests {
    typealias Field = BoundedForwardFuelField
    private func n(_ local: Int,_ pack: Int = 0) -> Field.Node { .init(pack: pack,local: local) }
    @Test func rangeIncludesExactBoundaryAndZeroSeamWithoutCopyingTopology() throws {
        let field = try Field.build(seeds: [.init(node: n(0),meters: 0)],maximumMeters: 20) { node,visit in
            if node == n(0) { try visit(n(1),10);try visit(n(2),100) }
            if node == n(1) { try visit(n(0,1),0) }
            if node == n(0,1) { try visit(n(1,1),10) }
            if node == n(1,1) { try visit(n(2,1),1) }
        }
        #expect(field.completeWithinRange)
        #expect(field.distance(n(1,1)) == 20)
        #expect(!field.possiblyReached(n(2,1)))
        #expect(!field.possiblyReached(n(2)))
        #expect(field.allocatedPayloadBytes <= 8*1024*1024)
    }
    @Test func capsCannotBecomeNegativeReachabilityAndSameEdgeRemainsProtected() throws {
        var limits = Field.Limits();limits.states = 1;limits.queueEntries = 2
        let incomplete = try Field.build(seeds: [.init(node: n(0),meters: 0)],maximumMeters: 20,limits: limits) { _,visit in try visit(n(1),1) }
        #expect(!incomplete.completeWithinRange)
        #expect(incomplete.possiblyReached(n(99)))
        let complete = try Field.build(seeds: [],maximumMeters: 1) { _,_ in }
        #expect(try !StationFieldProbe.canSkip(completedField: complete.completeWithinRange,
            protectedEdges: [42],isPossiblyReachedNode: { complete.possiblyReached(n($0)) }) { visit in
                try visit(42,0,1)
            })
        #expect(try StationFieldProbe.canSkip(completedField: true,
            protectedEdges: [],isPossiblyReachedNode: { complete.possiblyReached(n($0)) }) { visit in
                try visit(43,0,1)
            })
    }
    @Test func oneWayParallelAndCheaperLateRelaxationPreserveDistances() throws {
        let field = try Field.build(seeds: [.init(node: n(0),meters: 0)],maximumMeters: 100) { node,visit in
            switch node.local {
            case 0: try visit(n(1),50);try visit(n(1),40);try visit(n(2),5)
            case 2: try visit(n(1),5)
            case 1: try visit(n(3),1)
            default: break
            }
        }
        #expect(field.distance(n(1)) == 10)
        #expect(field.distance(n(3)) == 11)
        let reverse = try Field.build(seeds: [.init(node: n(3),meters: 0)],maximumMeters: 100) { _,_ in }
        #expect(!reverse.possiblyReached(n(0)))
    }
    @Test func originalPackCSRMatchesIndependentFixtureRelaxation() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/initial-same-edge-oneway.graph.v4.bin")
        let pack = try GraphV2Pack(data: Data(contentsOf: url))
        for origin in 0..<pack.nodeCount {
            var expected = [Double](repeating: .infinity,count: pack.nodeCount)
            expected[origin] = 0
            for _ in 0..<pack.nodeCount {
                for source in 0..<pack.nodeCount {
                    for arc in Int(pack.nodeOffsets[source])..<Int(pack.nodeOffsets[source+1]) {
                        let target = Int(pack.edgeTargets[arc]),edge = Int(pack.edgeUndirectedIndex[arc])
                        expected[target] = min(expected[target],expected[source]+Double(pack.edgeMeters[edge]))
                    }
                }
            }
            let field = try Field.build(packs: [pack],seeds: [.init(node: n(origin),meters: 0)],
                maximumMeters: 100_000,verifiedSeams: { _,_ in })
            #expect(field.completeWithinRange)
            for node in 0..<pack.nodeCount {
                let distance = expected[node] <= 100_000 ? expected[node] : nil
                #expect(field.distance(n(node)) == distance)
            }
        }
    }
    @Test func cancellationAndUnverifiedSeamsThrowRatherThanComplete() throws {
        #expect(throws: RoutingPageError.cancelled) {
            try Field.build(seeds: [],maximumMeters: 10,cancelled: { true }) { _,_ in }
        }
        enum SourceFailure: Error { case changed }
        #expect(throws: SourceFailure.changed) {
            try Field.build(seeds: [.init(node: n(0),meters: 0)],maximumMeters: 10) { _,_ in throw SourceFailure.changed }
        }
    }
}
