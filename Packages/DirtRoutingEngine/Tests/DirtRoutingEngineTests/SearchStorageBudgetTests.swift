import Foundation
import Testing
@testable import DirtRoutingEngine

struct SearchStorageBudgetTests {
    @Test func compactCapacityFitsFormerHistoryAllowance() {
        let budget = ComputationBudget()
        let ordinary = ChunkedArray<PathSearch.Label>.payloadBytes(forCount: budget.maximumLabels)
        let partialChunk = ChunkedArray<PathSearch.Arc>.payloadBytes(forCount: 1)
        #expect(ordinary + partialChunk <= budget.maximumSearchHistoryBytes)
        #expect(budget.maximumSearchHistoryBytes == 160 * 1_600_000)
    }

    @Test func fractionalRoadsConsumeHistoryAllowanceAndStayExact() throws {
        let graph = UnknownConnectorTests.Graph(lengths: [100], access: [0])
        let start = RoadMatch(edge: 0, coordinate: .init(longitude: 10 / 111_195, latitude: 0),
                              distanceMeters: 0, alongMeters: 10, geometryMeters: 100)
        let end = RoadMatch(edge: 0, coordinate: .init(longitude: 70 / 111_195, latitude: 0),
                            distanceMeters: 0, alongMeters: 70, geometryMeters: 100)
        var options = SearchOptions(); options.objective = .distance
        let labelsOnly = ChunkedArray<PathSearch.Label>.payloadBytes(forCount: 1)
        func route(_ bytes: Int, count: Int = 32) throws -> ComputedRoute {
            try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: .dirt),
                access: .init(), options: options,
                budget: .init(seconds: 10, maximumLabels: count, maximumSearchHistoryBytes: bytes))
        }
        #expect(throws: RoutingFailure.resourceLimit("search history bytes")) { try route(0) }
        #expect(throws: RoutingFailure.resourceLimit("search history bytes")) { try route(labelsOnly) }
        let enough = labelsOnly + ChunkedArray<PathSearch.Arc>.payloadBytes(forCount: 1)
        let result = try route(enough)
        #expect(result.distanceMeters == 60)
        #expect(result.segments.count == 1)
        #expect(result.limit == nil)
        #expect(throws: RoutingFailure.resourceLimit("labels")) { try route(enough, count: 1) }
    }

    @Test func attemptsAndCommittedStagesRetainTheSameMemoryCeiling() throws {
        let parent = ComputationBudget(seconds: 1, maximumLabels: 17, maximumSearchHistoryBytes: 12345)
        let attempt = parent.limited(to: 20)
        let committed = try parent.afterCommittedStage()
        #expect(attempt.deadline == parent.deadline)
        #expect(attempt.maximumLabels == 17 && committed.maximumLabels == 17)
        #expect(attempt.maximumSearchHistoryBytes == 12345 && committed.maximumSearchHistoryBytes == 12345)
    }
}
