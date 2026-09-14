import Foundation

/// A fast negative for matching against a completed distance field, not a
/// global disconnection proof. Matching remains unchanged for every possible hit.
nonisolated enum StationFieldProbe {
    private enum Stop: Error { case possible }

    static func canSkip(
        completedField: Bool,
        distances: [Double],
        protectedEdges: Set<Int>,
        enumerateCoverage: (_ visit: (Int, Int, Int) throws -> Void) throws -> Void
    ) throws -> Bool {
        try canSkip(completedField: completedField, protectedEdges: protectedEdges,
            isPossiblyReachedNode: { node in
                node >= distances.count || distances[node] != .infinity
            }, enumerateCoverage: enumerateCoverage)
    }

    /// Sparse fields supply a conservative predicate: malformed/out-of-range
    /// node identities must return true. Negative identities are protected here.
    static func canSkip(
        completedField: Bool,
        protectedEdges: Set<Int>,
        isPossiblyReachedNode: @escaping (Int) -> Bool,
        enumerateCoverage: (_ visit: (Int, Int, Int) throws -> Void) throws -> Void
    ) throws -> Bool {
        guard completedField else { return false }
        do {
            try enumerateCoverage { edge, a, b in
                if protectedEdges.contains(edge) { throw Stop.possible }
                guard a >= 0, b >= 0 else {
                    throw Stop.possible
                }
                // NaN and negative infinity do not prove an unreachable endpoint.
                if isPossiblyReachedNode(a) || isPossiblyReachedNode(b) {
                    throw Stop.possible
                }
            }
            return true
        } catch Stop.possible {
            return false
        }
    }
}
