import Foundation

/// Optional relaxed range proof. Complete means only complete within maximumMeters
/// in the supplied verified topology. No route, turn, fuel, or global no-path proof.
nonisolated final class BoundedForwardFuelField {
    struct Node: Hashable { let pack: Int; let local: Int }
    struct Seed { let node: Node; let meters: Double }
    struct Limits {
        var states = 32_768
        var queueEntries = 65_536
        var examinedArcs = 2_000_000
        var payloadBytes = 8 * 1024 * 1024
    }
    enum Failure: Error { case invalidInput, resourceLimit }
    private struct Label { var node = Node(pack: -1,local: -1); var meters = Double.infinity }
    private struct Item { let node: Node; let meters: Double }
    private var labels: [Label]
    private var queue: [Item]
    private var queueCount = 0
    private(set) var stateCount = 0
    private let limits: Limits
    let allocatedPayloadBytes: Int
    var retainedPayloadBytes: Int { labels.capacity * MemoryLayout<Label>.stride + queue.capacity * MemoryLayout<Item>.stride }
    private(set) var examinedArcs = 0
    private(set) var completeWithinRange = false
    private init(limits: Limits) throws {
        guard limits.states > 0, limits.states <= 1_000_000,
              limits.queueEntries > 0, limits.queueEntries <= 2_000_000,
              limits.examinedArcs > 0 else { throw Failure.invalidInput }
        let slots = limits.states * 2 + 1
        let bytes = slots * MemoryLayout<Label>.stride + limits.queueEntries * MemoryLayout<Item>.stride
        guard bytes <= limits.payloadBytes else { throw Failure.resourceLimit }
        self.limits = limits
        let labelStorage = Array(repeating: Label(),count: slots)
        let queueStorage = Array(repeating: Item(node: .init(pack: -1,local: -1),meters: 0),count: limits.queueEntries)
        let actual = labelStorage.capacity * MemoryLayout<Label>.stride + queueStorage.capacity * MemoryLayout<Item>.stride
        guard actual <= limits.payloadBytes else { throw Failure.resourceLimit }
        allocatedPayloadBytes = actual; labels = labelStorage; queue = queueStorage
    }
    private func slot(_ node: Node) -> Int {
        var position = Int((UInt(bitPattern: node.pack) &* 0x9e3779b1 ^ UInt(bitPattern: node.local)) % UInt(labels.count))
        while labels[position].node.pack >= 0 && labels[position].node != node {
            position += 1; if position == labels.count { position = 0 }
        }
        return position
    }
    /// nil is deliberately ambiguous until completeWithinRange is true.
    func distance(_ node: Node) -> Double? {
        guard node.pack >= 0,node.local >= 0 else { return nil }
        let row = labels[slot(node)]; return row.node == node ? row.meters : nil
    }
    func possiblyReached(_ node: Node) -> Bool {
        !completeWithinRange || node.pack < 0 || node.local < 0 || distance(node) != nil
    }
    private func offer(_ node: Node,_ meters: Double) throws {
        let position = slot(node)
        guard meters < labels[position].meters else { return }
        guard queueCount < queue.count else { throw Failure.resourceLimit }
        if labels[position].node.pack < 0 {
            guard stateCount < limits.states else { throw Failure.resourceLimit }
            stateCount += 1
        }
        labels[position] = .init(node: node,meters: meters)
        var child = queueCount; queueCount += 1
        while child > 0 {
            let parent = (child-1)/2
            if queue[parent].meters <= meters { break }
            queue[child] = queue[parent]; child = parent
        }
        queue[child] = .init(node: node,meters: meters)
    }
    private func pop() -> Item? {
        guard queueCount > 0 else { return nil }
        let result = queue[0]; queueCount -= 1
        if queueCount > 0 {
            let last = queue[queueCount]; var parent = 0
            while parent*2+1 < queueCount {
                var child = parent*2+1
                if child+1 < queueCount && queue[child+1].meters < queue[child].meters { child += 1 }
                if last.meters <= queue[child].meters { break }
                queue[parent] = queue[child]; parent = child
            }
            queue[parent] = last
        }
        return result
    }
    static func build(seeds: [Seed],maximumMeters: Double,limits: Limits = .init(),
        cancelled: @escaping () -> Bool = { RoutingWorkContext.stopReason != nil },
        outgoing: (Node, @escaping (Node,Double) throws -> Void) throws -> Void) throws -> BoundedForwardFuelField {
        guard maximumMeters.isFinite,maximumMeters >= 0 else { throw Failure.invalidInput }
        if cancelled() { throw RoutingPageError.cancelled }
        let field = try BoundedForwardFuelField(limits: limits)
        do {
            for seed in seeds {
                if cancelled() { throw RoutingPageError.cancelled }
                guard seed.node.pack >= 0,seed.node.local >= 0,seed.meters.isFinite,seed.meters >= 0 else { throw Failure.invalidInput }
                if seed.meters <= maximumMeters { try field.offer(seed.node,seed.meters) }
            }
            while let current = field.pop() {
                if cancelled() { throw RoutingPageError.cancelled }
                if field.distance(current.node) != current.meters { continue }
                try outgoing(current.node) { target,meters in
                    if cancelled() { throw RoutingPageError.cancelled }
                    field.examinedArcs += 1
                    guard field.examinedArcs <= limits.examinedArcs else { throw Failure.resourceLimit }
                    guard target.pack >= 0,target.local >= 0,meters.isFinite,meters >= 0 else { throw Failure.invalidInput }
                    let total = current.meters + meters
                    if total <= maximumMeters { try field.offer(target,total) }
                }
            }
            if cancelled() { throw RoutingPageError.cancelled }
            field.completeWithinRange = true
        } catch Failure.resourceLimit { /* Partial field must never exclude a station. */ }
        field.queue.removeAll(keepingCapacity: false); field.queueCount = 0
        return field
    }
    /// Streams original outgoing CSR directly. No offsets, adjacency copy or
    /// transpose. All access/turn rules are relaxed; exact routing proves them.
    /// Caller supplies ONLY source-validated exact-node seam adjacency and must
    /// keep its source scope valid through completion. Missing required region
    /// or incomplete seam snapshots must throw, never masquerade as no neighbors.
    static func build(packs: [GraphV2Pack],seeds: [Seed],maximumMeters: Double,
        limits: Limits = .init(),cancelled: @escaping () -> Bool = { RoutingWorkContext.stopReason != nil },
        verifiedSeams: (Node,@escaping (Node) throws -> Void) throws -> Void) throws -> BoundedForwardFuelField {
        try build(seeds: seeds,maximumMeters: maximumMeters,limits: limits,cancelled: cancelled) { node,visit in
            guard packs.indices.contains(node.pack),node.local >= 0,node.local < packs[node.pack].nodeCount else { throw Failure.invalidInput }
            let pack = packs[node.pack]
            let start = Int(pack.nodeOffsets[node.local]),end = Int(pack.nodeOffsets[node.local+1])
            guard start >= 0,end >= start,end <= pack.edgeTargets.count,end <= pack.edgeUndirectedIndex.count else { throw Failure.invalidInput }
            for arc in start..<end {
                let edge = Int(pack.edgeUndirectedIndex[arc]),target = Int(pack.edgeTargets[arc])
                guard pack.edgeMeters.indices.contains(edge),target >= 0,target < pack.nodeCount else { throw Failure.invalidInput }
                try visit(.init(pack: node.pack,local: target),Double(pack.edgeMeters[edge]))
            }
            try verifiedSeams(node) { target in
                guard packs.indices.contains(target.pack),target.local >= 0,target.local < packs[target.pack].nodeCount else { throw Failure.invalidInput }
                try visit(target,0)
            }
        }
    }
}
