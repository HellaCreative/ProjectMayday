import Testing
@testable import Dirt

@Suite struct BalancedTerminationProofTests {
    @Test func firstValidMixDoesNotProveNoBetterMixExists() {
        #expect(!BalancedTerminationProof.canFinish(dirtMeters: 46, pathMeters: 100,
            selectionCost: 1, frontierMinimumCost: 1_000))
        #expect(!BalancedTerminationProof.canFinish(dirtMeters: 50, pathMeters: 100,
            selectionCost: 10, frontierMinimumCost: 60))
        #expect(BalancedTerminationProof.canFinish(dirtMeters: 50, pathMeters: 100,
            selectionCost: 10, frontierMinimumCost: 60.01))
    }

    @Test func boundCannotDiscardAnImprovingFutureUnderCurrentComparator() {
        // Cover future routes across every represented 5% ratio bucket, near
        // the exact tolerance boundary, and shorter final-length tiebreaks.
        for ratio in [0.496, 0.5, 0.504] {
            for oldCost in [0.0, 3, 100] {
                let frontier = oldCost + 50.001
                #expect(BalancedTerminationProof.canFinish(dirtMeters: ratio * 100,
                    pathMeters: 100, selectionCost: oldCost, frontierMinimumCost: frontier))
                for futureRatio in stride(from: 0.0, through: 1.0, by: 0.001) {
                    for futureLength in [1.0, 90, 100, 1_000] {
                        let futureWins: Bool
                        let oldError = abs(ratio - 0.5), newError = abs(futureRatio - 0.5)
                        if abs(oldError - newError) > 0.005 { futureWins = newError < oldError }
                        else if abs(oldCost - frontier) > 50 { futureWins = frontier < oldCost }
                        else { futureWins = futureLength < 100 }
                        #expect(!futureWins)
                    }
                }
            }
        }
    }

    @Test func malformedMetricsCannotProduceACompletionProof() {
        for (dirt, length, cost, frontier) in [
            (50.0, 0.0, 10.0, 100.0), (.nan, 100, 10, 100),
            (50, .infinity, 10, 100), (50, 100, .nan, 100),
            (50, 100, 10, .nan), (101, 100, 10, 100)
        ] {
            #expect(!BalancedTerminationProof.canFinish(dirtMeters: dirt, pathMeters: length,
                selectionCost: cost, frontierMinimumCost: frontier))
        }
    }
}
