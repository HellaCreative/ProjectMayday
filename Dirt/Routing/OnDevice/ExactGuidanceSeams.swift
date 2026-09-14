import Foundation

/// Guidance only: transfer between two representations of the SAME verified
/// original node. Actual routing still proves incoming-road/turn legality.
nonisolated enum ExactGuidanceSeams {
    struct Connection: Hashable { let localNode: Int; let remoteNode: Int }
    enum Failure: Error { case incompatibleSource, invalidRecordedIdentity }

    static func connections(local: GraphV2Pack, remote: GraphV2Pack,
        anchors: [GraphV2Pack.CrossPackSeamAnchor],
        reverse: [GraphV2Pack.CrossPackSeamAnchor]) throws -> [Connection] {
        let phase = RoutingWorkContext.measurement?.begin(.seamNodePreparation)
        defer { RoutingWorkContext.measurement?.end(phase) }
        try RoutingWorkContext.check()
        if anchors.isEmpty && reverse.isEmpty { return [] }
        guard !anchors.isEmpty, !reverse.isEmpty else { throw Failure.invalidRecordedIdentity }
        guard local.version >= 4, remote.version >= 4, local.legalTopology, remote.legalTopology,
              let epoch = local.sourceEpoch, !epoch.isEmpty, epoch == remote.sourceEpoch,
              local.osmNodeIds.count == local.nodeCount,
              remote.osmNodeIds.count == remote.nodeCount else { throw Failure.incompatibleSource }
        func reciprocal(_ a: GraphV2Pack.CrossPackSeamAnchor, _ b: GraphV2Pack.CrossPackSeamAnchor) -> Bool {
            guard let id = a.osmNodeId, id != 0 else { return false }
            return b.osmNodeId == id && b.osmWayId == a.osmWayId
                && b.localEdgeId == a.remoteEdgeId && b.remoteEdgeId == a.localEdgeId
                && a.gapMeters >= 0 && a.gapMeters <= 2 && b.gapMeters >= 0 && b.gapMeters <= 2
                && abs(b.latitude - a.latitude) < 0.00002
                && abs(b.longitude - a.longitude) < 0.00002
        }
        // Coverage is symmetric; duplicates do not demand one-to-one pairing,
        // but an unmatched row on either side is not complete guidance.
        for row in reverse {
            try RoutingWorkContext.check()
            guard anchors.contains(where: { reciprocal($0, row) }) else { throw Failure.invalidRecordedIdentity }
        }
        var pairs: [(GraphV2Pack.CrossPackSeamAnchor, GraphV2Pack.CrossPackSeamAnchor)] = []
        var wanted: Set<Int64> = []
        for anchor in anchors {
            try RoutingWorkContext.check()
            guard let id = anchor.osmNodeId,
                  let other = reverse.first(where: { reciprocal(anchor, $0) })
            else { throw Failure.invalidRecordedIdentity }
            for row in [anchor, other] {
                let parts = row.localEdgeId.split(separator: ":")
                guard parts.count == 3, let first = Int64(parts[1]), let last = Int64(parts[2])
                else { throw Failure.invalidRecordedIdentity }
                wanted.insert(first); wanted.insert(last)
            }
            pairs.append((anchor, other)); wanted.insert(id)
        }
        // Retain only requested seam IDs, never a full-region original-ID index.
        func resolve(_ pack: GraphV2Pack) throws -> [Int64: Int] {
            var result: [Int64: Int] = [:]
            for (index, id) in pack.osmNodeIds.enumerated() {
                if index & 1023 == 0 { try RoutingWorkContext.check() }
                if wanted.contains(id) {
                    guard result.updateValue(index, forKey: id) == nil else { throw Failure.invalidRecordedIdentity }
                }
            }
            
            return result
        }
        let a = try resolve(local), b = try resolve(remote)
        func verify(_ pack: GraphV2Pack, _ anchor: GraphV2Pack.CrossPackSeamAnchor, _ node: Int, _ nodes: [Int64: Int]) throws {
            let parts = anchor.localEdgeId.split(separator: ":")
            guard pack.osmNodeIds.indices.contains(node),
                  parts.count == 3, let way = Int64(parts[0]), let first = Int64(parts[1]),
                  let last = Int64(parts[2]), String(way) == anchor.osmWayId,
                  first == pack.osmNodeIds[node] || last == pack.osmNodeIds[node],
                  let firstNode = nodes[first], let lastNode = nodes[last],
                  let from = pack.edgeFrom, let to = pack.edgeTo else { throw Failure.invalidRecordedIdentity }
            for endpoint in [firstNode, lastNode] {
                guard endpoint >= 0, endpoint < pack.nodeCount,
                      pack.nodeOffsets.indices.contains(endpoint),
                      pack.nodeOffsets.indices.contains(endpoint + 1) else { throw Failure.invalidRecordedIdentity }
                let start = Int(pack.nodeOffsets[endpoint]), end = Int(pack.nodeOffsets[endpoint + 1])
                guard start >= 0, end >= start, end <= pack.directedArcCount,
                      end <= pack.edgeUndirectedIndex.count, end <= pack.edgeTargets.count
                else { throw Failure.invalidRecordedIdentity }
                for arc in start..<end {
                    try RoutingWorkContext.check()
                    let edge = Int(pack.edgeUndirectedIndex[arc]), target = Int(pack.edgeTargets[arc])
                    guard target >= 0, target < pack.nodeCount, edge >= 0,
                          edge < pack.undirectedEdgeCount, from.indices.contains(edge),
                          to.indices.contains(edge), pack.osmWayIds.indices.contains(edge)
                    else { throw Failure.invalidRecordedIdentity }
                    let fromNode = Int(from[edge]), toNode = Int(to[edge])
                    guard pack.osmNodeIds.indices.contains(fromNode), pack.osmNodeIds.indices.contains(toNode),
                          (fromNode == endpoint && toNode == target) || (toNode == endpoint && fromNode == target)
                    else { throw Failure.invalidRecordedIdentity }
                    let x = pack.osmNodeIds[fromNode], y = pack.osmNodeIds[toNode]
                    if pack.osmWayIds[edge] == way && ((x == first && y == last) || (x == last && y == first)) { return }
                }
            }
            throw Failure.invalidRecordedIdentity
        }
        var seen: Set<Connection> = [], result: [Connection] = []
        for (anchor, other) in pairs {
            try RoutingWorkContext.check()
            guard let id = anchor.osmNodeId, let x = a[id], let y = b[id] else { throw Failure.invalidRecordedIdentity }
            try verify(local, anchor, x, a); try verify(remote, other, y, b)
            let connection = Connection(localNode: x, remoteNode: y)
            if seen.insert(connection).inserted { result.append(connection) }
        }
        try RoutingWorkContext.check()
        RoutingWorkContext.measurement?.increment(.exactSeamRows, by: UInt64(pairs.count))
        RoutingWorkContext.measurement?.increment(.exactSeamBindings, by: UInt64(result.count))
        // Avoided lookups include prior cache hits; not a claim each was a scan.
        RoutingWorkContext.measurement?.increment(.seamSpatialLookupsAvoided, by: UInt64(pairs.count * 2))
        return result
    }
}
