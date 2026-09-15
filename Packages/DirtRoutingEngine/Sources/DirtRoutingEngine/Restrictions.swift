import Foundation

public struct TurnRestriction: Codable, Sendable {
    public let relationID: Int64
    public let fromEdge: Int
    public let toEdge: Int
    public let viaNode: Int
    public let viaEdges: [Int]
    public let only: Bool
    public let vehicleMask: UInt16
    public init(relationID: Int64, fromEdge: Int, toEdge: Int, viaNode: Int,
                viaEdges: [Int] = [], only: Bool, vehicleMask: UInt16 = 7) {
        self.relationID = relationID; self.fromEdge = fromEdge; self.toEdge = toEdge
        self.viaNode = viaNode; self.viaEdges = viaEdges; self.only = only; self.vehicleMask = vehicleMask
    }
}

public struct RestrictionProgress: Hashable, Codable, Sendable {
    public let pattern: Int
    public let progress: Int
    public init(pattern: Int, progress: Int) { self.pattern = pattern; self.progress = progress }
}

/// Ports compileRestrictionIndex / advanceRestrictionState from legal-topology/restrictions.js.
/// Progress is created only for states reached by a search, not preexpanded over a province.
public struct RestrictionIndex: Sendable {
    struct Turn: Hashable { let node: Int; let incoming: Int }
    private var blocked: [Turn: Set<Int>] = [:]
    private var required: [Turn: Set<Int>] = [:]
    private var patterns: [TurnRestriction] = []
    private var starters: [Int: [Int]] = [:]
    public init(_ restrictions: [TurnRestriction]) {
        for r in restrictions where r.vehicleMask & 1 != 0 {
            if !r.viaEdges.isEmpty {
                starters[r.fromEdge, default: []].append(patterns.count)
                patterns.append(r)
            } else {
                let key = Turn(node: r.viaNode, incoming: r.fromEdge)
                if r.only { required[key, default: []].insert(r.toEdge) }
                else { blocked[key, default: []].insert(r.toEdge) }
            }
        }
    }
    public func advance(_ active: [RestrictionProgress], from: Int, to: Int, at node: Int) -> [RestrictionProgress]? {
        let key = Turn(node: node, incoming: from)
        if let only = required[key], !only.contains(to) { return nil }
        if blocked[key]?.contains(to) == true { return nil }
        // Invalid carried state is a data error, never unrestricted travel.
        guard active.allSatisfy({ $0.pattern >= 0 && $0.pattern < patterns.count
            && $0.progress >= 1 && $0.progress <= patterns[$0.pattern].viaEdges.count }) else { return nil }
        func expected(_ row: RestrictionProgress) -> Int {
            let p = patterns[row.pattern]
            return row.progress < p.viaEdges.count ? p.viaEdges[row.progress] : p.toEdge
        }
        let activeOnly = active.filter { patterns[$0.pattern].only }
        if !activeOnly.isEmpty && !activeOnly.contains(where: { expected($0) == to }) { return nil }
        var next = Set<RestrictionProgress>()
        for row in active where expected(row) == to {
            let p = patterns[row.pattern]
            if row.progress == p.viaEdges.count {
                if !p.only { return nil }
            } else { next.insert(.init(pattern: row.pattern, progress: row.progress + 1)) }
        }
        let entering = (starters[from] ?? []).filter { patterns[$0].viaNode < 0 || patterns[$0].viaNode == node }
        let enteringOnly = entering.filter { patterns[$0].only }
        if !enteringOnly.isEmpty && !enteringOnly.contains(where: { patterns[$0].viaEdges[0] == to }) { return nil }
        for id in entering where patterns[id].viaEdges[0] == to {
            next.insert(.init(pattern: id, progress: 1))
        }
        return next.sorted { $0.pattern == $1.pattern ? $0.progress < $1.progress : $0.pattern < $1.pattern }
    }
}
