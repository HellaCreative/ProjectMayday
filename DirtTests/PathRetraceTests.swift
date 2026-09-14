import Testing
@testable import Dirt

struct PathRetraceTests {
    @Test func cyclicPredecessorsKeepExistingRejectionWithoutLongWalk() {
        let chain = [1, 2, 3, 1]
        var reads = 0
        let result = PathRetrace.contains(node: 0,
            span: .init(edge: 99, lower: 0, upper: 10),
            previous: { reads += 1; return chain[$0] },
            record: { .init(edge: $0, lower: 0, upper: 1) })
        #expect(result)
        #expect(reads < 20)
    }

    @Test func acyclicChainsKeepPartialEdgeOverlapLaw() {
        for count in 1...40 {
            for query in 0...count {
                let result = PathRetrace.contains(node: count - 1,
                    span: .init(edge: query, lower: 0, upper: 10),
                    previous: { $0 - 1 },
                    record: { .init(edge: $0, lower: 0, upper: 10) })
                #expect(result == (query < count))
            }
        }
        let boundaryOnly = PathRetrace.contains(node: 0,
            span: .init(edge: 2, lower: 9.5, upper: 20), previous: { _ in -1 },
            record: { _ in .init(edge: 2, lower: 0, upper: 10) })
        #expect(boundaryOnly == false, "stop reason: \(RoutingWorkContext.stopReason ?? "none")")
        #expect(PathRetrace.contains(node: 0,
            span: .init(edge: 2, lower: 9, upper: 20), previous: { _ in -1 },
            record: { _ in .init(edge: 2, lower: 0, upper: 10) }))
    }
    @Test func countedWalkReportsExactlyTheReadsIncludingMatchingTerminal() {
        for count in 0...40 {
            for query in 0...count {
                var reads = 0
                let result = PathRetrace.containsCounted(node: count - 1,
                    span: .init(edge: query, lower: 0, upper: 10), step: { node in
                        reads += 1
                        return (node - 1, .init(edge: node, lower: 0, upper: 10))
                    })
                #expect(result.contains == (query < count))
                #expect(result.visits == UInt64(reads))
                #expect(reads == (query < count ? count - query : count))
            }
        }
    }

    @Test func countedWalkPreservesCycleAndPartialOverlapOutcomes() {
        for chain in [[0], [1, 2, 3, 1], [1, 2, -1]] {
            var reads = 0
            let span = PathRetrace.Span(edge: 99, lower: 0, upper: 10)
            let result = PathRetrace.containsCounted(node: 0, span: span, step: { node in
                reads += 1
                return (chain[node], nil)
            })
            let original = PathRetrace.contains(node: 0, span: span,
                previous: { chain[$0] }, record: { _ in nil })
            #expect(result.contains == original)
            #expect(result.visits == UInt64(reads))
            #expect(reads < 20)
        }
        for lower in [9.0, 9.5, 10.0] {
            let result = PathRetrace.containsCounted(node: 0,
                span: .init(edge: 2, lower: lower, upper: 20),
                step: { _ in (-1, .init(edge: 2, lower: 0, upper: 10)) })
            #expect(result.contains == (lower < 9.5))
            #expect(result.visits == 1)
        }
    }

    @Test func countedCancelledWalkDoesNotCountAnUnreadPredecessor() {
        RoutingWorkContext.$deadline.withValue(0) {
            let result = PathRetrace.containsCounted(node: 0,
                span: .init(edge: 1, lower: 0, upper: 10), step: { _ in
                    Issue.record("Cancelled walk read a predecessor")
                    return (-1, nil)
                })
            #expect(result.contains)
            #expect(result.visits == 0)
            let empty = PathRetrace.containsCounted(node: -1,
                span: .init(edge: 1, lower: 0, upper: 10), step: { _ in (-1, nil) })
            #expect(!empty.contains)
            #expect(empty.visits == 0)
        }
    }

}
