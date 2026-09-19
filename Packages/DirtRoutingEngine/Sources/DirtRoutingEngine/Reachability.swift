import Foundation

/// Directed arcs in flat arrays. Outgoing arc `k` of node `v` has id `outStart[v] + k`,
/// in the same order as `RoadGraph.outgoing(v)`; `inArcs` lists the ids arriving at each node.
struct ArcIndex: Sendable {
    let outStart: [Int32]
    let outSource: [Int32]
    let outEdge: [Int32]
    let inStart: [Int32]
    let inArcs: [Int32]
    let targets: [Int32]
    let forwards: [Bool]
    let meters: [Double]

    init(nodeCount: Int, budget: ComputationBudget, outgoing: (Int) -> [RoadArc]) throws {
        // Do not walk and materialize every outgoing list just to count it;
        // append in source order and grow the compact buffers as needed.
        guard nodeCount < Int(Int32.max) else { throw RoutingFailure.resourceLimit("arc index") }
        let arcCount = nodeCount
        var outStart = [Int32](repeating: 0, count: nodeCount + 1)
        var outSource: [Int32] = [], outEdge: [Int32] = [], targets: [Int32] = []
        outSource.reserveCapacity(arcCount); outEdge.reserveCapacity(arcCount); targets.reserveCapacity(arcCount)
        var forwards: [Bool] = [], meters: [Double] = []
        forwards.reserveCapacity(arcCount); meters.reserveCapacity(arcCount)
        var inStart = [Int32](repeating: 0, count: nodeCount + 1)
        for node in 0..<nodeCount {
            if node & 4095 == 0 { try budget.check() }
            for arc in outgoing(node) {
                let target = arc.target >= 0 && arc.target < nodeCount ? arc.target : -1
                outSource.append(Int32(node)); outEdge.append(Int32(arc.edge)); targets.append(Int32(target))
                forwards.append(arc.forward); meters.append(arc.meters)
                if target >= 0 { inStart[target + 1] += 1 }
            }
            guard outSource.count < Int(Int32.max) else { throw RoutingFailure.resourceLimit("arc index") }
            outStart[node + 1] = Int32(outSource.count)
        }
        for node in 0..<nodeCount { inStart[node + 1] += inStart[node] }
        var fill = inStart
        var inArcs = [Int32](repeating: 0, count: Int(inStart[nodeCount]))
        for arc in targets.indices where targets[arc] >= 0 {
            let target = Int(targets[arc])
            inArcs[Int(fill[target])] = Int32(arc)
            fill[target] += 1
        }
        self.outStart = outStart; self.outSource = outSource; self.outEdge = outEdge
        self.inStart = inStart; self.inArcs = inArcs
        self.targets = targets; self.forwards = forwards; self.meters = meters
    }
}

/// Builds an arc index the first time it is needed and shares it afterwards, so graphs
/// whose routes never need a reachability check pay no time or memory for one.
final class ArcIndexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var index: ArcIndex?
    func value(_ build: () throws -> ArcIndex) rethrows -> ArcIndex {
        lock.lock(); defer { lock.unlock() }
        if let index { return index }
        let built = try build()
        index = built
        return built
    }
}

/// Lazy weak-component tables: only the allowUnknown mode a request needs is built.
final class WeakComponentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var strict: [Int]?
    private var allow: [Int]?
    func ids(allowUnknown: Bool, build: () -> [Int]) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        if allowUnknown {
            if let allow { return allow }
            let built = build()
            allow = built
            return built
        }
        if let strict { return strict }
        let built = build()
        strict = built
        return built
    }
}

/// Answers whether a start match could possibly connect to an end match before a search
/// floods the network to prove it. It follows every directed road and coincident-node
/// transfer and enforces only the search's rule that a road is never taken straight back
/// the way it arrived; access, turn restrictions, corridors and distance limits are
/// ignored. It never rules out a pair the search could connect, and a pair it rules out
/// would only end in "no path".
final class EndpointReachability {
    private let graph: any RoadGraph
    private let arcs: ArcIndex
    private let permitsThrough: (Int) -> Bool
    private struct EndKey: Hashable { let edge: Int }
    /// `arrival[arc]`: the end is reachable after arriving along that arc.
    /// `free[node]`: reachable after a coincident-node transfer, when any road may follow.
    private struct Marks { let arrival: [Bool]; let free: [Bool] }
    private var cache: [EndKey: Marks] = [:]

    init(graph: any RoadGraph, budget: ComputationBudget,
         permitsThrough: @escaping (Int) -> Bool = { _ in true }) throws {
        self.graph = graph
        self.permitsThrough = permitsThrough
        if let indexed = graph as? IndexedGraph {
            arcs = try indexed.arcIndex(budget: budget)
        } else {
            arcs = try ArcIndex(nodeCount: graph.nodeCount, budget: budget) { graph.outgoing($0) }
        }
    }

    func mayConnect(start: RoadMatch, end: RoadMatch, budget: ComputationBudget) throws -> Bool {
        if start.edge == end.edge {
            // PathSearch adds a direct arc between two positions on one road.
            let forward = start.alongMeters <= end.alongMeters
            if start.forward != !forward { return true }
        }
        let marks = try marks(for: end, budget: budget)
        let a = graph.endpoint(start.edge, from: true), b = graph.endpoint(start.edge, from: false)
        if start.forward != true, canContinue(from: a, arrivedBy: start.edge, end: end, marks: marks) { return true }
        if start.forward != false, canContinue(from: b, arrivedBy: start.edge, end: end, marks: marks) { return true }
        return false
    }

    /// Arrival may use either direction of the destination road.
    private func finishes(_ node: Int, _ end: RoadMatch) -> Bool {
        node == graph.endpoint(end.edge, from: true) || node == graph.endpoint(end.edge, from: false)
    }

    private func canContinue(from node: Int, arrivedBy edge: Int, end: RoadMatch, marks: Marks) -> Bool {
        guard node >= 0, node < graph.nodeCount else { return false }
        if edge != end.edge, finishes(node, end) { return true }
        for arc in Int(arcs.outStart[node])..<Int(arcs.outStart[node + 1])
        where Int(arcs.outEdge[arc]) != edge && marks.arrival[arc] { return true }
        for sibling in graph.coincidentSiblings(node)
        where sibling != node && sibling >= 0 && sibling < graph.nodeCount && marks.free[sibling] { return true }
        return false
    }

    private func marks(for end: RoadMatch, budget: ComputationBudget) throws -> Marks {
        let key = EndKey(edge: end.edge)
        if let cached = cache[key] { return cached }
        let nodeCount = graph.nodeCount
        var arrival = [Bool](repeating: false, count: arcs.outEdge.count)
        var free = [Bool](repeating: false, count: nodeCount)
        var arcQueue: [Int32] = [], nodeQueue: [Int32] = []
        func markFree(_ node: Int) {
            if !free[node] { free[node] = true; nodeQueue.append(Int32(node)) }
        }
        func markArrivals(at node: Int, except edge: Int?) {
            for slot in Int(arcs.inStart[node])..<Int(arcs.inStart[node + 1]) {
                let arc = Int(arcs.inArcs[slot])
                let incoming = Int(arcs.outEdge[arc])
                if !arrival[arc], incoming != edge, permitsThrough(incoming) {
                    arrival[arc] = true; arcQueue.append(Int32(arc))
                }
            }
        }
        for node in [graph.endpoint(end.edge, from: true), graph.endpoint(end.edge, from: false)]
        where node >= 0 && node < nodeCount {
            markFree(node)
            markArrivals(at: node, except: end.edge)
        }
        var steps = 0
        while true {
            if let arc = arcQueue.popLast() {
                // Taking `arc` out of its source continues toward the end.
                let source = Int(arcs.outSource[Int(arc)])
                markFree(source)
                markArrivals(at: source, except: Int(arcs.outEdge[Int(arc)]))
            } else if let node = nodeQueue.popLast() {
                // Any state at a coincident node can transfer here.
                for sibling in graph.coincidentSiblings(Int(node))
                where sibling != Int(node) && sibling >= 0 && sibling < nodeCount {
                    markFree(sibling)
                    markArrivals(at: sibling, except: nil)
                }
            } else {
                break
            }
            steps += 1
            if steps & 4095 == 0 { try budget.check() }
        }
        let marks = Marks(arrival: arrival, free: free)
        cache[key] = marks
        return marks
    }
}
