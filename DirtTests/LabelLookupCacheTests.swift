import Testing
@testable import Dirt

@Suite("Routing label lookup cache")
struct LabelLookupCacheTests {
    @Test("Allocating a previously absent page replaces its cached defaults")
    func negativeEntryInvalidation() throws {
        let single = try DemandSearchLabels(stateCount: 100, maxPayloadBytes: 10_000, pageCapacity: 4)
        let ratio = try DemandBalancedSearchLabels(stateCount: 100, maxPayloadBytes: 10_000, pageCapacity: 4)
        for _ in 0..<4 {
            #expect(single[19].cost == .infinity)
            #expect(ratio[19].dirtMeters == 0)
        }
        #expect(single.allocationRevision == 0)
        #expect(ratio.allocationRevision == 0)
        try single.mutate(19) { $0.cost = 7; $0.predecessor = 3 }
        try ratio.mutate(19) { $0.cost = 8; $0.dirtMeters = 51; $0.predecessor = 4 }
        #expect(single[19].cost == 7)
        #expect(single[19].predecessor == 3)
        #expect(ratio[19].cost == 8)
        #expect(ratio[19].dirtMeters == 51)
        #expect(single[18].cost == .infinity)
        #expect(ratio[18].dirtMeters == 0)
        #expect(single.allocationRevision == 1)
        #expect(ratio.allocationRevision == 1)
    }

    @Test("Direct-mapped collisions preserve each page and current predecessor values")
    func collisions() throws {
        let single = try DemandSearchLabels(stateCount: 100, maxPayloadBytes: 10_000, pageCapacity: 4)
        let ratio = try DemandBalancedSearchLabels(stateCount: 100, maxPayloadBytes: 10_000, pageCapacity: 4)
        let states = [0, 16, 32, 48, 64, 80, 96]
        for id in states {
            try single.mutate(id) { $0.cost = Double(id); $0.predecessor = id - 1 }
            try ratio.mutate(id) { $0.dirtMeters = Double(id); $0.predecessor = id - 1 }
        }
        for _ in 0..<4 {
            for id in states.reversed() {
                #expect(single[id].cost == Double(id))
                #expect(ratio[id].dirtMeters == Double(id))
                #expect(single[id].predecessor == id - 1)
                #expect(ratio[id].predecessor == id - 1)
            }
        }
        try single.mutate(16) { $0.predecessor = 99 }
        try ratio.mutate(16) { $0.predecessor = 98 }
        #expect(single[16].predecessor == 99)
        #expect(ratio[16].predecessor == 98)
        #expect(single.allocationRevision == states.count)
        #expect(ratio.allocationRevision == states.count)
        #expect(single.statistics.logicalLookupCacheBytes > 0)
    }

    @Test("Non-power-of-two addressing and a partial final page retain exact indices")
    func arbitraryPageCapacity() throws {
        let single = try DemandSearchLabels(stateCount: 17, maxPayloadBytes: 10_000, pageCapacity: 3)
        let ratio = try DemandBalancedSearchLabels(stateCount: 17, maxPayloadBytes: 10_000, pageCapacity: 3)
        for id in 0..<17 {
            try single.mutate(id) { $0.cost = Double(id * 7) }
            try ratio.mutate(id) { $0.dirtMeters = Double(id * 5) }
        }
        for id in 0..<17 {
            #expect(single[id].cost == Double(id * 7))
            #expect(ratio[id].dirtMeters == Double(id * 5))
        }
        #expect(single.statistics.allocatedLabelCapacity == 17)
        #expect(ratio.statistics.allocatedLabelCapacity == 17)
    }

    @Test("Failed allocations neither populate a missing page nor consume a revision")
    func memoryCapPreserved() throws {
        let single = try DemandSearchLabels(stateCount: 100, maxPayloadBytes: 0)
        let ratio = try DemandBalancedSearchLabels(stateCount: 100, maxPayloadBytes: 0)
        #expect(single[1].cost == .infinity)
        #expect(ratio[1].dirtMeters == 0)
        #expect(throws: DemandSearchLabels.StorageError.memoryLimit) {
            try single.mutate(1) { $0.cost = 1 }
        }
        #expect(throws: DemandBalancedSearchLabels.StorageError.memoryLimit) {
            try ratio.mutate(1) { $0.dirtMeters = 1 }
        }
        #expect(single[1].cost == .infinity)
        #expect(ratio[1].dirtMeters == 0)
        #expect(single.allocationRevision == 0)
        #expect(ratio.allocationRevision == 0)
    }
}
