import Foundation

/// Compact completed graph-guidance facts owned by the existing build scope.
/// No graph, field, station name or speculative ordering value is retained.
@MainActor final class FuelLazyGuidanceMemo {
    struct Queue: Sendable { let prepared: LazyOnwardStationPreparation.Prepared;let epoch: String }
    struct Key: Hashable {
        let epoch: String,graph: String,geometry: String
        let from: RouteCoordinate,to: RouteCoordinate,station: RouteCoordinate
        let profile: String,allowUnknown: Bool,cap: Double
        var estimatedPayloadBytes: Int { epoch.utf8.count + graph.utf8.count + geometry.utf8.count + profile.utf8.count + 256 }
    }
    struct Fact: Sendable {
        let forward: Double?,originRemaining: Double?,remaining: Double?
        var valid: Bool { [forward,originRemaining,remaining].allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0) } }
        var complete: Bool { forward != nil && originRemaining != nil && remaining != nil }
    }
    static func eligibleIndices(_ prepared: LazyOnwardStationPreparation.Prepared,ids: [String],
        excluding: Set<String>,required: String? = nil,usableRangeMeters: Double? = nil,seed: UInt64 = 0) -> [Int] {
        let excluded = Set(excluding.map(FuelItinerary.physicalStationID))
        // Approximate only the existing tank-band/coherence work order. These
        // sampled values never enter the exact eligibility dictionaries.
        let ordered = prepared.hints.sorted { a,b in
            guard let af = a.forwardEstimate,let ar = a.remainingEstimate else { return b.hasBothEstimates ? false : a.stationIndex < b.stationIndex }
            guard let bf = b.forwardEstimate,let br = b.remainingEstimate else { return true }
            if (af <= prepared.request.usableMeters) != (bf <= prepared.request.usableMeters) { return af <= prepared.request.usableMeters }
            let ab = HopSearchPolicy.tankCommitBand(graphMeters: af,tankMeters: prepared.request.usableMeters,usableRangeMeters: usableRangeMeters)
            let bb = HopSearchPolicy.tankCommitBand(graphMeters: bf,tankMeters: prepared.request.usableMeters,usableRangeMeters: usableRangeMeters)
            if ab != bb { return ab < bb }
            // Subtracting the common origin remaining distance cancels in the
            // detour comparison. Retain existing ranking tolerances, no gate.
            if abs((af+ar)-(bf+br)) > 5_000 { return af+ar < bf+br }
            if abs(ar-br) > 2_000 { return ar < br }
            if abs(af-bf) > 2_000 { return af < bf }
            func integer(_ value: Double) -> Int { Int(min(Double(Int.max/2),max(0,value))) }
            let ah = HopSearchPolicy.hash(seed,integer(ar),integer(af)),bh = HopSearchPolicy.hash(seed,integer(br),integer(bf))
            return ah == bh ? a.stationIndex < b.stationIndex : ah < bh
        }
        return ordered.map(\.stationIndex).filter { index in
            ids.indices.contains(index) && !excluded.contains(FuelItinerary.physicalStationID(ids[index]))
                && (required == nil || ids[index] == required)
        }
    }
    static func firstProvenIndex(_ indices: [Int],check: () throws -> Void = { try RoutingWorkContext.check() },
        prove: (Int) async throws -> Bool) async throws -> Int? {
        for index in indices {
            try check()
            let accepted = try await prove(index)
            try check()
            if accepted { return index }
        }
        return nil // Caller classifies unproved completion as unknown, not gap.
    }
    private var entries: [(Key,Fact)] = []
    // Logical reservation estimate; actual heap/RSS is measured by RoutingMeasurement.
    private var estimatedRetainedBytes = 0
    private(set) var loads = 0,hits = 0
    func resolve(_ key: Key,currentIdentity: () -> String,
        check: () throws -> Void = { try RoutingWorkContext.check() },
        load: () async throws -> Fact) async throws -> Fact {
        try check()
        guard currentIdentity() == key.epoch else { throw RoutingPageError.sourceChanged }
        if let hit = entries.first(where: { $0.0 == key }) {
            try check();guard currentIdentity() == key.epoch else { throw RoutingPageError.sourceChanged }
            hits += 1
            RoutingDebugLog.shared.event("fuel lazy exact memo hit=\(hits) guidanceQueries=0")
            return hit.1
        }
        let result = try await load();loads += 1
        try check();guard currentIdentity() == key.epoch else { throw RoutingPageError.sourceChanged }
        guard result.valid,result.forward.map({ $0 <= key.cap }) ?? true else { throw RoutingError.fuelUnknown("Exact station guidance is invalid.") }
        RoutingDebugLog.shared.event("fuel lazy exact refinement guidanceQueries=2 loads=\(loads) hits=\(hits)")
        // Legacy nil can mean incomplete guidance. Never memoize it as absence.
        if result.complete,key.estimatedPayloadBytes <= 1_048_576 {
            while !entries.isEmpty && (entries.count >= 256 || estimatedRetainedBytes > 1_048_576-key.estimatedPayloadBytes) {
                estimatedRetainedBytes -= entries.removeFirst().0.estimatedPayloadBytes
            }
            entries.append((key,result));estimatedRetainedBytes += key.estimatedPayloadBytes
        }
        return result
    }
}
