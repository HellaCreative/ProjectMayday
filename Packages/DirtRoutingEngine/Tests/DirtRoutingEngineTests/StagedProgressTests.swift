import Foundation
import Testing
@testable import DirtRoutingEngine

struct StagedProgressTests {
    private func route() -> ComputedRoute {
        let match = RoadMatch(edge: 0, coordinate: .init(longitude: 0, latitude: 0),
            distanceMeters: 0, alongMeters: 0, geometryMeters: 0)
        return ComputedRoute(start: match, end: match, segments: [],
            distanceMeters: 0, searchCost: 3, poppedLabels: 7, arrivalRestrictions: [])
    }

    private func label(_ event: StagedRouter.Progress) -> String {
        switch event {
        case .started(let chain): return "start:" + chain.joined(separator: "+")
        case .stage(let index, _): return "stage:\(index)"
        case .completed: return "complete"
        case .discarded: return "discard"
        }
    }

    @Test func failedChainIsDiscardedBeforeTheAlternativeStarts() throws {
        var events: [String] = []
        let observe: (StagedRouter.Progress) -> Void = { events.append(label($0)) }
        let expected = route()
        let result = try StagedRouter.firstCompletedConnection(
            [["a", "b"], ["a", "c", "b"]], budget: .init()
        ) { chain, _ in
            try StagedRouter.observedAttempt(chain: chain, onProgress: observe) {
                observe(.stage(index: 0, route: expected))
                if chain.count == 2 { throw RoutingFailure.noPath }
                return expected
            }
        }
        #expect(events == ["start:a+b", "stage:0", "discard",
                           "start:a+c+b", "stage:0", "complete"])
        #expect(result.poppedLabels == expected.poppedLabels)
        #expect(result.searchCost == expected.searchCost)
    }

    @Test func limitedResultCannotEmitCompletionOrLoseItsLimit() throws {
        var events: [String] = []
        let limited = route().reportingLimit("time")
        let result = try StagedRouter.observedAttempt(chain: ["a"],
            onProgress: { events.append(label($0)) }) { limited }
        #expect(result.limit == "time")
        #expect(events == ["start:a", "discard"])
    }

    @Test func cancellationDiscardsPreviewWithoutCompleting() throws {
        var events: [String] = []
        do {
            _ = try StagedRouter.observedAttempt(chain: ["a", "b"],
                onProgress: { events.append(label($0)) }) {
                    throw CancellationError()
                }
            Issue.record("Cancellation must propagate")
        } catch is CancellationError {
            #expect(events == ["start:a+b", "discard"])
        }
    }

    @Test func absentObserverPreservesRouteAndFailure() throws {
        let expected = route()
        let result = try StagedRouter.observedAttempt(chain: ["a"], onProgress: nil) { expected }
        #expect(result.poppedLabels == 7)
        #expect(result.searchCost == 3)
        #expect(throws: RoutingFailure.noPath) {
            try StagedRouter.observedAttempt(chain: ["a"], onProgress: nil) {
                throw RoutingFailure.noPath
            }
        }
    }
}
