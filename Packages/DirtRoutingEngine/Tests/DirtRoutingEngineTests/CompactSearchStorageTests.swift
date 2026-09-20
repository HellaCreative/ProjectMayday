import Testing
@testable import DirtRoutingEngine
struct CompactSearchStorageTests {
    struct OldState: Hashable {
        let node: Int
        let incoming: Int
        let restrictions: [RestrictionProgress]
        let bucket: Int
        var unknownConnectorMeters: Double = 0
        var simple: OldSimpleKey? { restrictions.isEmpty && unknownConnectorMeters == 0 ? OldSimpleKey(node: node, incoming: incoming, bucket: bucket) : nil }
    }
    struct OldSimpleKey: Hashable {
        let node: Int
        let incoming: Int
        let bucket: Int
    }
    struct OldArc {
        let target: Int
        let edge: Int
        let forward: Bool
        let meters: Double
        let lower: Double
        let upper: Double
    }
    struct OldLabel {
        let state: OldState
        let cost: Double
        let meters: Double
        let dirtMeters: Double
        /// Continuous dirt/gravel run ending at this label; resets on pavement.
        let contiguousDirtMeters: Double
        /// True once any contiguous dirt run reached the meaningful floor.
        let achievedMeaningfulDirt: Bool
        /// Paved meters accumulated since start (or since the last meaningful
        /// dirt completion). Drives deferred dirt-entry pressure.
        let pavedWithoutMeaningfulMeters: Double
        let peakProgress: Double
        let parent: Int?
        let arc: OldArc?
    }
    @Test func layoutsShrinkWithoutReducingSearchState() {
        print("SEARCH_STORAGE_LAYOUT oldLabel=\(MemoryLayout<OldLabel>.stride) compactLabel=\(MemoryLayout<PathSearch.Label>.stride) oldKey=\(MemoryLayout<OldSimpleKey>.stride) compactKey=\(MemoryLayout<PathSearch.SimpleKey>.stride)")
        #expect(MemoryLayout<PathSearch.Label>.stride < MemoryLayout<OldLabel>.stride)
        #expect(MemoryLayout<PathSearch.SimpleKey>.stride < MemoryLayout<OldSimpleKey>.stride)
    }
}
