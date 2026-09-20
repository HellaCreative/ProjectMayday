import Foundation

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
        var remaining = Array(repeating: Double.infinity, count: count)
        var heap = BinaryHeap<(Int, Double)> { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        func seed(_ node: Int, _ meters: Double) {
            guard node >= 0, node < count, meters < remaining[node] else { return }
            remaining[node] = meters
            heap.push((node, meters))
        }
        let length = pack.distance(end.edge)
        let along = max(0, min(length, end.alongMeters))
        seed(pack.endpoint(end.edge, from: true), along)
        seed(pack.endpoint(end.edge, from: false), max(0, length - along))
        var pops = 0
        while let current = heap.pop() {
            if pops & 255 == 0 { try budget.check() }
            pops += 1
            if current.1 != remaining[current.0] { continue }
            if current.1 > maxRemaining { continue }
            for slot in Int(arcs.inStart[current.0])..<Int(arcs.inStart[current.0 + 1]) {
                let arc = Int(arcs.inArcs[slot])
                if avoidFerries && pack.structure(Int(arcs.outEdge[arc])) == "ferry" { continue }
                let from = arcs.source(arc), meters = arcs.distance(arc)
                guard meters.isFinite, meters >= 0 else { continue }
                let candidate = current.1 + meters
                if candidate < remaining[from] {
                    remaining[from] = candidate
                    heap.push((from, candidate))
                }
            }
        }
        return .init(remaining: remaining)
    }
}
