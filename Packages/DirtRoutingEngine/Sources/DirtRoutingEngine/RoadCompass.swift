import Foundation

/// Reuses one destination remaining table across corridor/fuel passes, matching
/// JS `roadCompassCache`.
public final class RoadCompassStore: @unchecked Sendable {
    private var key: String?
    private var remaining: [Double]?
    public init() {}
    func remaining(for key: String, build: () throws -> [Double]) rethrows -> [Double] {
        if self.key == key, let remaining { return remaining }
        let built = try build()
        self.key = key
        self.remaining = built
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
                              budget: ComputationBudget) throws -> RoadCompass {
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
