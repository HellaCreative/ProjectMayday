import Testing
@testable import Dirt

struct V4TurnBudgetDiagnosticTests {
    @Test func budgetFailureReportsItsActualBoundOnceAtScopeEnd() throws {
        for reason in ["bytes","states","transitions"] {
            let measurement = RoutingMeasurement(metadata: ["workload":"turn-budget-"+reason])
            try RoutingWorkContext.$measurement.withValue(measurement) {
                var limits = V4TurnPreparationLimits()
                limits.maximumStates = 1; limits.maximumTransitions = 1
                let budget = try V4TurnPreparationBudget(limits: limits)
                defer { budget.publishDiagnostics() }
                switch reason {
                case "bytes":
                    try budget.reserve(limits.maximumReservedBytes)
                    #expect(throws: V4TurnPreparationError.resourceLimit) { try budget.reserve(1) }
                case "states":
                    try budget.state(progress: 0)
                    #expect(throws: V4TurnPreparationError.resourceLimit) { try budget.state(progress: 0) }
                default:
                    try budget.transition()
                    #expect(throws: V4TurnPreparationError.resourceLimit) { try budget.transition() }
                }
            }
            let report = measurement.finish(outcome: "expected-limit")
            let key = reason == "bytes" ? "turnPreparationByteLimitHits" : reason == "states" ? "turnPreparationStateLimitHits" : "turnPreparationTransitionLimitHits"
            #expect(report.counters[key] == 1)
            #expect(report.counters["turnPreparationStates"] == (reason == "states" ? 1 : 0))
            #expect(report.counters["turnPreparationTransitions"] == (reason == "transitions" ? 1 : 0))
        }
    }
}
