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
    // Four fixed cache slots alias existing pages; they never allocate or retain
    // extra label payload beyond the owning page directory. Negative entries
    // are replaced immediately when their page is created.
    private var cached0: (key: Int, page: Page?) = (-1, nil)
    private var cached1: (key: Int, page: Page?) = (-1, nil)
    private var cached2: (key: Int, page: Page?) = (-1, nil)
    private var cached3: (key: Int, page: Page?) = (-1, nil)
    private let pageShift: Int
    private(set) var allocationRevision = 0
    private var allocatedLabelCapacity = 0
    private var allocatedPayloadBytes = 0

    init(stateCount: Int, maxPayloadBytes: Int, pageCapacity: Int = 256,
         shouldStop: @escaping () -> Bool = { false }) throws {
        guard stateCount >= 0, maxPayloadBytes >= 0, pageCapacity > 0,
              pageCapacity <= Int.max / MemoryLayout<Label>.stride else {
            throw StorageError.invalidConfiguration
        }
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
            guard let page = self.page(for: pageKey(state)) else { return Label() }
            return page.values[pageOffset(state)]
        }
    }

    @inline(__always) private func pageKey(_ state: Int) -> Int {
        pageShift >= 0 ? state >> pageShift : state / pageCapacity
    }

    @inline(__always) private func pageOffset(_ state: Int) -> Int {
        pageShift >= 0 ? state & (pageCapacity - 1) : state % pageCapacity
    }

    @inline(__always) private func page(for key: Int) -> Page? {
        switch key & 3 {
        case 0: if cached0.key == key { return cached0.page }
        case 1: if cached1.key == key { return cached1.page }
        case 2: if cached2.key == key { return cached2.page }
        default: if cached3.key == key { return cached3.page }
        }
        let found = pages[key]
        remember(key, page: found)
        return found
    }

    @inline(__always) private func remember(_ key: Int, page: Page?) {
        switch key & 3 {
        case 0: cached0 = (key, page)
        case 1: cached1 = (key, page)
        case 2: cached2 = (key, page)
        default: cached3 = (key, page)
        }
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
        if let existing = self.page(for: key) {
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
        body(&page.values[pageOffset(state)])
    }

    var statistics: Statistics {
        Statistics(
            allocatedPages: pages.count,
            allocatedLabelCapacity: allocatedLabelCapacity,
            allocatedPayloadBytes: allocatedPayloadBytes,
            maximumPayloadBytes: maximumPayloadBytes,
            maximumPages: maximumPages,
            logicalPageDirectoryEntryBytes: pages.count * (MemoryLayout<Int>.stride + MemoryLayout<Page>.stride),
            logicalLookupCacheBytes: 4 * MemoryLayout<(Int, Page?)>.stride
        )
    }
}
