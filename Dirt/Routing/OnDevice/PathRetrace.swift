import Foundation

/// Shared packed-edge interval law; disjoint partial endpoint spans are legal.
/// Lockstep: routing/lib/path-retrace.js.
nonisolated enum PathRetrace {
    struct Span {
        let edge: Int
        let lower: Double
        let upper: Double
        func overlaps(_ other: Span) -> Bool {
            edge == other.edge && min(upper, other.upper) - max(lower, other.lower) > 0.5
        }
    }
    static func contains(node initial: Int, span: Span,
                         previous: (Int) -> Int, record: (Int) -> Span?) -> Bool {
        var node = initial, steps = 0
        while node >= 0 {
            if let row = record(node), row.overlaps(span) { return true }
            let next = previous(node)
            steps += 1
            if next == node || steps > 10_000_000 { return true }
            node = next
        }
        return false
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
