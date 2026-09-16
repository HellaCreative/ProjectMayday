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
                              maxRemaining: Double = .infinity) throws -> RoadCompass {
        let count = pack.nodeCount
        var incoming = Array(repeating: [(Int, Double)](), count: count)
        if let indexed = pack as? IndexedGraph {
            incoming = indexed.predecessors
        } else {
            for node in 0..<count {
                if node & 4095 == 0 { try budget.check() }
                for arc in pack.outgoing(node) {
                    let meters = pack.distance(arc.edge)
                    guard arc.target >= 0, arc.target < count, meters.isFinite, meters >= 0 else { continue }
                    incoming[arc.target].append((node, meters))
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
            for (from, meters) in incoming[current.0] {
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
