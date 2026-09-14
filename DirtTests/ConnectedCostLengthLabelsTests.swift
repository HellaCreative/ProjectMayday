import Testing
@testable import Dirt

struct ConnectedCostLengthLabelsTests {
    private let arrival = ConnectedCostLengthLabels.Arrival(pack: 1, turnState: 7, incomingRoad: 9)
    private func accepted(_ result: ConnectedCostLengthLabels.Insertion) throws -> Int {
        guard case .accepted(let id) = result else { throw TestError.unexpectedDominance }
        return id
    }
    @Test func cheaperLongPrefixCannotDiscardDearerShortPrefixNeededForTail() throws {
        let labels = try ConnectedCostLengthLabels()
        let cheap = try accepted(labels.insert(arrival: arrival, history: 1, cost: 1, meters: 195))
        let short = try accepted(labels.insert(arrival: arrival, history: 1, cost: 2, meters: 180))
        #expect(labels.activeCount == 2)
        let tail = 20.0, cap = 207.0
        #expect(try labels.label(cheap).meters + tail > cap)
        #expect(try labels.label(short).meters + tail <= cap)
    }
    @Test func distinctLegalArrivalOrHistoryNeverDominatesWithoutProof() throws {
        let labels = try ConnectedCostLengthLabels()
        _ = try accepted(labels.insert(arrival: arrival, history: 1, cost: 1, meters: 10))
        let differentTurn = ConnectedCostLengthLabels.Arrival(pack: 1, turnState: 8, incomingRoad: 9)
        _ = try accepted(labels.insert(arrival: differentTurn, history: 1, cost: 2, meters: 20))
        _ = try accepted(labels.insert(arrival: arrival, history: 2, cost: 2, meters: 20))
        #expect(labels.activeCount == 3)
    }
    @Test func exactDominanceKeepsStablePredecessorRows() throws {
        let labels = try ConnectedCostLengthLabels()
        let old = try accepted(labels.insert(arrival: arrival, history: 1, cost: 2, meters: 20))
        let next = ConnectedCostLengthLabels.Arrival(pack: 1, turnState: 8, incomingRoad: 10)
        let descendant = try accepted(labels.insert(arrival: next, history: 2, cost: 3, meters: 30, predecessor: old))
        _ = try accepted(labels.insert(arrival: arrival, history: 1, cost: 1, meters: 10))
        #expect(labels.activeCount == 2)
        #expect(try labels.label(descendant).predecessor == old)
        #expect(try labels.label(old).meters == 20)
        if case .dominated = try labels.insert(arrival: arrival, history: 1, cost: 1, meters: 10) {}
        else { Issue.record("Exact duplicate should reuse dominance proof") }
    }
    @Test func limitsAndCancellationAreExplicitWithoutDroppingAlternatives() throws {
        var limits = ConnectedCostLengthLabels.Limits()
        limits.maximumLabels = 2; limits.pageCapacity = 1; limits.bucketCount = 1
        let labels = try ConnectedCostLengthLabels(limits: limits)
        _ = try accepted(labels.insert(arrival: arrival, history: 1, cost: 1, meters: 10))
        _ = try accepted(labels.insert(arrival: arrival, history: 2, cost: 2, meters: 20))
        #expect(throws: ConnectedCostLengthLabels.Failure.self) {
            try labels.insert(arrival: arrival, history: 3, cost: 3, meters: 30)
        }
        #expect(labels.count == 2 && labels.activeCount == 2)
        #expect(labels.accountedPayloadBytes <= limits.maximumPayloadBytes)
        var cancelled = true
        let stopped = try ConnectedCostLengthLabels(limits: limits, cancelled: { cancelled })
        #expect(throws: ConnectedCostLengthLabels.Failure.self) {
            try stopped.insert(arrival: arrival, history: 1, cost: 1, meters: 10)
        }
        #expect(stopped.count == 0)
        cancelled = false
        _ = try accepted(stopped.insert(arrival: arrival, history: 1, cost: 1, meters: 10))
    }
    private enum TestError: Error { case unexpectedDominance }
}
