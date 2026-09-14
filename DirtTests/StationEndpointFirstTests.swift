import Foundation
import Testing
@testable import Dirt

struct StationEndpointFirstTests {
    @Test func endpointFirstKeepsExactNegativeLawWithFewerBoundsReads() throws {
        for reached: Set<Int> in [[],[3],[5]] {
            for protected: Set<Int> in [[],[1]] {
                let rows = [(0,0,1),(1,2,3),(2,4,5)]
                let intersects: Set<Int> = [0,2]
                var beforeReads = 0, afterReads = 0
                let before = try StationFieldProbe.canSkip(completedField: true,protectedEdges: protected,
                    isPossiblyReachedNode: { reached.contains($0) }) { visit in
                        for (edge,a,b) in rows {
                            beforeReads += 1
                            if intersects.contains(edge) { try visit(edge,a,b) }
                        }
                    }
                let after = try StationFieldProbe.canSkip(completedField: true,protectedEdges: protected,
                    isPossiblyReachedNode: { reached.contains($0) },boundsMayIntersect: { edge in
                        afterReads += 1;return intersects.contains(edge)
                    }) { visit in
                        for (edge,a,b) in rows { try visit(edge,a,b) }
                    }
                #expect(before == after)
                #expect(afterReads <= beforeReads)
                if reached.isEmpty && protected.isEmpty { #expect(afterReads == 0 && beforeReads == 3) }
            }
        }
    }
    @Test func protectedSameEdgeStillChecksExactBoundsAndPropagatesFailure() throws {
        var reads = 0
        #expect(try !StationFieldProbe.canSkip(completedField: true,protectedEdges: [7],
            isPossiblyReachedNode: { _ in false },boundsMayIntersect: { _ in reads += 1;return true }) {
                try $0(7,0,1)
            })
        #expect(reads == 1)
        enum Changed: Error { case source }
        #expect(throws: Changed.source) {
            try StationFieldProbe.canSkip(completedField: true,protectedEdges: [7],
                isPossiblyReachedNode: { _ in false },boundsMayIntersect: { _ in throw Changed.source }) {
                    try $0(7,0,1)
                }
        }
        #expect(try !StationFieldProbe.canSkip(completedField: false,protectedEdges: [],
            isPossiblyReachedNode: { _ in false },boundsMayIntersect: { _ in Issue.record("Incomplete field must not inspect bounds");return false }) { _ in })
    }
    @Test func broadCoverageCacheCannotReuseBoundsFilteredEntry() throws {
        let cache = StationCoverageCache(),owner = NSObject(),index = NSObject()
        var builds = 0
        for _ in 0..<2 {
            for broad in [false,true] {
                var found: [Int] = []
                try cache.enumerate(owner: owner,index: index,latitude: 0,longitude: 0,meters: 550,
                    cellSuperset: broad,cancelled: { false },visit: { found.append($0) }) { emit in
                        builds += 1
                        if broad { try emit(9) }
                    }
                #expect(found == (broad ? [9] : []))
            }
        }
        #expect(builds == 2)
    }
}
