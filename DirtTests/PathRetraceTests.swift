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
}
