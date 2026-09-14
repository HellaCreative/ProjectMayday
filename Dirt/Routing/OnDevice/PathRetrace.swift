import Foundation

/// Shared packed-edge interval law; disjoint partial endpoint spans are legal.
/// Lockstep: routing/lib/path-retrace.js.
nonisolated enum PathRetrace {
    struct Span {
        let edge: Int
        let lower: Double
        let upper: Double
        @inline(__always) func overlaps(_ other: Span) -> Bool {
            edge == other.edge && min(upper, other.upper) - max(lower, other.lower) > 0.5
        }
    }
    @inline(__always) static func contains(node initial: Int, span: Span,
                         previous: (Int) -> Int, record: (Int) -> Span?) -> Bool {
        var node = initial, steps = 0
        var checkpoint = initial, checkpointPower = 1, sinceCheckpoint = 0
        while node >= 0 {
            if steps & 255 == 0, RoutingWorkContext.stopReason != nil { return true }
            if let row = record(node), row.overlaps(span) { return true }
            let next = previous(node)
            steps += 1
            if next == node || steps > 10_000_000 { return true }
            // A cyclic predecessor chain already returns true under the existing
            // guard. Brent's detection proves the same outcome promptly, using
            // constant memory instead of walking up to ten million links.
            if next >= 0, next == checkpoint { return true }
            sinceCheckpoint += 1
            if sinceCheckpoint == checkpointPower {
                checkpoint = next
                checkpointPower *= 2
                sinceCheckpoint = 0
            }
            node = next
        }
        return false
    }
    @inline(__always) static func containsCounted(node initial: Int, span: Span,
                         previous: (Int) -> Int, record: (Int) -> Span?) -> (contains: Bool, visits: UInt64) {
        var node = initial, steps = 0
        var visits: UInt64 = 0
        var checkpoint = initial, checkpointPower = 1, sinceCheckpoint = 0
        while node >= 0 {
            if steps & 255 == 0, RoutingWorkContext.stopReason != nil { return (true, visits) }
            let row = record(node)
            visits &+= 1
            if let row, row.overlaps(span) { return (true, visits) }
            let next = previous(node)
            steps += 1
            if next == node || steps > 10_000_000 { return (true, visits) }
            // A cyclic predecessor chain already returns true under the existing
            // guard. Brent's detection proves the same outcome promptly, using
            // constant memory instead of walking up to ten million links.
            if next >= 0, next == checkpoint { return (true, visits) }
            sinceCheckpoint += 1
            if sinceCheckpoint == checkpointPower {
                checkpoint = next
                checkpointPower *= 2
                sinceCheckpoint = 0
            }
            node = next
        }
        return (false, visits)
    }
    /// Compatibility entry point; the counted walk preserves the same guards and reads.
    @inline(__always) static func contains(node initial: Int, span: Span,
                         step: (Int) -> (previous: Int, span: Span?)) -> Bool {
        containsCounted(node: initial, span: span, step: step).contains
    }
    /// Same walk with one immutable label read per predecessor node.
    @inline(__always) static func containsCounted(node initial: Int, span: Span,
                         step: (Int) -> (previous: Int, span: Span?)) -> (contains: Bool, visits: UInt64) {
        var node = initial, steps = 0
        var visits: UInt64 = 0
        var checkpoint = initial, checkpointPower = 1, sinceCheckpoint = 0
        while node >= 0 {
            if steps & 255 == 0, RoutingWorkContext.stopReason != nil { return (true, visits) }
            let entry = step(node)
            visits &+= 1
            if let row = entry.span, row.overlaps(span) { return (true, visits) }
            let next = entry.previous
            steps += 1
            if next == node || steps > 10_000_000 { return (true, visits) }
            // A cyclic predecessor chain already returns true under the existing
            // guard. Brent's detection proves the same outcome promptly, using
            // constant memory instead of walking up to ten million links.
            if next >= 0, next == checkpoint { return (true, visits) }
            sinceCheckpoint += 1
            if sinceCheckpoint == checkpointPower {
                checkpoint = next
                checkpointPower *= 2
                sinceCheckpoint = 0
            }
            node = next
        }
        return (false, visits)
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
