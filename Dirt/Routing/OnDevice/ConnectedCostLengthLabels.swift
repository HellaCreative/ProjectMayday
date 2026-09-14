import Foundation

/// Staged label storage, not a routing algorithm. Dominance is valid only for
/// the same exact legal arrival AND identical future-relevant path history.
/// The caller must intern exact histories without hash-only equality. Different
/// histories are retained; exhausting capacity is incomplete, never noPath.
nonisolated final class ConnectedCostLengthLabels {
    struct Arrival: Hashable {
        let pack: Int
        let turnState: Int
        /// Search-local interned canonical road ID, including direction where
        /// required by predecessor-tier or legal-arrival semantics.
        let incomingRoad: Int
    }
    struct Label {
        let arrival: Arrival
        let history: Int
        let cost: Double
        let meters: Double
        let predecessor: Int
        fileprivate let next: Int
        fileprivate var active: Bool
        var isActive: Bool { active }
    }
    enum Insertion { case accepted(Int), dominated(Int) }
    enum Failure: Error { case invalidInput, cancelled, resourceLimit }
    struct Limits {
        var maximumLabels = 65_536
        var pageCapacity = 128
        var bucketCount = 4096
        var maximumPayloadBytes = 16 * 1024 * 1024
    }
    private let limits: Limits
    private let cancelled: () -> Bool
    private var buckets: [Int]
    private var pages: [UnsafeMutablePointer<Label>?]
    private(set) var count = 0
    private(set) var activeCount = 0
    private(set) var allocatedRowBytes = 0
    let metadataCapacityBytes: Int
    var accountedPayloadBytes: Int { metadataCapacityBytes + allocatedRowBytes }

    init(limits: Limits = Limits(), cancelled: @escaping () -> Bool = { false }) throws {
        guard limits.maximumLabels > 0, limits.maximumLabels <= 1_048_576,
              limits.pageCapacity > 0, limits.pageCapacity <= 1024,
              limits.bucketCount > 0, limits.bucketCount <= 65_536,
              limits.maximumPayloadBytes > 0 else { throw Failure.invalidInput }
        let pageCount = (limits.maximumLabels - 1) / limits.pageCapacity + 1
        let nominalMetadata = limits.bucketCount * MemoryLayout<Int>.stride
            + pageCount * MemoryLayout<UnsafeMutablePointer<Label>?>.stride
        guard nominalMetadata <= limits.maximumPayloadBytes else { throw Failure.resourceLimit }
        buckets = Array(repeating: -1, count: limits.bucketCount)
        pages = Array(repeating: nil, count: pageCount)
        metadataCapacityBytes = buckets.capacity * MemoryLayout<Int>.stride
            + pages.capacity * MemoryLayout<UnsafeMutablePointer<Label>?>.stride
        guard metadataCapacityBytes <= limits.maximumPayloadBytes else { throw Failure.resourceLimit }
        self.limits = limits; self.cancelled = cancelled
    }
    deinit {
        for (index, page) in pages.enumerated() {
            guard let page else { continue }
            let initialized = max(0, min(limits.pageCapacity, count - index * limits.pageCapacity))
            page.deinitialize(count: initialized); page.deallocate()
        }
    }
    private func pointer(_ id: Int) -> UnsafeMutablePointer<Label> {
        pages[id / limits.pageCapacity]!.advanced(by: id % limits.pageCapacity)
    }
    func label(_ id: Int) throws -> Label {
        guard id >= 0, id < count else { throw Failure.invalidInput }
        return pointer(id).pointee
    }
    func insert(arrival: Arrival, history: Int, cost: Double, meters: Double,
                predecessor: Int = -1) throws -> Insertion {
        guard history >= 0, cost.isFinite, cost >= 0, meters.isFinite, meters >= 0,
              predecessor == -1 || (predecessor >= 0 && predecessor < count) else { throw Failure.invalidInput }
        if cancelled() { throw Failure.cancelled }
        var hasher = Hasher(); hasher.combine(arrival); hasher.combine(history)
        let bucket = Int(UInt(bitPattern: hasher.finalize()) % UInt(buckets.count))
        var scan = buckets[bucket], examined = 0
        while scan >= 0 {
            if examined & 255 == 0, cancelled() { throw Failure.cancelled }
            let row = pointer(scan).pointee
            if row.active, row.arrival == arrival, row.history == history,
               row.cost <= cost, row.meters <= meters { return .dominated(scan) }
            scan = row.next; examined += 1
        }
        guard count < limits.maximumLabels else { throw Failure.resourceLimit }
        let page = count / limits.pageCapacity
        if pages[page] == nil {
            let capacity = min(limits.pageCapacity, limits.maximumLabels - page * limits.pageCapacity)
            let bytes = capacity * MemoryLayout<Label>.stride
            guard bytes <= limits.maximumPayloadBytes - accountedPayloadBytes else { throw Failure.resourceLimit }
            pages[page] = .allocate(capacity: capacity)
            allocatedRowBytes += bytes
        }
        if cancelled() { throw Failure.cancelled }
        // Commit has no throwing work. IDs and predecessor rows remain stable,
        // including inactive rows still needed to reconstruct descendants.
        let id = count
        pointer(id).initialize(to: Label(arrival: arrival, history: history, cost: cost,
            meters: meters, predecessor: predecessor, next: buckets[bucket], active: true))
        count += 1; activeCount += 1
        scan = buckets[bucket]
        while scan >= 0 {
            let row = pointer(scan).pointee
            if row.active, row.arrival == arrival, row.history == history,
               cost <= row.cost, meters <= row.meters {
                pointer(scan).pointee.active = false; activeCount -= 1
            }
            scan = row.next
        }
        buckets[bucket] = id
        return .accepted(id)
    }
}
