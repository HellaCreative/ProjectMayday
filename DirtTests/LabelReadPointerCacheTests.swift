import Foundation
import Testing
@testable import Dirt

@Suite("Non-owning fixed label page read cache", .serialized)
struct LabelReadPointerCacheTests {
    @Test func demandSearchLabelsAliasLifecycle() throws {
        let count = 1_030
        let store = try DemandSearchLabels(stateCount: count,
            maxPayloadBytes: count * MemoryLayout<DemandSearchLabels.Label>.stride, pageCapacity: 4)
        // Page 0 and page 256 collide, including negative entries.
        #expect(store[0] == DemandSearchLabels.Label())
        #expect(store[1_024] == DemandSearchLabels.Label())
        #expect(store.statistics.allocatedPages == 0)
        try store.mutate(0) { $0.cost = 7; $0.predecessor = -1 }
        #expect(store[0].cost == 7)
        #expect(store[1_024].cost == .infinity)
        try store.mutate(1_024) { $0.cost = 9; $0.predecessor = 0 }
        for _ in 0..<100 {
            #expect(store[0].cost == 7)
            #expect(store[1_024].cost == 9)
        }
        // Cached pointer observes writes directly; returned Label is a copy.
        let snapshot = store[1_024]
        try store.mutate(1_024) { $0.cost = 12; $0.predecessorData = 27 }
        #expect(snapshot.cost == 9)
        #expect(store[1_024].cost == 12 && store[1_024].predecessorData == 27)
        #expect(store[1_029] == DemandSearchLabels.Label())
        try store.mutate(1_029) { $0.slots = 3 }
        #expect(store[1_028] == DemandSearchLabels.Label())
        #expect(store[1_029].slots == 3)
        #expect(store.statistics.allocatedLabelCapacity == 10)
        #expect(store.statistics.logicalLookupCacheBytes <= 4_096)
    }
    @Test func demandSearchLabelsCancellationAndFailedAllocationKeepPointersValid() throws {
        var cancelled = false
        let store = try DemandSearchLabels(stateCount: 20,
            maxPayloadBytes: 3 * MemoryLayout<DemandSearchLabels.Label>.stride,
            pageCapacity: 3, shouldStop: { cancelled })
        #expect(store[0].cost == .infinity)
        try store.mutate(0) { $0.cost = 5 }
        #expect(store[0].cost == 5)
        cancelled = true
        #expect(throws: DemandSearchLabels.StorageError.cancelled) {
            try store.mutate(0) { $0.cost = 99 }
        }
        #expect(store[0].cost == 5)
        cancelled = false
        #expect(store[6].cost == .infinity)
        #expect(throws: DemandSearchLabels.StorageError.memoryLimit) {
            try store.mutate(6) { $0.cost = 99 }
        }
        #expect(store[6].cost == .infinity && store[0].cost == 5)
    }
    @Test func demandBalancedSearchLabelsAliasLifecycle() throws {
        let count = 1_030
        let store = try DemandBalancedSearchLabels(stateCount: count,
            maxPayloadBytes: count * MemoryLayout<DemandBalancedSearchLabels.Label>.stride, pageCapacity: 4)
        // Page 0 and page 256 collide, including negative entries.
        #expect(store[0] == DemandBalancedSearchLabels.Label())
        #expect(store[1_024] == DemandBalancedSearchLabels.Label())
        #expect(store.statistics.allocatedPages == 0)
        try store.mutate(0) { $0.cost = 7; $0.predecessor = -1 }
        #expect(store[0].cost == 7)
        #expect(store[1_024].cost == .infinity)
        try store.mutate(1_024) { $0.cost = 9; $0.predecessor = 0 }
        for _ in 0..<100 {
            #expect(store[0].cost == 7)
            #expect(store[1_024].cost == 9)
        }
        // Cached pointer observes writes directly; returned Label is a copy.
        let snapshot = store[1_024]
        try store.mutate(1_024) { $0.cost = 12; $0.predecessorData = 27 }
        #expect(snapshot.cost == 9)
        #expect(store[1_024].cost == 12 && store[1_024].predecessorData == 27)
        #expect(store[1_029] == DemandBalancedSearchLabels.Label())
        try store.mutate(1_029) { $0.slots = 3 }
        #expect(store[1_028] == DemandBalancedSearchLabels.Label())
        #expect(store[1_029].slots == 3)
        #expect(store.statistics.allocatedLabelCapacity == 10)
        #expect(store.statistics.logicalLookupCacheBytes <= 4_096)
    }
    @Test func demandBalancedSearchLabelsCancellationAndFailedAllocationKeepPointersValid() throws {
        var cancelled = false
        let store = try DemandBalancedSearchLabels(stateCount: 20,
            maxPayloadBytes: 3 * MemoryLayout<DemandBalancedSearchLabels.Label>.stride,
            pageCapacity: 3, shouldStop: { cancelled })
        #expect(store[0].cost == .infinity)
        try store.mutate(0) { $0.cost = 5 }
        #expect(store[0].cost == 5)
        cancelled = true
        #expect(throws: DemandBalancedSearchLabels.StorageError.cancelled) {
            try store.mutate(0) { $0.cost = 99 }
        }
        #expect(store[0].cost == 5)
        cancelled = false
        #expect(store[6].cost == .infinity)
        #expect(throws: DemandBalancedSearchLabels.StorageError.memoryLimit) {
            try store.mutate(6) { $0.cost = 99 }
        }
        #expect(store[6].cost == .infinity && store[0].cost == 5)
    }
}
