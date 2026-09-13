import Testing
@testable import Dirt

@Suite("Demand allocated ratio search labels")
struct DemandBalancedSearchLabelsTests {
    @Test("Bucket defaults preserve zero dirt without growing single-objective labels")
    func defaultsAndLayouts() throws {
        let store = try DemandBalancedSearchLabels(stateCount: 20_000_000, maxPayloadBytes: 0)
        let untouched = store[19_999_999]
        #expect(untouched.cost == .infinity)
        #expect(untouched.pathMeters == .infinity)
        #expect(untouched.dirtMeters == 0)
        #expect(untouched.predecessor == -1)
        #expect(untouched.predecessorData == -1)
        #expect(untouched.predecessorKind == 0)
        #expect(untouched.forward)
        #expect(untouched.slots == 0)
        #expect(store.statistics.allocatedPayloadBytes == 0)
        #expect(MemoryLayout<DemandSearchLabels.Label>.stride < MemoryLayout<DemandBalancedSearchLabels.Label>.stride)
    }

    @Test("Independent bucket labels retain exact costs, dirt, orientation and predecessor identity")
    func denseBucketEquivalence() throws {
        let buckets = HopSearchPolicy.balancedBuckets
        let count = 1_003 * buckets
        let store = try DemandBalancedSearchLabels(stateCount: count,
            maxPayloadBytes: count * MemoryLayout<DemandBalancedSearchLabels.Label>.stride)
        var dense = [DemandBalancedSearchLabels.Label](repeating: .init(), count: count)
        for node in stride(from: 0, to: 1_003, by: 17) {
            for bucket in 0..<buckets {
                let id = node * buckets + bucket
                let row = DemandBalancedSearchLabels.Label(
                    cost: Double(node * 10 + bucket), pathMeters: Double(node * 20 + bucket),
                    dirtMeters: Double(bucket * 2), predecessor: id == 0 ? -1 : id - 1,
                    predecessorData: node, predecessorKind: UInt8(bucket % 3),
                    forward: bucket % 2 == 0, slots: UInt8(bucket)
                )
                dense[id] = row
                try store.mutate(id) { $0 = row }
            }
        }
        for id in dense.indices { #expect(store[id] == dense[id]) }
        #expect(store.statistics.allocatedLabelCapacity < count)
    }

    @Test("Payload exhaustion preserves already proved bucket records and charges padded stride")
    func exactCapacity() throws {
        let stride = MemoryLayout<DemandBalancedSearchLabels.Label>.stride
        let store = try DemandBalancedSearchLabels(stateCount: 1_000, maxPayloadBytes: stride * 20,
            pageCapacity: 20)
        try store.mutate(407) {
            $0.cost = 8; $0.pathMeters = 900; $0.dirtMeters = 470; $0.predecessor = 208
        }
        #expect(store.statistics.allocatedLabelCapacity == 20)
        #expect(store.statistics.allocatedPayloadBytes == stride * 20)
        #expect(throws: DemandBalancedSearchLabels.StorageError.memoryLimit) {
            try store.mutate(620) { $0.dirtMeters = 1 }
        }
        #expect(store[407].dirtMeters == 470)
        #expect(store[407].predecessor == 208)
        #expect(store[620].dirtMeters == 0)
        #expect(store[620].cost == .infinity)
    }

    @Test("Cancellation does not become memory exhaustion or change a bucket")
    func cancellation() throws {
        let store = try DemandBalancedSearchLabels(stateCount: 20, maxPayloadBytes: 0, shouldStop: { true })
        #expect(throws: DemandBalancedSearchLabels.StorageError.cancelled) {
            try store.mutate(4) { $0.dirtMeters = 5 }
        }
        #expect(store[4].dirtMeters == 0)
        #expect(store.statistics.allocatedPages == 0)
    }
}
