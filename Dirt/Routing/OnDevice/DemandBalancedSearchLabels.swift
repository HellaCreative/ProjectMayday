import Foundation

/// Separate ratio-search label layout; single-objective labels keep their smaller stride.
/// Storage is addressed by existing turn-state × bucket IDs. Reads
/// of untouched states return the exact dense-array defaults without allocating.
/// This bounds label payload, not graph/geometry residency or total process RSS.
/// Confined to its owning synchronous search; deliberately not Sendable.
nonisolated final class DemandBalancedSearchLabels {
    struct Label: Equatable {
        var cost: Double = .infinity
        var pathMeters: Double = .infinity
        var dirtMeters: Double = 0
        var predecessor: Int = -1
        var predecessorData: Int = -1
        var predecessorKind: UInt8 = 0
        var forward: Bool = true
        var slots: UInt8 = 0
    }

    enum StorageError: Error, Equatable {
        case invalidConfiguration
        case invalidState(Int)
        case memoryLimit
        case cancelled
    }

    struct Statistics: Equatable {
        let allocatedPages: Int
        let allocatedLabelCapacity: Int
        /// Labels with finite search costs, not padded untouched page slots.
        let finiteLabels: Int
        /// Includes struct padding, using MemoryLayout<Label>.stride.
        let allocatedPayloadBytes: Int
        let maximumPayloadBytes: Int
        let maximumPages: Int
        /// Logical live dictionary key/reference bytes only; Swift hash-table
        /// buckets, object headers and allocator rounding are additional. Observe
        /// those with RoutingMeasurement; never label this value total memory.
        let logicalPageDirectoryEntryBytes: Int
        let logicalLookupCacheBytes: Int
    }

    private final class Page {
        let values: UnsafeMutablePointer<Label>
        let count: Int

        init(count: Int) {
            self.count = count
            values = .allocate(capacity: count)
            values.initialize(repeating: Label(), count: count)
        }

        deinit {
            values.deinitialize(count: count)
            values.deallocate()
        }
    }

    let stateCount: Int
    let pageCapacity: Int
    let maximumPayloadBytes: Int
    let maximumPages: Int
    private let shouldStop: () -> Bool
    private var pages: [Int: Page] = [:]
    // Non-owning aliases into directory-owned immutable-lifetime pages. No
    // Page reference or pointer escapes a getter. The owning synchronous search
    // never removes a page before this store is destroyed.
    private struct ReadSlot {
        var key: Int = -1
        var values: UnsafeMutablePointer<Label>? = nil
    }
    private let readSlotCount: Int
    private let readSlots: UnsafeMutablePointer<ReadSlot>
    private let useReadPointerCache: Bool
    private let pageShift: Int
    private(set) var allocationRevision = 0
    private var allocatedLabelCapacity = 0
    private var finiteLabels = 0
    private var allocatedPayloadBytes = 0

    init(stateCount: Int, maxPayloadBytes: Int, pageCapacity: Int = 256,
         useReadPointerCache: Bool = true, readCacheSlots: Int = 256,
         shouldStop: @escaping () -> Bool = { false }) throws {
        guard stateCount >= 0, maxPayloadBytes >= 0, pageCapacity > 0,
              pageCapacity <= Int.max / MemoryLayout<Label>.stride else {
            throw StorageError.invalidConfiguration
        }
        // Fixed metadata bound independent of graph/state counts. Qualification
        // may compare 256 slots (4 KiB) with4096 slots (64 KiB).
        guard readCacheSlots > 0, readCacheSlots <= 4096,
              readCacheSlots.nonzeroBitCount == 1,
              readCacheSlots * MemoryLayout<ReadSlot>.stride <= 65_536 else {
            throw StorageError.invalidConfiguration
        }
        readSlotCount = readCacheSlots
        readSlots = .allocate(capacity: readCacheSlots)
        readSlots.initialize(repeating: ReadSlot(), count: readCacheSlots)
        self.useReadPointerCache = useReadPointerCache
        self.stateCount = stateCount
        self.pageCapacity = pageCapacity
        pageShift = pageCapacity.nonzeroBitCount == 1 ? pageCapacity.trailingZeroBitCount : -1
        maximumPayloadBytes = maxPayloadBytes
        self.shouldStop = shouldStop
        let fullPageBytes = pageCapacity * MemoryLayout<Label>.stride
        let logicalPages = stateCount / pageCapacity + (stateCount % pageCapacity == 0 ? 0 : 1)
        // At most one shortened final page exists. It may fit where a full
        // page does not. The payload check below always charges its exact size.
        let boundedFullPages = maxPayloadBytes / fullPageBytes
        let shortenedPageAllowance = stateCount % pageCapacity == 0 ? 0 : 1
        maximumPages = min(logicalPages, boundedFullPages + shortenedPageAllowance)
    }

    subscript(state: Int) -> Label {
        @inline(__always) get {
            precondition(state >= 0 && state < stateCount, "Invalid routing label state")
            guard let values = readValues(for: pageKey(state)) else { return Label() }
            return values[pageOffset(state)]
        }
    }

    @inline(__always) private func pageKey(_ state: Int) -> Int {
        pageShift >= 0 ? state >> pageShift : state / pageCapacity
    }

    @inline(__always) private func pageOffset(_ state: Int) -> Int {
        pageShift >= 0 ? state & (pageCapacity - 1) : state % pageCapacity
    }

    deinit {
        readSlots.deinitialize(count: readSlotCount)
        readSlots.deallocate()
        // Dictionary-owned Page objects release their label payload afterward.
    }

    @inline(__always) private func readValues(for key: Int) -> UnsafeMutablePointer<Label>? {
        guard useReadPointerCache else { return pages[key]?.values }
        let slot = key & (readSlotCount - 1)
        if readSlots[slot].key == key { return readSlots[slot].values }
        let values = pages[key]?.values
        readSlots[slot] = ReadSlot(key: key, values: values)
        return values
    }

    @inline(__always) private func remember(_ key: Int, page: Page) {
        readSlots[key & (readSlotCount - 1)] = ReadSlot(key: key, values: page.values)
    }

    /// The caller should invoke this only for accepted relaxations. Exhausting
    /// the payload budget throws before modifying any label or allocating a page.
    /// Map memoryLimit to searchLimit, never noPath. A cancelled mutation leaves
    /// the existing label untouched. Neither outcome establishes disconnection.
    func mutate(_ state: Int, _ body: (inout Label) -> Void) throws {
        guard state >= 0 && state < stateCount else { throw StorageError.invalidState(state) }
        guard !shouldStop() else { throw StorageError.cancelled }
        let key = pageKey(state)
        let page: Page
        if let existing = pages[key] {
            page = existing
        } else {
            let first = state - pageOffset(state)
            let capacity = min(pageCapacity, stateCount - first)
            let requiredBytes = capacity * MemoryLayout<Label>.stride
            guard pages.count < maximumPages,
                  requiredBytes <= maximumPayloadBytes - allocatedPayloadBytes else {
                throw StorageError.memoryLimit
            }
            page = Page(count: capacity)
            pages[key] = page
            remember(key, page: page)
            allocationRevision += 1
            allocatedLabelCapacity += capacity
            allocatedPayloadBytes += requiredBytes
        }
        let offset = pageOffset(state)
        let wasFinite = page.values[offset].cost.isFinite
        body(&page.values[offset])
        let isFinite = page.values[offset].cost.isFinite
        if isFinite != wasFinite { finiteLabels += isFinite ? 1 : -1 }
    }

    var statistics: Statistics {
        Statistics(
            allocatedPages: pages.count,
            allocatedLabelCapacity: allocatedLabelCapacity,
            finiteLabels: finiteLabels,
            allocatedPayloadBytes: allocatedPayloadBytes,
            maximumPayloadBytes: maximumPayloadBytes,
            maximumPages: maximumPages,
            logicalPageDirectoryEntryBytes: pages.count * (MemoryLayout<Int>.stride + MemoryLayout<Page>.stride),
            logicalLookupCacheBytes: readSlotCount * MemoryLayout<ReadSlot>.stride
        )
    }
}
