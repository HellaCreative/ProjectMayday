import Foundation

/// One exact integer column, borrowed from pack bytes or owned for a joined graph.
enum IndexColumn: Sendable {
    case mapped(MappedColumn<Int32>)
    case owned([Int32])
    case compact(CompactArcColumn)
    var count: Int {
        switch self { case .mapped(let data): data.count; case .owned(let data): data.count; case .compact(let data): data.count }
    }
    var ownedBytes: Int {
        switch self { case .mapped: 0; case .owned(let data): data.count * MemoryLayout<Int32>.stride; case .compact(let data): data.ownedBytes }
    }
    subscript(_ index: Int) -> Int32 {
        switch self { case .mapped(let data): data[index]; case .owned(let data): data[index]; case .compact(let data): data[index] }
    }
}

/// Directed arcs in source order, with an exact reverse lookup. A raw pack
/// lends its mapped forward columns; joined graphs own their composed columns.
struct ArcIndex: Sendable {
    let outStart: IndexColumn
    let outSource: CompactArcColumn
    let outEdge: IndexColumn
    let inStart: [Int32]
    let inArcs: CompactArcColumn
    let targets: IndexColumn
    let forwards: [Bool]
    let meters: [Double]
    private let mapped: GraphPack?
    private let distanceGraph: RegionalGraph?

    /// Borrow the already validated adjacency columns. Only the reverse lookup
    /// needs storage; source, direction and length are exact edge-column reads.
    init(pack: GraphPack, budget: ComputationBudget) throws {
        try budget.check()
        mapped = pack
        distanceGraph = nil
        outStart = .mapped(pack.nodeOffsets)
        outEdge = .mapped(pack.arcEdges)
        targets = .mapped(pack.targets)
        outSource = .init(); forwards = []; meters = []
        var starts = [Int32](repeating: 0, count: pack.nodeCount + 1)
        for arc in 0..<pack.arcCount {
            if arc & 4095 == 0 { try budget.check() }
            starts[Int(pack.targets[arc]) + 1] += 1
        }
        for node in 0..<pack.nodeCount { starts[node + 1] += starts[node] }
        var fill = starts
        var incoming = CompactArcColumn(repeating: 0, count: pack.arcCount, maximumValue: Int32(pack.arcCount))
        for arc in 0..<pack.arcCount {
            if arc & 4095 == 0 { try budget.check() }
            let target = Int(pack.targets[arc])
            incoming[Int(fill[target])] = Int32(arc)
            fill[target] += 1
        }
        inStart = starts; inArcs = incoming
        try budget.check()
    }

    func source(_ arc: Int) -> Int {
        guard let pack = mapped else { return Int(outSource[arc]) }
        let edge = Int(pack.arcEdges[arc]), target = pack.targets[arc]
        return Int(pack.edgeTo[edge] == target ? pack.edgeFrom[edge] : pack.edgeTo[edge])
    }
    func forward(_ arc: Int) -> Bool {
        guard let pack = mapped else { return forwards[arc] }
        return pack.edgeFrom[Int(pack.arcEdges[arc])] == source(arc)
    }
    func distance(_ arc: Int) -> Double {
        if let distanceGraph { return distanceGraph.distance(Int(outEdge[arc])) }
        guard let pack = mapped else { return meters[arc] }
        return Double(pack.meters[Int(pack.arcEdges[arc])])
    }
    var ownedAdjacencyBytes: Int {
        outStart.ownedBytes + outEdge.ownedBytes + targets.ownedBytes
            + outSource.ownedBytes
            + forwards.count * MemoryLayout<Bool>.stride
            + meters.count * MemoryLayout<Double>.stride
    }

    init(nodeCount: Int, arcCapacity: Int? = nil, budget: ComputationBudget, outgoing: (Int) -> [RoadArc]) throws {
        try self.init(nodeCount: nodeCount, arcCapacity: arcCapacity, distanceGraph: nil,
                      budget: budget, outgoing: outgoing)
    }

    /// A joined arc retains the original edge identity, whose mapped distance
    /// already exists. Borrow it instead of copying a Double for every directed
    /// arc (including the extra arcs exposed at seam aliases).
    init(regional: RegionalGraph, budget: ComputationBudget) throws {
        try self.init(nodeCount: regional.nodeCount, arcCapacity: regional.adjacencyCount(budget: budget),
                      distanceGraph: regional, budget: budget, outgoing: regional.outgoing)
    }

    private init(nodeCount: Int, arcCapacity: Int?, distanceGraph: RegionalGraph?,
                 budget: ComputationBudget, outgoing: (Int) -> [RoadArc]) throws {
        mapped = nil
        self.distanceGraph = distanceGraph
        // Do not walk and materialize every outgoing list just to count it;
        // append in source order and grow the compact buffers as needed.
        guard nodeCount < Int(Int32.max) else { throw RoutingFailure.resourceLimit("arc index") }
        let arcCount = max(0, arcCapacity ?? nodeCount)
        var outStart = [Int32](repeating: 0, count: nodeCount + 1)
        var outSource = CompactArcColumn(), outEdge = CompactArcColumn(), targets = CompactArcColumn()
        outSource.reserveCapacity(arcCount); outEdge.reserveCapacity(arcCount); targets.reserveCapacity(arcCount)
        var forwards: [Bool] = [], meters: [Double] = []
        forwards.reserveCapacity(arcCount)
        if distanceGraph == nil { meters.reserveCapacity(arcCount) }
        var inStart = [Int32](repeating: 0, count: nodeCount + 1)
        for node in 0..<nodeCount {
            if node & 4095 == 0 { try budget.check() }
            for arc in outgoing(node) {
                let target = arc.target >= 0 && arc.target < nodeCount ? arc.target : -1
                outSource.append(Int32(node)); outEdge.append(Int32(arc.edge)); targets.append(Int32(target))
                forwards.append(arc.forward)
                if distanceGraph == nil { meters.append(arc.meters) }
                if target >= 0 { inStart[target + 1] += 1 }
            }
            guard outSource.count < Int(Int32.max) else { throw RoutingFailure.resourceLimit("arc index") }
            outStart[node + 1] = Int32(outSource.count)
        }
        for node in 0..<nodeCount { inStart[node + 1] += inStart[node] }
        var fill = inStart
        var inArcs = CompactArcColumn(repeating: 0, count: Int(inStart[nodeCount]), maximumValue: Int32(outSource.count))
        for arc in targets.indices where targets[arc] >= 0 {
            let target = Int(targets[arc])
            inArcs[Int(fill[target])] = Int32(arc)
            fill[target] += 1
        }
        self.outStart = .owned(outStart); self.outSource = outSource; self.outEdge = .compact(outEdge)
        self.inStart = inStart; self.inArcs = inArcs
        self.targets = .compact(targets); self.forwards = forwards; self.meters = meters
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
    private var strict: ComponentIDs?
    private var allow: ComponentIDs?
    func ids(allowUnknown: Bool, build: () throws -> ComponentIDs) rethrows -> ComponentIDs {
        lock.lock(); defer { lock.unlock() }
        if allowUnknown {
            if let allow { return allow }
            let built = try build()
            allow = built
            return built
        }
        if let strict { return strict }
        let built = try build()
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
    private struct Marks { let arrival: ReachabilityMarks; let free: ReachabilityMarks }
    private var cache: [EndKey: Marks] = [:]
    private struct StartKey: Hashable { let edge: Int; let direction: Int8 }
    private struct ForwardKey: Hashable { let starts: [StartKey] }
    private var forwardCache: [ForwardKey: Marks] = [:]

    init(graph: any RoadGraph, budget: ComputationBudget,
         permitsThrough: @escaping (Int) -> Bool = { _ in true }) throws {
        self.graph = graph
        self.permitsThrough = permitsThrough
        if let indexed = graph as? IndexedGraph {
            arcs = try indexed.arcIndex(budget: budget)
        } else if let pack = graph as? GraphPack {
            arcs = try ArcIndex(pack: pack, budget: budget)
        } else {
            arcs = try ArcIndex(nodeCount: graph.nodeCount, budget: budget) { graph.outgoing($0) }
        }
    }

    /// A negative result proves disconnection; a positive result still needs
    /// the legal turn-aware search. Expand the smaller frontier so a nearby
    /// destination or a small cut-off component does not flood an entire region.
    /// Ignoring arrival restrictions and U-turns makes this deliberately optimistic.
    func mayConnectBidirectionally(start: RoadMatch, end: RoadMatch,
                                   budget: ComputationBudget) throws -> Bool {
        if start.edge == end.edge { return true }
        var marks = [UInt8](repeating: 0, count: graph.nodeCount)
        var permission = [UInt8](repeating: 0, count: graph.edgeCount)
        var forward: [Int32] = [], reverse: [Int32] = []
        func seed(_ node: Int, side: UInt8, into frontier: inout [Int32]) -> Bool {
            guard node >= 0 && node < marks.count else { return false }
            if marks[node] & (3 ^ side) != 0 { return true }
            if marks[node] & side == 0 { marks[node] |= side; frontier.append(Int32(node)) }
            return false
        }
        if start.forward != true {
            _ = seed(graph.endpoint(start.edge, from: true), side: 1, into: &forward)
        }
        if start.forward != false {
            _ = seed(graph.endpoint(start.edge, from: false), side: 1, into: &forward)
        }
        if seed(graph.endpoint(end.edge, from: true), side: 2, into: &reverse)
            || seed(graph.endpoint(end.edge, from: false), side: 2, into: &reverse) { return true }
        func permits(_ edge: Int) -> Bool {
            if permission[edge] == 0 { permission[edge] = permitsThrough(edge) ? 2 : 1 }
            return permission[edge] == 2
        }
        var steps = 0
        while !forward.isEmpty && !reverse.isEmpty {
            try budget.check()
            let advancing = forward.count <= reverse.count
            let side: UInt8 = advancing ? 1 : 2
            let frontier = advancing ? forward : reverse
            var next: [Int32] = []
            for value in frontier {
                let node = Int(value)
                let range = advancing
                    ? Int(arcs.outStart[node])..<Int(arcs.outStart[node + 1])
                    : Int(arcs.inStart[node])..<Int(arcs.inStart[node + 1])
                for slot in range {
                    steps += 1
                    if steps & 4095 == 0 { try budget.check() }
                    let arc = advancing ? slot : Int(arcs.inArcs[slot])
                    let target = advancing ? Int(arcs.targets[arc]) : arcs.source(arc)
                    if permits(Int(arcs.outEdge[arc])), seed(target, side: side, into: &next) { return true }
                }
                for sibling in graph.coincidentSiblings(node) {
                    if seed(sibling, side: side, into: &next) { return true }
                }
            }
            if advancing { forward = next } else { reverse = next }
        }
        return false
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

    /// Answers the same question for a set of snap candidates while walking the
    /// graph once from the fixed origin. Staged seam screening calls this many
    /// times with the same origin and different border points; caching that one
    /// forward field avoids rebuilding a whole reverse field for every border
    /// road without changing which candidate pairs are considered connected.
    func mayConnectAny(starts: [RoadMatch], ends: [RoadMatch],
                       budget: ComputationBudget) throws -> Bool {
        guard !starts.isEmpty, !ends.isEmpty else { return false }
        for start in starts {
            for end in ends {
                if start.edge == end.edge {
                    let forward = start.alongMeters <= end.alongMeters
                    if start.forward != !forward { return true }
                }
                if startsAtDestinationJunction(start, end: end) { return true }
            }
        }
        let marks = try forwardMarks(from: starts, budget: budget)
        return ends.contains { canFinish($0, marks: marks) }
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

    private func startsAtDestinationJunction(_ start: RoadMatch, end: RoadMatch) -> Bool {
        guard start.edge != end.edge else { return false }
        let a = graph.endpoint(start.edge, from: true), b = graph.endpoint(start.edge, from: false)
        return (start.forward != true && finishes(a, end))
            || (start.forward != false && finishes(b, end))
    }

    private func canFinish(_ end: RoadMatch, marks: Marks) -> Bool {
        for node in [graph.endpoint(end.edge, from: true), graph.endpoint(end.edge, from: false)]
        where node >= 0 && node < graph.nodeCount {
            if marks.free[node] { return true }
            for slot in Int(arcs.inStart[node])..<Int(arcs.inStart[node + 1]) {
                let arc = Int(arcs.inArcs[slot])
                if Int(arcs.outEdge[arc]) != end.edge && marks.arrival[arc] { return true }
            }
        }
        return false
    }

    private func forwardMarks(from starts: [RoadMatch], budget: ComputationBudget) throws -> Marks {
        var unique = Set<StartKey>()
        for start in starts {
            let direction: Int8 = start.forward == true ? 1 : (start.forward == false ? -1 : 0)
            unique.insert(StartKey(edge: start.edge, direction: direction))
        }
        let keys = unique.sorted { a, b in
            a.edge == b.edge ? a.direction < b.direction : a.edge < b.edge
        }
        let key = ForwardKey(starts: keys)
        if let cached = forwardCache[key] { return cached }
        let nodeCount = graph.nodeCount
        var arrival = ReachabilityMarks(count: arcs.outEdge.count)
        var free = ReachabilityMarks(count: nodeCount)
        var arcQueue: [Int32] = [], nodeQueue: [Int32] = []
        func markArc(_ arc: Int) {
            let edge = Int(arcs.outEdge[arc])
            if !arrival[arc], permitsThrough(edge) {
                arrival[arc] = true; arcQueue.append(Int32(arc))
            }
        }
        func markFree(_ node: Int) {
            if !free[node] { free[node] = true; nodeQueue.append(Int32(node)) }
        }
        func continueFrom(_ node: Int, except edge: Int?) {
            guard node >= 0, node < nodeCount else { return }
            for arc in Int(arcs.outStart[node])..<Int(arcs.outStart[node + 1])
            where edge == nil || Int(arcs.outEdge[arc]) != edge! { markArc(arc) }
            for sibling in graph.coincidentSiblings(node)
            where sibling != node && sibling >= 0 && sibling < nodeCount { markFree(sibling) }
        }
        for start in starts {
            if start.forward != true {
                continueFrom(graph.endpoint(start.edge, from: true), except: start.edge)
            }
            if start.forward != false {
                continueFrom(graph.endpoint(start.edge, from: false), except: start.edge)
            }
        }
        var steps = 0
        while true {
            if let arc = arcQueue.popLast() {
                continueFrom(Int(arcs.targets[Int(arc)]), except: Int(arcs.outEdge[Int(arc)]))
            } else if let node = nodeQueue.popLast() {
                continueFrom(Int(node), except: nil)
            } else {
                break
            }
            steps += 1
            if steps & 4095 == 0 { try budget.check() }
        }
        let marks = Marks(arrival: arrival, free: free)
        forwardCache[key] = marks
        return marks
    }

    private func marks(for end: RoadMatch, budget: ComputationBudget) throws -> Marks {
        let key = EndKey(edge: end.edge)
        if let cached = cache[key] { return cached }
        let nodeCount = graph.nodeCount
        var arrival = ReachabilityMarks(count: arcs.outEdge.count)
        var free = ReachabilityMarks(count: nodeCount)
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
                let source = arcs.source(Int(arc))
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
