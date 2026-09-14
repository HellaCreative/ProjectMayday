import Foundation
#if canImport(Darwin)
import Darwin
import Darwin.Mach
import Darwin.malloc
#endif

/// A bounded, request/window-owned measurement. It creates no task, timer or
/// sampling thread. Call sampleIfDue in work loops and use phase boundaries to
/// sample preparation. Process high-water marks and sampled request peaks are
/// deliberately separate: a lifetime peak cannot be reset by starting a ride.
nonisolated final class RoutingMeasurement: @unchecked Sendable {
    enum Phase: String, Codable, CaseIterable, Sendable {
        case acquisition, verification, graphAccess, decode, indexing, matching
        case indexSourceScan, indexMerge, indexPublication, indexEnvelopeValidation
        case stationCoverage, seamSourceValidation, seamNodePreparation
        case turnPreparation, reverseGuidance, search, fuelContinuation
        case geometry, finalValidation, display
    }

    enum Counter: String, Codable, CaseIterable, Sendable {
        case downloadedBytes, diskReadBytes, graphPagesRead, graphPageHits
        /// Logical file views opened and bytes consumed by checksums; repeated
        /// access counts repeated work, not unique storage or physical disk I/O.
        case urbanMemoHits, urbanMemoMisses, urbanMemoEvictions
        case matchingGeometrySegments, matchingProjectionCandidates, matchingRoadSnapsConstructed
        case stationCoverageBoundsChecks
        case stationCoverageCacheHits, stationCoverageCacheMisses, stationCoverageEdgesScanned, stationCoverageEntriesEvicted
        case initialFuelBoundMemoHits, initialFuelBoundMemoMisses
        case snapEnvelopeRejectedQueries
        case singleRetraceQueries, singleRetracePredecessorVisits
        case resourceRetraceQueries, resourceRetracePredecessorVisits
        case directedCostMemoHits, directedCostMemoMisses, directedCostMemoEvictions
        case fileBytesAccessed, fileBytesHashed
        case filePageBorrowAcquisitions, filePageBytesBorrowed
        /// Scheduled source-scan checks only; file I/O/hash cancellation checks
        /// remain additional. Counts are batched locally, avoiding per-row locks.
        case indexSourceBlockLoads, indexSourceScalars,indexSourceBufferBorrows,indexScanCancellationChecks
        case decodedEdges, geometryEdgesRead, examinedArcs, examinedStates
        case resourceFiniteLabels, resourceAllocatedLabelSlots, resourceAllocatedPages
        case labelPagesAllocated, labelsCreated, queuePushes, queuePops
        case fuelStagesCommitted, failedContinuations, reusedProofs
        case rangeSnapCacheHits, rangeSnapCacheMisses, rangeSnapCoverageBypasses
        case stationMatchesSkipped, exactSeamRows, exactSeamBindings, seamSpatialLookupsAvoided
        case turnPreparationStates, turnPreparationTransitions
        case turnPreparationByteLimitHits, turnPreparationStateLimitHits, turnPreparationTransitionLimitHits
        case cancelledWindows, dataErrors
    }

    enum Gauge: String, Codable, CaseIterable, Sendable {
        case stationCoverageCacheBytes, stationCoverageCaptureBytes
        case turnPreparationReservedBytes, turnPreparationByteLimit, turnPreparationStateLimit, turnPreparationTransitionLimit
        case directedCostMemoBytes
        case labelDirectoryLogicalBytes
        case graphPageBytes, geometryPageBytes, indexBytes, labelBytes, queueBytes
        case retainedGraphOwners, loadedDetailPages
    }

    struct MemorySample: Codable, Sendable, Equatable {
        var residentBytes: UInt64?
        var footprintBytes: UInt64?
        var processLifetimeResidentPeakBytes: UInt64?
        var processLifetimeFootprintPeakBytes: UInt64?
        var mallocInUseBytes: UInt64?
        var mallocReservedBytes: UInt64?
        /// Sum of allocator-zone high-water marks, which need not have occurred
        /// simultaneously. Not an exact request allocation peak, and excludes
        /// non-malloc mappings such as mapped pack files.
        var mallocZoneHighWaterSumBytes: UInt64?
        var unavailableReason: String?

        static func capture() -> Self {
            #if canImport(Darwin)
            var value = Self()
            var info = task_vm_info_data_t()
            let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
            var count = mach_msg_type_number_t(capacity)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS {
                let returnedBytes = Int(count) * MemoryLayout<integer_t>.size
                func contains(_ offset: Int?, _ size: Int) -> Bool {
                    guard let offset else { return false }
                    return offset + size <= returnedBytes
                }
                if contains(MemoryLayout<task_vm_info_data_t>.offset(of: \.resident_size), 8) {
                    value.residentBytes = UInt64(info.resident_size)
                }
                if contains(MemoryLayout<task_vm_info_data_t>.offset(of: \.resident_size_peak), 8) {
                    value.processLifetimeResidentPeakBytes = UInt64(info.resident_size_peak)
                }
                if contains(MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint), 8) {
                    value.footprintBytes = UInt64(info.phys_footprint)
                }
                if contains(MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak), 8),
                   info.ledger_phys_footprint_peak >= 0 {
                    value.processLifetimeFootprintPeakBytes = UInt64(info.ledger_phys_footprint_peak)
                }
                if value.residentBytes == nil || value.footprintBytes == nil {
                    value.unavailableReason = "TASK_VM_INFO returned an older partial record"
                }
            } else {
                value.unavailableReason = "TASK_VM_INFO failed: \(result)"
            }
            var heap = malloc_statistics_t()
            // A nil zone requests the allocator's sum across all zones.
            malloc_zone_statistics(nil, &heap)
            value.mallocInUseBytes = UInt64(heap.size_in_use)
            value.mallocReservedBytes = UInt64(heap.size_allocated)
            value.mallocZoneHighWaterSumBytes = UInt64(heap.max_size_in_use)
            return value
            #else
            return Self(unavailableReason: "Process memory metrics unavailable on this platform")
            #endif
        }
    }

    struct PhaseSummary: Codable, Sendable, Equatable {
        var completedCount = 0
        var interruptedCount = 0
        var elapsedSeconds: Double = 0
    }

    struct GaugeSummary: Codable, Sendable, Equatable {
        var current: UInt64 = 0
        var peak: UInt64 = 0
    }

    struct Report: Codable, Sendable {
        let id: String
        /// Supply source/pack hashes, named hardware, request settings/seed,
        /// execution path, and preparationState=cold|warm|unknown at call sites.
        let metadata: [String: String]
        let outcome: String
        let totalSeconds: Double
        let sampleCount: UInt64
        let baseline: MemorySample
        let final: MemorySample
        let sampledRequestResidentPeakBytes: UInt64?
        let sampledRequestFootprintPeakBytes: UInt64?
        let sampledRequestMallocInUsePeakBytes: UInt64?
        /// Peak *sampled current* memory minus baseline current memory. This is
        /// process-wide growth during the request, not request-owned allocation.
        let sampledResidentGrowthAboveBaselineBytes: UInt64?
        let sampledFootprintGrowthAboveBaselineBytes: UInt64?
        let sampledMallocGrowthAboveBaselineBytes: UInt64?
        let phases: [String: PhaseSummary]
        let counters: [String: UInt64]
        let gauges: [String: GaugeSummary]
        let droppedPhaseBegins: UInt64
        let notes: [String]
    }

    struct PhaseToken: Sendable {
        fileprivate let owner: UUID
        fileprivate let id: UInt64
    }

    private struct ActivePhase {
        let phase: Phase
        let began: Double
    }

    private let lock = NSLock()
    private let owner = UUID()
    private let metadata: [String: String]
    private let clock: @Sendable () -> Double
    private let memory: @Sendable () -> MemorySample
    private let sampleInterval: Double
    private let started: Double
    private let baseline: MemorySample
    private var lastSampleAt: Double
    private var lastSample: MemorySample
    private var sampleCount: UInt64 = 1
    private var peakResident: UInt64?
    private var peakFootprint: UInt64?
    private var peakMalloc: UInt64?
    private var active: [UInt64: ActivePhase] = [:]
    private var nextToken: UInt64 = 0
    private var phases: [Phase: PhaseSummary] = [:]
    private var counters: [Counter: UInt64] = [:]
    private var gauges: [Gauge: GaugeSummary] = [:]
    private var droppedPhaseBegins: UInt64 = 0
    private var finished: Report?

    init(
        metadata: [String: String],
        sampleIntervalSeconds: Double = 0.05,
        clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        memory: @escaping @Sendable () -> MemorySample = { MemorySample.capture() }
    ) {
        self.metadata = metadata
        self.clock = clock
        self.memory = memory
        sampleInterval = sampleIntervalSeconds.isFinite ? max(0.01, sampleIntervalSeconds) : 0.05
        started = clock()
        baseline = memory()
        lastSampleAt = started
        lastSample = baseline
        peakResident = baseline.residentBytes
        peakFootprint = baseline.footprintBytes
        peakMalloc = baseline.mallocInUseBytes
    }

    @discardableResult
    func begin(_ phase: Phase) -> PhaseToken? {
        lock.lock()
        defer { lock.unlock() }
        guard finished == nil else { return nil }
        guard active.count < 64, nextToken < UInt64.max else {
            droppedPhaseBegins = Self.add(droppedPhaseBegins, 1)
            return nil
        }
        let now = clock()
        sampleLocked(at: now, force: true)
        nextToken += 1
        active[nextToken] = ActivePhase(phase: phase, began: now)
        return PhaseToken(owner: owner, id: nextToken)
    }

    func end(_ token: PhaseToken?) {
        guard let token, token.owner == owner else { return }
        lock.lock()
        defer { lock.unlock() }
        guard finished == nil, let entry = active.removeValue(forKey: token.id) else { return }
        let now = clock()
        var summary = phases[entry.phase, default: PhaseSummary()]
        summary.completedCount += 1
        summary.elapsedSeconds += max(0, now - entry.began)
        phases[entry.phase] = summary
        sampleLocked(at: now, force: true)
    }

    func increment(_ counter: Counter, by amount: UInt64 = 1) {
        lock.lock()
        defer { lock.unlock() }
        guard finished == nil else { return }
        counters[counter] = Self.add(counters[counter, default: 0], amount)
    }

    /// Gauge values are caller-accounted live allocations/owners. They are
    /// supplementary evidence, never a replacement for actual process memory.
    func set(_ gauge: Gauge, to value: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard finished == nil else { return }
        var summary = gauges[gauge, default: GaugeSummary()]
        summary.current = value
        summary.peak = max(summary.peak, value)
        gauges[gauge] = summary
    }

    func sampleIfDue() {
        lock.lock()
        defer { lock.unlock() }
        guard finished == nil else { return }
        sampleLocked(at: clock(), force: false)
    }

    /// Idempotent, suitable for defer on success, failure or cancellation.
    /// No work continues after finish; outstanding phases are marked interrupted.
    @discardableResult
    func finish(outcome: String) -> Report {
        lock.lock()
        defer { lock.unlock() }
        if let finished { return finished }
        let now = clock()
        sampleLocked(at: now, force: true)
        for entry in active.values {
            var summary = phases[entry.phase, default: PhaseSummary()]
            summary.interruptedCount += 1
            summary.elapsedSeconds += max(0, now - entry.began)
            phases[entry.phase] = summary
        }
        active.removeAll()
        let report = Report(
            id: owner.uuidString, metadata: metadata, outcome: outcome,
            totalSeconds: max(0, now - started), sampleCount: sampleCount,
            baseline: baseline, final: lastSample,
            sampledRequestResidentPeakBytes: peakResident,
            sampledRequestFootprintPeakBytes: peakFootprint,
            sampledRequestMallocInUsePeakBytes: peakMalloc,
            sampledResidentGrowthAboveBaselineBytes: Self.growth(peakResident, baseline.residentBytes),
            sampledFootprintGrowthAboveBaselineBytes: Self.growth(peakFootprint, baseline.footprintBytes),
            sampledMallocGrowthAboveBaselineBytes: Self.growth(peakMalloc, baseline.mallocInUseBytes),
            phases: Dictionary(uniqueKeysWithValues: phases.map { ($0.key.rawValue, $0.value) }),
            counters: Dictionary(uniqueKeysWithValues: counters.map { ($0.key.rawValue, $0.value) }),
            gauges: Dictionary(uniqueKeysWithValues: gauges.map { ($0.key.rawValue, $0.value) }),
            droppedPhaseBegins: droppedPhaseBegins,
            notes: [
                "Request peaks sample process-wide current memory at phase boundaries and explicit loop hooks; shorter spikes may be missed.",
                "Process lifetime peaks include earlier work and are not request allocation peaks.",
                "fileBytesAccessed counts logical file views (mappedIfSafe may map or copy); it is not physical disk I/O, resident bytes, or unique stored bytes. filePageBytesBorrowed counts page bytes referenced by borrow acquisitions (including repeats); it is neither copied bytes nor physical I/O. fileBytesHashed counts bytes submitted to checksum operations, including repeated verification and partial cancelled operations.",
                "Malloc zone high-water sums may combine peaks from different times and exclude non-malloc mappings.",
                "Overlapping phase times are inclusive and must not be summed as wall time.",
                "Cold identifies application preparation state; it does not imply an empty operating-system file cache."
            ]
        )
        finished = report
        return report
    }

    private func sampleLocked(at now: Double, force: Bool) {
        guard force || now - lastSampleAt >= sampleInterval else { return }
        lastSample = memory()
        lastSampleAt = now
        sampleCount = Self.add(sampleCount, 1)
        peakResident = Self.maximum(peakResident, lastSample.residentBytes)
        peakFootprint = Self.maximum(peakFootprint, lastSample.footprintBytes)
        peakMalloc = Self.maximum(peakMalloc, lastSample.mallocInUseBytes)
    }

    private static func maximum(_ a: UInt64?, _ b: UInt64?) -> UInt64? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    private static func growth(_ peak: UInt64?, _ baseline: UInt64?) -> UInt64? {
        guard let peak, let baseline else { return nil }
        return peak >= baseline ? peak - baseline : 0
    }

    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : sum
    }
}
