import Foundation
import Testing
@testable import Dirt

@Suite("Balanced label allocation granularity", .serialized)
struct BalancedPageCapacityTests {
    @Test func scatteredLegalStatesKeepExactBucketValuesWithLessPadding() throws {
        let count=262_147, stride=MemoryLayout<DemandBalancedSearchLabels.Label>.stride
        let old=try DemandBalancedSearchLabels(stateCount: count,maxPayloadBytes: count*stride,pageCapacity: 256)
        let small=try DemandBalancedSearchLabels(stateCount: count,maxPayloadBytes: count*stride,pageCapacity: 32)
        let states=[0,19,1_000,1_019,2_000,2_019,50_000,50_019,262_146]
        for (ordinal,state) in states.enumerated() {
            #expect(small[state] == old[state])
            let value=DemandBalancedSearchLabels.Label(cost: Double(ordinal),pathMeters: Double(ordinal*100),
                dirtMeters: Double(ordinal*49),predecessor: ordinal == 0 ? -1 : states[ordinal-1],
                predecessorData: ordinal,predecessorKind: UInt8(ordinal%3),forward: ordinal%2 == 0,slots: UInt8(ordinal%4))
            try old.mutate(state) { $0=value };try small.mutate(state) { $0=value }
        }
        for state in 0..<count { #expect(small[state] == old[state]) }
        #expect(small.statistics.finiteLabels == states.count)
        #expect(old.statistics.finiteLabels == states.count)
        #expect(small.statistics.allocatedPayloadBytes < old.statistics.allocatedPayloadBytes)
        #expect(small.statistics.logicalPageDirectoryEntryBytes >= old.statistics.logicalPageDirectoryEntryBytes)
        #expect(small.statistics.logicalLookupCacheBytes == old.statistics.logicalLookupCacheBytes)
    }
    @Test func shortenedPageLimitCancellationAndFiniteOccupancyRemainExact() throws {
        let stride=MemoryLayout<DemandBalancedSearchLabels.Label>.stride
        var cancelled=false
        let store=try DemandBalancedSearchLabels(stateCount: 65,maxPayloadBytes: stride,pageCapacity: 32,
            shouldStop: { cancelled })
        #expect(store[64].cost == .infinity)
        try store.mutate(64) { $0.cost=7 }
        #expect(store.statistics.allocatedLabelCapacity == 1 && store.statistics.finiteLabels == 1)
        try store.mutate(64) { $0.cost=6 }
        #expect(store.statistics.finiteLabels == 1)
        #expect(throws: DemandBalancedSearchLabels.StorageError.memoryLimit) { try store.mutate(0) { $0.cost=1 } }
        #expect(store[0].cost == .infinity && store.statistics.finiteLabels == 1)
        cancelled=true
        #expect(throws: DemandBalancedSearchLabels.StorageError.cancelled) { try store.mutate(64) { $0.cost=9 } }
        #expect(store[64].cost == 6)
        cancelled=false
        try store.mutate(64) { $0.cost = .infinity }
        #expect(store.statistics.finiteLabels == 0)
    }
}
