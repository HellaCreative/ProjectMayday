import Testing
@testable import DirtRoutingEngine

struct ReachabilityMarksTests {
    @Test func marksMatchBooleanOracleAcrossWordBoundariesAndClears() {
        var marks = ReachabilityMarks(count: 1027)
        var oracle = Array(repeating: false, count: 1027)
        var seed: UInt64 = 93
        for step in 0..<12000 {
            seed = seed &* 6364136223846793005 &+ 1
            let index = Int((seed >> 17) % UInt64(oracle.count))
            let value = step % 3 != 0
            marks[index] = value; oracle[index] = value
        }
        for i in oracle.indices { #expect(marks[i] == oracle[i]) }
        for i in [0, 63, 64, 127, 128, 1026] {
            marks[i] = true; #expect(marks[i]); marks[i] = false; #expect(!marks[i])
        }
    }
    @Test func cachedCopyStaysIndependentWhenScratchMarksChange() {
        var scratch = ReachabilityMarks(count: 129)
        scratch[64] = true
        let cached = scratch
        scratch[64] = false; scratch[128] = true
        #expect(cached[64]); #expect(!cached[128])
        #expect(!scratch[64]); #expect(scratch[128])
    }
    @Test func regionalProofStorageHasOneBitPerEntryWithBoundedTail() {
        #expect(ReachabilityMarks(count: 0).storageBytes == 0)
        #expect(ReachabilityMarks(count: 64).storageBytes == 8)
        #expect(ReachabilityMarks(count: 65).storageBytes == 16)
        #expect(ReachabilityMarks(count: 8_000_000).storageBytes == 1_000_000)
    }
}
