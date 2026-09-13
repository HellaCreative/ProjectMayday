import Foundation
import Testing
@testable import Dirt

@Suite("Routing calculation measurement")
struct RoutingMeasurementTests {
    private nonisolated final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Double = 10
        private var reading = RoutingMeasurement.MemorySample(
            residentBytes: 100, footprintBytes: 80,
            processLifetimeResidentPeakBytes: 900,
            processLifetimeFootprintPeakBytes: 800,
            mallocInUseBytes: 50, mallocReservedBytes: 200,
            mallocZoneHighWaterSumBytes: 700
        )
        func clock() -> Double {
            lock.lock(); defer { lock.unlock() }
            return time
        }
        func memory() -> RoutingMeasurement.MemorySample {
            lock.lock(); defer { lock.unlock() }
            return reading
        }
        func advance(_ seconds: Double, resident: UInt64? = nil) {
            lock.lock(); defer { lock.unlock() }
            time += seconds
            if let resident { reading.residentBytes = resident }
        }
    }

    @Test("Request growth excludes a preexisting lifetime peak and finish freezes cancellation evidence")
    func sampledPeakAndCancellation() throws {
        let source = Source()
        let measurement = RoutingMeasurement(metadata: ["preparationState": "warm"],
            clock: { source.clock() }, memory: { source.memory() })
        let phase = measurement.begin(.search)
        source.advance(2, resident: 150)
        measurement.sampleIfDue()
        source.advance(1, resident: 120)
        let report = measurement.finish(outcome: "cancelled")
        #expect(report.totalSeconds == 3)
        #expect(report.sampledRequestResidentPeakBytes == 150)
        #expect(report.sampledResidentGrowthAboveBaselineBytes == 50)
        #expect(report.final.processLifetimeResidentPeakBytes == 900)
        #expect(report.phases["search"]?.interruptedCount == 1)
        #expect(report.phases["search"]?.completedCount == 0)
        #expect(report.phases["search"]?.elapsedSeconds == 3)
        measurement.end(phase)
        measurement.increment(.queuePops)
        source.advance(10, resident: 1_000)
        measurement.sampleIfDue()
        let repeated = measurement.finish(outcome: "complete")
        #expect(repeated.outcome == "cancelled")
        #expect(repeated.totalSeconds == 3)
        #expect(repeated.sampleCount == report.sampleCount)
        #expect(repeated.counters["queuePops"] == nil)
        let encoded = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(RoutingMeasurement.Report.self, from: encoded).id == report.id)
    }

    @Test("Absent process metrics stay absent and unfinished phases have a bounded count")
    func missingMetricsAndPhaseLimit() {
        let measurement = RoutingMeasurement(metadata: [:], clock: { 0 },
            memory: { .init(unavailableReason: "test-unavailable") })
        for _ in 0..<65 { measurement.begin(.decode) }
        let report = measurement.finish(outcome: "incomplete")
        #expect(report.sampledRequestResidentPeakBytes == nil)
        #expect(report.sampledResidentGrowthAboveBaselineBytes == nil)
        #expect(report.baseline.residentBytes == nil)
        #expect(report.final.unavailableReason == "test-unavailable")
        #expect(report.phases["decode"]?.interruptedCount == 64)
        #expect(report.droppedPhaseBegins == 1)
    }

    @Test("Concurrent worker counters remain exact and foreign or duplicate phase endings are ignored")
    func concurrentCountersAndTokenOwnership() {
        let memory: @Sendable () -> RoutingMeasurement.MemorySample = { .init() }
        let first = RoutingMeasurement(metadata: [:], memory: memory)
        let second = RoutingMeasurement(metadata: [:], memory: memory)
        let token = first.begin(.graphAccess)
        second.end(token)
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in first.increment(.examinedArcs) }
        first.end(token)
        first.end(token)
        first.set(.labelBytes, to: 800)
        first.set(.labelBytes, to: 0)
        let report = first.finish(outcome: "complete")
        #expect(report.counters["examinedArcs"] == 1_000)
        #expect(report.phases["graphAccess"]?.completedCount == 1)
        #expect(report.gauges["labelBytes"]?.current == 0)
        #expect(report.gauges["labelBytes"]?.peak == 800)
        #expect(second.finish(outcome: "complete").phases.isEmpty)
    }

    @Test("Darwin capture supplies real process and allocator readings")
    func actualProcessMetrics() {
        let reading = RoutingMeasurement.MemorySample.capture()
        #if canImport(Darwin)
        #expect(reading.residentBytes != nil)
        #expect((reading.residentBytes ?? 0) > 0)
        #expect(reading.footprintBytes != nil)
        #expect(reading.processLifetimeResidentPeakBytes != nil)
        #expect(reading.mallocInUseBytes != nil)
        #expect((reading.mallocInUseBytes ?? 0) > 0)
        #else
        #expect(reading.residentBytes == nil)
        #expect(reading.unavailableReason != nil)
        #endif
    }
}
