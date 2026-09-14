import Foundation

/// Eligibility only: the cache retains the original result and all disclosure.
/// Preserve completed no-path proofs; incomplete searches, cancellation and
/// unavailable data never become sticky through reuse.
nonisolated enum NativeRouteReusePolicy {
    static func canReuse(_ outcome: Swift.Result<OnDeviceRouter.Result, OnDeviceRouter.Failure>) -> Bool {
        if case .failure(.noPath) = outcome { return true }
        guard case .success(let route) = outcome else { return false }
        let meta = route.searchMeta
        guard route.distanceMeters.isFinite, route.distanceMeters >= 0,
              !route.coordinates.isEmpty else { return false }
        if !meta.timedOut { return true }
        // A selected incomplete search remains retryable. Only the explicit
        // aggregate comparison warning may coexist with a completed winner.
        guard meta.pass2Outcome == "completed",
              let limits = meta.selectionLimitedOutcomes, !limits.isEmpty,
              let attempts = meta.selectionAttempts, attempts > 0 else { return false }
        return limits.allSatisfy { reason in
            reason == "popCap" || reason == "timeCap" || reason == "labelMemoryCap"
        }
    }
}
