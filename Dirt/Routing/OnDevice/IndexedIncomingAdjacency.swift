import Foundation

/// Optional exact incoming-arc access. This never computes a route or treats
/// incomplete work as disconnected. Confined to one synchronous bounds query.
nonisolated final class IndexedIncomingAdjacency {
    enum Failure: Error, Equatable { case incompleteIndex, invalidTopology, workLimit, memoryLimit }
    struct Incoming: Equatable { let source: Int; let edge: Int; let originalArc: Int }
    struct Limits {
        var maximumPayloadBytes = 512 * 1024
        var maximumCellArcs = 4096
        var maximumCachedCells = 4
        var maximumScannedEdges = 32768
        var maximumScannedArcs = 262144
    }
    struct Statistics {
        let livePayloadBytes: Int
        let peakPayloadBytes: Int
        let cachedCells: Int
    }
    private struct Row {
        let target: Int
        let arc: Incoming
    }
    private final class Budget {
        let maximum: Int
        var used = 0, peak = 0
        init(_ maximum: Int) { self.maximum = maximum }
        func reserve(_ bytes: Int) throws {
            guard bytes <= maximum - used else { throw Failure.memoryLimit }
            used += bytes; peak = max(peak,used)
        }
    }
    private final class Cell {
        let rows: UnsafeMutablePointer<Row>
        let capacity: Int, bytes: Int
        var count = 0
        let budget: Budget
        init(capacity: Int,budget: Budget) throws {
            self.capacity = capacity; self.budget = budget
            bytes = capacity * MemoryLayout<Row>.stride
            try budget.reserve(bytes)
            rows = .allocate(capacity: capacity)
        }
        func append(_ row: Row) throws {
            guard count < capacity else { throw Failure.workLimit }
            rows.advanced(by: count).initialize(to: row); count += 1
        }
        deinit { rows.deinitialize(count: count); rows.deallocate(); budget.used -= bytes }
    }
    private let pack: GraphV2Pack, index: ExactSnapIndex
    private let query: ExactSnapIndex.BoundsQuery
    private let limits: Limits, budget: Budget
    private let cancelled: () -> Bool
    private var cells: [UInt64: Cell] = [:]
    private var order: [UInt64] = []
    var statistics: Statistics { .init(livePayloadBytes: budget.used,peakPayloadBytes: budget.peak,cachedCells: cells.count) }

    init(pack: GraphV2Pack,index: ExactSnapIndex,query: ExactSnapIndex.BoundsQuery,
         limits: Limits = Limits(),cancelled: @escaping () -> Bool = { false }) throws {
        guard limits.maximumPayloadBytes >= 0, limits.maximumCellArcs > 0,
              limits.maximumCellArcs <= Int.max / MemoryLayout<Row>.stride,
              limits.maximumScannedEdges > 0, limits.maximumScannedArcs > 0,
              limits.maximumCachedCells > 0 else { throw Failure.memoryLimit }
        self.pack = pack; self.index = index; self.query = query
        self.limits = limits; self.cancelled = cancelled; budget = Budget(limits.maximumPayloadBytes)
        try validate()
    }
    private func validate() throws {
        guard !cancelled() else { throw RoutingPageError.cancelled }
        guard pack.exactSnapIndex === index else { throw ExactSnapIndex.Failure.identityMismatch }
        guard try index.hasCompleteEndpointCoverage(query: query) else { throw Failure.incompleteIndex }
    }
    private func key(_ node: Int) throws -> UInt64 {
        guard node >= 0,node < pack.nodeCount else { throw Failure.invalidTopology }
        return try ExactSnapIndex.key(ExactSnapIndex.cell(Double(pack.nodeCoords[node*2])),
            ExactSnapIndex.cell(Double(pack.nodeCoords[node*2+1])))
    }
    func removeCachedCells() { cells.removeAll(); order.removeAll() }
    func forEachIncoming(to node: Int,_ visit: (Incoming) throws -> Void) throws {
        try validate()
        let cellKey = try key(node)
        let cell: Cell
        if let cached = cells[cellKey] { cell = cached }
        else {
            let bytes = limits.maximumCellArcs * MemoryLayout<Row>.stride
            while (budget.used > budget.maximum - bytes || cells.count >= limits.maximumCachedCells), !order.isEmpty {
                cells.removeValue(forKey: order.removeFirst())
            }
            let prepared = try Cell(capacity: limits.maximumCellArcs,budget: budget)
            guard let from = pack.edgeFrom,let to = pack.edgeTo else { throw Failure.invalidTopology }
            var examined = 0, examinedArcs = 0
            try index.forEachEdge(nearLat: Double(pack.nodeCoords[node*2+1]),
                lon: Double(pack.nodeCoords[node*2]),radiusCells: 0,query: query,cancelled: cancelled) { edge in
                examined += 1
                guard examined <= limits.maximumScannedEdges else { throw Failure.workLimit }
                guard from.indices.contains(edge),to.indices.contains(edge) else { throw Failure.invalidTopology }
                let a = Int(from[edge]), b = Int(to[edge])
                func appendArcs(source: Int,target: Int) throws {
                    guard try key(target) == cellKey else { return }
                    guard source >= 0,source < pack.nodeCount else { throw Failure.invalidTopology }
                    let lo = Int(pack.nodeOffsets[source]),hi = Int(pack.nodeOffsets[source+1])
                    guard lo >= 0,hi >= lo,hi <= pack.edgeTargets.count else { throw Failure.invalidTopology }
                    for ordinal in lo..<hi {
                        examinedArcs += 1
                        guard examinedArcs <= limits.maximumScannedArcs else { throw Failure.workLimit }
                        if ordinal & 255 == 0, cancelled() { throw RoutingPageError.cancelled }
                        if Int(pack.edgeTargets[ordinal]) == target,Int(pack.edgeUndirectedIndex[ordinal]) == edge {
                            try prepared.append(.init(target: target,arc: .init(source: source,edge: edge,originalArc: ordinal)))
                        }
                    }
                }
                try appendArcs(source: a,target: b)
                if a != b { try appendArcs(source: b,target: a) }
            }
            try validate()
            var buffer = UnsafeMutableBufferPointer<Row>(start: prepared.rows, count: prepared.count)
            buffer.sort { (left: Row, right: Row) -> Bool in
                if left.target == right.target { return left.arc.originalArc < right.arc.originalArc }
                return left.target < right.target
            }
            cells[cellKey] = prepared; order.append(cellKey); cell = prepared
        }
        var low = 0, high = cell.count
        while low < high {
            let middle = low + (high-low)/2
            if cell.rows[middle].target < node { low = middle+1 } else { high = middle }
        }
        while low < cell.count, cell.rows[low].target == node {
            guard !cancelled() else { throw RoutingPageError.cancelled }
            try visit(cell.rows[low].arc); low += 1
        }
        try validate()
        // The outer withBoundsQuery still must close before any result is committed.
    }
}
