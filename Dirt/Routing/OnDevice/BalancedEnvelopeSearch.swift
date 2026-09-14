import CoreFoundation

/// A wider corridor is justified by exhausted topology, not by an unfinished
/// calculation. All widths share the caller's original deadline. A successful
/// legal incumbent (including an explicitly limited one) is returned unchanged.
nonisolated enum BalancedEnvelopeSearch {
    static func run<Value>(widths: [Double], deadline: Double?,
        now: () -> Double = { CFAbsoluteTimeGetCurrent() },
        search: (Double) -> Swift.Result<Value, OnDeviceRouter.Failure>
    ) -> Swift.Result<Value, OnDeviceRouter.Failure> {
        for width in widths {
            if let deadline, now() >= deadline { return .failure(.searchLimit("timeCap")) }
            switch search(width) {
            case .success(let result): return .success(result)
            case .failure(.noPath): continue
            case .failure(let failure): return .failure(failure)
            }
        }
        return .failure(.noPath)
    }
}
