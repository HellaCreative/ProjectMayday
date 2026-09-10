import Foundation

nonisolated enum CustomerEndpointAccess {
    static let limitMeters = 200.0
    static func validRuns(_ rows: [(id: String, meters: Double)], customerIDs: Set<String>, start: Bool, end: Bool) -> Bool {
        var i = 0
        while i < rows.count {
            guard customerIDs.contains(rows[i].id) else { i += 1; continue }
            let first = i
            var meters = 0.0
            while i < rows.count, customerIDs.contains(rows[i].id) {
                meters += rows[i].meters
                i += 1
            }
            if meters > limitMeters + 0.01 || !((first == 0 && start) || (i == rows.count && end)) { return false }
        }
        return true
    }
}

extension GraphV2Pack {
    nonisolated func customerEndpointEdges(edgeIndex: Int, seeds: [(node: Int, meters: Double)], reverse: Bool = false) -> Set<Int> {
        guard version >= 4, legalTopology, edgeIndex >= 0,
              edgeIndex * 2 + 1 < edgeAccess.count,
              edgeAccess[edgeIndex * 2] == 4 || edgeAccess[edgeIndex * 2 + 1] == 4 else { return [] }
        var adjacency: [Int: [(to: Int, edge: Int, meters: Double)]] = [:]
        for node in 0..<nodeCount {
            for arc in Int(nodeOffsets[node])..<Int(nodeOffsets[node + 1]) {
                let ei = Int(edgeUndirectedIndex[arc])
                let target = Int(edgeTargets[arc])
                guard v4AccessCode(ei: ei, from: node, to: target) == 4 else { continue }
                let source = reverse ? target : node
                adjacency[source, default: []].append((reverse ? node : target, ei, Double(edgeMeters[ei])))
            }
        }
        var distances: [Int: Double] = [:]
        var queue: [(node: Int, meters: Double)] = []
        for seed in seeds where seed.node >= 0 && seed.node < nodeCount && seed.meters.isFinite && seed.meters >= 0 && seed.meters <= CustomerEndpointAccess.limitMeters {
            if seed.meters < (distances[seed.node] ?? .infinity) {
                distances[seed.node] = seed.meters
                queue.append(seed)
            }
        }
        var edges: Set<Int> = queue.isEmpty ? [] : [edgeIndex]
        while !queue.isEmpty {
            queue.sort { $0.meters > $1.meters }
            let current = queue.removeLast()
            guard current.meters == distances[current.node] else { continue }
            for arc in adjacency[current.node] ?? [] {
                let meters = current.meters + arc.meters
                guard meters <= CustomerEndpointAccess.limitMeters else { continue }
                edges.insert(arc.edge)
                if meters < (distances[arc.to] ?? .infinity) {
                    distances[arc.to] = meters
                    queue.append((arc.to, meters))
                }
            }
        }
        return edges
    }
}
