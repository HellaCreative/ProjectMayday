import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Demand allocated routing labels")
struct DemandSearchLabelsTests {
    @Test("Reading untouched turn-state IDs does not allocate any labels")
    func untouchedDefaults() throws {
        let store = try DemandSearchLabels(stateCount: Int.max, maxPayloadBytes: 0)
        #expect(store[0] == DemandSearchLabels.Label())
        #expect(store[9_000_000] == DemandSearchLabels.Label())
        #expect(store[Int.max - 1] == DemandSearchLabels.Label())
        #expect(store.statistics.allocatedPages == 0)
        #expect(store.statistics.allocatedPayloadBytes == 0)
    }

    @Test("Sparse writes preserve dense defaults, stable IDs and all predecessor fields")
    func denseEquivalence() throws {
        let count = 10_003
        var dense = [DemandSearchLabels.Label](repeating: .init(), count: count)
        let store = try DemandSearchLabels(stateCount: count,
            maxPayloadBytes: count * MemoryLayout<DemandSearchLabels.Label>.stride)
        var random: UInt64 = 73
        for index in 0..<400 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let state = Int(random % UInt64(count))
            let row = DemandSearchLabels.Label(
                cost: Double(index) / 7, pathMeters: Double(index * 100),
                predecessor: max(-1, state - 1), predecessorData: index,
                predecessorKind: UInt8(index % 3), forward: index % 2 == 0,
                slots: UInt8(index % 256)
            )
            dense[state] = row
            try store.mutate(state) { $0 = row }
        }
        for state in dense.indices { #expect(store[state] == dense[state]) }
        #expect(store.statistics.allocatedPayloadBytes <= count * MemoryLayout<DemandSearchLabels.Label>.stride)
    }

    @Test("Memory exhaustion rejects a new page without changing prior labels")
    func memoryLimit() throws {
        let stride = MemoryLayout<DemandSearchLabels.Label>.stride
        let store = try DemandSearchLabels(stateCount: 1_000, maxPayloadBytes: 4 * stride, pageCapacity: 4)
        try store.mutate(9) { $0.cost = 7; $0.predecessor = 8 }
        #expect(store.statistics.allocatedLabelCapacity == 4)
        #expect(store.statistics.allocatedPayloadBytes == 4 * stride)
        #expect(throws: DemandSearchLabels.StorageError.memoryLimit) {
            try store.mutate(20) { $0.cost = 0 }
        }
        #expect(store[20].cost == .infinity)
        #expect(store[9].cost == 7)
        #expect(store[9].predecessor == 8)
        // Improving an already resident page remains legal at the allocation cap.
        try store.mutate(10) { $0.cost = 3 }
        #expect(store[10].cost == 3)
        #expect(store.statistics.allocatedPages == 1)
    }

    @Test("A shortened final page is charged at its actual padded label capacity")
    func finalPage() throws {
        let stride = MemoryLayout<DemandSearchLabels.Label>.stride
        let store = try DemandSearchLabels(stateCount: 10, maxPayloadBytes: 2 * stride, pageCapacity: 4)
        try store.mutate(9) { $0.cost = 1 }
        #expect(store.statistics.allocatedLabelCapacity == 2)
        #expect(store.statistics.allocatedPayloadBytes == 2 * stride)
        #expect(throws: DemandSearchLabels.StorageError.memoryLimit) {
            try store.mutate(0) { $0.cost = 2 }
        }
    }

    @Test("Cancellation and invalid IDs are distinct from allocation exhaustion")
    func cancellationAndInvalidIDs() throws {
        let store = try DemandSearchLabels(stateCount: 10, maxPayloadBytes: 0, shouldStop: { true })
        #expect(throws: DemandSearchLabels.StorageError.cancelled) {
            try store.mutate(0) { $0.cost = 0 }
        }
        #expect(throws: DemandSearchLabels.StorageError.invalidState(-1)) {
            try store.mutate(-1) { $0.cost = 0 }
        }
        #expect(throws: DemandSearchLabels.StorageError.invalidState(10)) {
            try store.mutate(10) { $0.cost = 0 }
        }
        #expect(store.statistics.allocatedPages == 0)
    }

    @Test("A real native route reports label exhaustion as incomplete and succeeds with adequate memory")
    func nativeLabelCapClassification() throws {
        func fixture(_ name: String) throws -> URL {
            let bundle = Bundle(for: DemandLabelFixtureBundle.self)
            if let url = bundle.url(forResource: name, withExtension: nil)
                ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
                return url
            }
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures").appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw GraphV2Pack.PackError.truncated
            }
            return url
        }
        let pack = try GraphV2Pack(data: Data(contentsOf: fixture("legal-topology-forecourt.graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: fixture("legal-topology-forecourt.geometry.v1.bin")))
        var router = try fixtureRouter(pack: pack)
        router.matchLimitMeters = 80
        router.initialFuelApproach = true
        let from = CLLocationCoordinate2D(latitude: 45, longitude: -64.004)
        let to = CLLocationCoordinate2D(latitude: 45, longitude: -63.996)
        router.maximumSearchLabelPayloadBytes = 0
        let limited = router.routeDetailed(from: from, to: to, profile: .dirt, allowUnknown: false, sessionSeed: 0)
        guard case .failure(.searchLimit(let reason)) = limited else {
            Issue.record("Native label exhaustion must be a search limit, not no-path or success")
            return
        }
        #expect(reason.hasPrefix("labelMemoryCap:"))
        router.maximumSearchLabelPayloadBytes = 128 * 1024 * 1024
        let measurement = RoutingMeasurement(metadata: ["case": "native-label-cap"], memory: { .init() })
        let sufficient = RoutingWorkContext.$measurement.withValue(measurement) {
            router.routeDetailed(from: from, to: to, profile: .dirt, allowUnknown: false, sessionSeed: 0)
        }
        guard case .success(let route) = sufficient else {
            Issue.record("Known connected native route must complete with adequate label memory")
            return
        }
        #expect(route.distanceMeters > 0)
        let report = measurement.finish(outcome: "complete")
        #expect((report.counters["labelPagesAllocated"] ?? 0) > 0)
        #expect((report.gauges["labelBytes"]?.peak ?? 0) > 0)
        #expect(report.gauges["labelBytes"]?.current == 0)
    }
}

private final class DemandLabelFixtureBundle: NSObject {}
