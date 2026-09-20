import Foundation

/// Concrete min-heap for the reverse distance field. This loop processes
/// millions of entries on dense regional windows; keeping the comparison
/// statically dispatched avoids the generic closure call on every sift step.
private struct CompassHeap {
    struct Entry {
        let node: Int32
        let meters: Double
    }
    private var values: [Entry] = []
    private static func before(_ a: Entry, _ b: Entry) -> Bool {
        a.meters == b.meters ? a.node < b.node : a.meters < b.meters
    }
    mutating func push(node: Int, meters: Double) {
        let value = Entry(node: Int32(node), meters: meters)
        values.append(value)
        var index = values.count - 1
        while index > 0 {
            let parent = (index - 1) >> 1
            if !Self.before(values[index], values[parent]) { break }
            values.swapAt(index, parent)
            index = parent
        }
    }
    mutating func pop() -> Entry? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let first = values[0]
        values[0] = values.removeLast()
        var index = 0
        while (index << 1) + 1 < values.count {
            let left = (index << 1) + 1, right = left + 1
            let best = right < values.count && Self.before(values[right], values[left]) ? right : left
            if !Self.before(values[best], values[index]) { break }
            values.swapAt(best, index)
            index = best
        }
        return first
    }
}

/// Reuses recent destination remaining tables across corridor, endpoint and fuel
/// passes, matching JS `roadCompassCache`. Keys must identify the graph as well as
/// the destination, because one store outlives a change of prepared regions.
public final class RoadCompassStore: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [(key: String, remaining: [Double])] = []
    public init(capacity: Int = 4) { self.capacity = max(1, capacity) }
    func remaining(for key: String, build: () throws -> [Double]) rethrows -> [Double] {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let hit = entries.remove(at: index)
            entries.append(hit)
            lock.unlock()
            return hit.remaining
        }
        lock.unlock()
        let built = try build()
        lock.lock(); defer { lock.unlock() }
        entries.append((key, built))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return built
    }
}

/// Remaining legal road meters from each graph node to the destination pin.
/// Port of `scripts/pack-fabric/routing/lib/road-compass.js`, using graph nodes
/// rather than expanded turn states. Coordinates never participate.
public struct RoadCompass: Sendable {
    public let remaining: [Double]

    public subscript(node: Int) -> Double {
        guard node >= 0, node < remaining.count else { return .infinity }
        return remaining[node]
    }

    public static func toward(end: RoadMatch, pack: any RoadGraph,
                              budget: ComputationBudget,
                              maxRemaining: Double = .infinity, avoidFerries: Bool = false) throws -> RoadCompass {
        let count = pack.nodeCount
        let arcs: ArcIndex
        if let indexed = pack as? IndexedGraph {
            arcs = try indexed.arcIndex(budget: budget)
        } else if let raw = pack as? GraphPack {
            arcs = try ArcIndex(pack: raw, budget: budget)
        } else {
            arcs = try ArcIndex(nodeCount: count, budget: budget) { node in
                pack.outgoing(node).map { arc in
                    RoadArc(target: arc.target, edge: arc.edge, forward: arc.forward,
                            meters: pack.distance(arc.edge))
                }
            }
        }
        guard count < Int(Int32.max) else { throw RoutingFailure.resourceLimit("road compass") }
        var remaining = Array(repeating: Double.infinity, count: count)
        var heap = CompassHeap()
        func seed(_ node: Int, _ meters: Double) {
            guard node >= 0, node < count, meters < remaining[node] else { return }
            remaining[node] = meters
            heap.push(node: node, meters: meters)
        }
        let length = pack.distance(end.edge)
        let along = max(0, min(length, end.alongMeters))
        seed(pack.endpoint(end.edge, from: true), along)
        seed(pack.endpoint(end.edge, from: false), max(0, length - along))
        var pops = 0
        while let current = heap.pop() {
            if pops & 255 == 0 { try budget.check() }
            pops += 1
            let node = Int(current.node)
            if current.meters != remaining[node] { continue }
            if current.meters > maxRemaining { continue }
            for slot in Int(arcs.inStart[node])..<Int(arcs.inStart[node + 1]) {
                let arc = Int(arcs.inArcs[slot])
                if avoidFerries && pack.structure(Int(arcs.outEdge[arc])) == "ferry" { continue }
                let from = arcs.source(arc), meters = arcs.distance(arc)
                guard meters.isFinite, meters >= 0 else { continue }
                let candidate = current.meters + meters
                if candidate < remaining[from] {
                    remaining[from] = candidate
                    heap.push(node: from, meters: candidate)
                }
            }
        }
        return .init(remaining: remaining)
    }
}
