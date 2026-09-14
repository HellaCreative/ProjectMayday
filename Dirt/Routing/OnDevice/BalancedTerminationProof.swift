import Foundation

/// Conservative proof for the current native Balanced comparator. No global
/// optimality is claimed beyond the represented resource-label search space.
nonisolated enum BalancedTerminationProof {
    static func canFinish(dirtMeters: Double, pathMeters: Double,
                          selectionCost: Double, frontierMinimumCost: Double) -> Bool {
        guard pathMeters.isFinite, pathMeters > 0, dirtMeters.isFinite,
              dirtMeters >= 0, dirtMeters <= pathMeters,
              selectionCost.isFinite, selectionCost >= 0,
              !frontierMinimumCost.isNaN else { return false }
        // The existing comparator treats ratio errors within 0.005 as tied.
        // No possible route can have ratio error below zero.
        let error = abs(dirtMeters / pathMeters - 0.5)
        guard error <= 0.005 else { return false }
        // Preserve the current 50-score tolerance exactly (weighted km today).
        // Strict inequality prevents an unexamined shorter equal-score result
        // from winning the existing final length tiebreak.
        return frontierMinimumCost > selectionCost + 50
    }
}
