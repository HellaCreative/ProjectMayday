import Foundation

/// Shared packed-edge interval law; disjoint partial endpoint spans are legal.
/// Lockstep: routing/lib/path-retrace.js.
nonisolated enum PathRetrace {
    /// Real routes are thousands of edges, not millions. Walking farther is a
    /// cycle or a hang, not a legal path.
    static let maximumWalkSteps = 65_536

    struct Span {
        let edge: Int
        let lower: Double
        let upper: Double
        func overlaps(_ other: Span) -> Bool {
            edge == other.edge && min(upper, other.upper) - max(lower, other.lower) > 0.5
        }
    }

    /// Occupied spans on the path to one search node. Built once per pop so
    /// each outgoing edge is an O(1) overlap check instead of a full walk.
    struct Occupancy {
        private var byEdge: [Int: [Span]] = [:]

        init() {}

        mutating func insert(_ span: Span) {
            byEdge[span.edge, default: []].append(span)
        }

        func overlaps(_ span: Span) -> Bool {
            (byEdge[span.edge] ?? []).contains { $0.overlaps(span) }
        }
    }

    static func occupancy(
        from initial: Int,
        previous: (Int) -> Int,
        record: (Int) -> Span?
    ) -> Occupancy {
        var occupied = Occupancy()
        var node = initial
        var steps = 0
        while node >= 0 {
            if let row = record(node) { occupied.insert(row) }
            let next = previous(node)
            steps += 1
            if next == node || steps > maximumWalkSteps { break }
            node = next
        }
        return occupied
    }

    static func contains(node initial: Int, span: Span,
                         previous: (Int) -> Int, record: (Int) -> Span?) -> Bool {
        occupancy(from: initial, previous: previous, record: record).overlaps(span)
    }

    static func repeats(_ rows: [Span]) -> Bool {
        var byEdge: [Int: [Span]] = [:]
        for row in rows {
            if (byEdge[row.edge] ?? []).contains(where: { $0.overlaps(row) }) { return true }
            byEdge[row.edge, default: []].append(row)
        }
        return false
    }
}
