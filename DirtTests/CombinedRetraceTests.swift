import Testing
@testable import Dirt

struct CombinedRetraceTests {
    @Test func oneReadWalkMatchesExistingCyclesAndOverlapBoundaries() {
        let chains=[[-1],[1,2,3,-1],[1,2,3,1],[0]]
        for chain in chains {
            for edge in 0...5 {
                for lower in [0.0,9.0,9.5,10.0] {
                    let target=PathRetrace.Span(edge: edge,lower: lower,upper: 20)
                    let expected=PathRetrace.contains(node: 0,span: target,
                        previous: { chain[$0] },record: { .init(edge: $0,lower: 0,upper: 10) })
                    let actual=PathRetrace.contains(node: 0,span: target,step: {
                        (previous: chain[$0],span: .init(edge: $0,lower: 0,upper: 10))
                    })
                    #expect(actual == expected)
                }
            }
        }
    }
    @Test func oneLabelReadPerAcyclicNode() {
        var reads=0
        #expect(!PathRetrace.contains(node: 99,span: .init(edge: 1000,lower: 0,upper: 10),step: {
            reads += 1
            return (previous: $0-1,span: .init(edge: $0,lower: 0,upper: 10))
        }))
        #expect(reads == 100)
    }
}
