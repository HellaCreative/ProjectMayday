import Foundation
import Testing
@testable import Dirt

@Suite("Bounded Balanced read pointer cache capacities", .serialized)
struct BalancedReadCacheSlotTests {
    @Test func collisionsNegativeCacheMutationAndPartialPagesMatchDirectory() throws {
        for slots in [256,4096] {
            let count = slots*3+2
            let bytes = count * MemoryLayout<DemandBalancedSearchLabels.Label>.stride
            let cached = try DemandBalancedSearchLabels(stateCount: count,maxPayloadBytes: bytes,
                pageCapacity: 3,readCacheSlots: slots)
            let directory = try DemandBalancedSearchLabels(stateCount: count,maxPayloadBytes: bytes,
                pageCapacity: 3,useReadPointerCache: false,readCacheSlots: slots)
            for state in [0,slots*3,count-1] {
                #expect(cached[state] == directory[state])
                #expect(cached[state].cost == .infinity)
            }
            #expect(cached.statistics.allocatedPages == 0)
            for state in [0,slots*3,count-1,0] {
                for store in [cached,directory] {
                    try store.mutate(state) { $0.cost = Double(state+7); $0.predecessor = state-1 }
                }
                for read in [0,slots*3,count-1,1] { #expect(cached[read] == directory[read]) }
            }
            let valueCopy = cached[0]
            try cached.mutate(0) { $0.cost = 99 }
            #expect(valueCopy.cost == 7)
            #expect(cached[0].cost == 99)
            #expect(cached.statistics.allocatedLabelCapacity == 5)
            #expect(cached.statistics.logicalLookupCacheBytes == slots*16)
            #expect(cached.statistics.logicalLookupCacheBytes <= 65_536)
        }
    }
    @Test func boundCancellationAndLifetimeDoNotChangeWithSlotCount() throws {
        for slots in [256,4096] {
            weak var released: DemandBalancedSearchLabels?
            var copied = DemandBalancedSearchLabels.Label()
            do {
                var cancelled = false
                let store = try DemandBalancedSearchLabels(stateCount: 100_000_000,
                    maxPayloadBytes: 3*MemoryLayout<DemandBalancedSearchLabels.Label>.stride,
                    pageCapacity: 3,readCacheSlots: slots,shouldStop: { cancelled })
                released = store
                #expect(store.statistics.allocatedPages == 0)
                #expect(store[99_999_999].cost == .infinity)
                try store.mutate(0) { $0.cost = 9 }
                copied = store[0]
                cancelled = true
                #expect(throws: DemandBalancedSearchLabels.StorageError.cancelled) { try store.mutate(0) { $0.cost = 10 } }
                cancelled = false
                #expect(throws: DemandBalancedSearchLabels.StorageError.memoryLimit) { try store.mutate(3) { $0.cost = 11 } }
                #expect(store[0].cost == 9 && store[3].cost == .infinity)
                #expect(store.statistics.allocatedLabelCapacity == 3)
            }
            #expect(released == nil)
            #expect(copied.cost == 9)
        }
        for invalid in [0,-1,255,4097,8192,Int.max] {
            #expect(throws: DemandBalancedSearchLabels.StorageError.invalidConfiguration) {
                _ = try DemandBalancedSearchLabels(stateCount: 1,maxPayloadBytes: 100,readCacheSlots: invalid)
            }
        }
    }
}
