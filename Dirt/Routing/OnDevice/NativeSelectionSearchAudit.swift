import Foundation

/// Metadata only: never chooses, rejects or edits a route. noPath is a
/// completed negative attempt; searchLimit means the alternative was unproved.
/// Scoped to the native Dirt comparison/repair family. Other profile fallback
/// families currently retain their existing aggregation behavior.
nonisolated struct NativeSelectionSearchAudit {
    private(set) var attempts = 0
    private(set) var limitedOutcomes: [String] = []

    mutating func record(_ outcome: Swift.Result<OnDeviceRouter.Result, OnDeviceRouter.Failure>) {
        attempts += 1
        switch outcome {
        case .success(let route):
            if route.searchMeta.timedOut {
                limitedOutcomes.append(route.searchMeta.pass2Outcome.isEmpty ? "searchLimit" : route.searchMeta.pass2Outcome)
            }
        case .failure(.searchLimit(let reason)): limitedOutcomes.append(reason)
        case .failure: break
        }
    }
    func apply(to meta: inout OnDeviceRouter.SearchMeta) {
        meta.selectionAttempts = attempts
        meta.selectionLimitedOutcomes = limitedOutcomes
        meta.timedOut = meta.timedOut || !limitedOutcomes.isEmpty
        // Keep selected pass2Outcome, pops and elapsedMs intact. The explicit
        // outcomes above explain why a completed winner still has a warning.
    }
}
