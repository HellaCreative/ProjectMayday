import Foundation

/// Repair a completed, capped suffix noPath by reserving a concrete suffix,
/// then re-proving it after the prefix changes. The caller owns the unchanged
/// absolute deadline, source identity and shared regional work quota.
nonisolated enum RegionalTailRefinement {
    enum Attempt<Value> { case success(Value), noPath, incomplete(String) }
    enum Outcome<Approach, Tail> { case completed(Approach, Tail), incomplete(String) }

    static func afterCappedNoPath<Approach, Tail>(initial: Approach,
        initialApproachCap: Double, availableMeters: Double,
        approachMeters: (Approach) -> Double, tailMeters: (Tail) -> Double,
        check: () throws -> Void, consumeAttempt: () -> Bool,
        approach: (Double) async -> Attempt<Approach>,
        tail: (Approach, Double) async -> Attempt<Tail>) async rethrows -> Outcome<Approach, Tail> {
        var current = initial, cap = initialApproachCap
        while true {
            try check()
            guard consumeAttempt() else { return .incomplete("regionalSeamWorkLimit") }
            // This is a tentative reservation under the original stage budget,
            // not a claim that the current approach plus this tail already fits.
            let broad = await tail(current, availableMeters)
            try check()
            let reservation: Double
            switch broad {
            case .success(let proof): reservation = tailMeters(proof)
            case .noPath: return .incomplete("regionalTailRefinementUnproved")
            case .incomplete(let reason): return .incomplete(reason)
            }
            let nextCap = availableMeters - reservation
            guard reservation.isFinite, reservation >= 0, nextCap >= 0, nextCap < cap
            else { return .incomplete("regionalTailRefinementNoProgress") }
            cap = nextCap
            switch await approach(cap) {
            case .success(let value): current = value
            case .noPath: return .incomplete("regionalTailApproachUnproved")
            case .incomplete(let reason): return .incomplete(reason)
            }
            try check()
            let used = approachMeters(current)
            guard used.isFinite, used >= 0, used <= cap else { return .incomplete("regionalTailApproachInvalidDistance") }
            // Always re-prove with the new exact arrival/history. Never consume
            // the broad result merely because a seam coordinate stayed equal.
            switch await tail(current, availableMeters - used) {
            case .success(let proof):
                try check()
                let final = tailMeters(proof)
                guard final.isFinite, final >= 0, used + final <= availableMeters
                else { return .incomplete("regionalTailInvalidDistance") }
                return .completed(current, proof)
            case .noPath: continue
            case .incomplete(let reason): return .incomplete(reason)
            }
        }
    }
}
