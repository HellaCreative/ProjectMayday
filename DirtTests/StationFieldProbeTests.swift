import Testing
@testable import Dirt

@Suite("Conservative station field probe")
struct StationFieldProbeTests {
    @Test("Any potentially reachable candidate retains the entire original match")
    func fartherCandidate() throws {
        let result=try StationFieldProbe.canSkip(completedField: true,distances: [.infinity,.infinity,100,.infinity],protectedEdges: []) { visit in
            try visit(0,0,1) // Closest edge unreachable.
            try visit(1,2,3) // A farther edge is potentially reachable: do not filter.
        }
        #expect(!result)
    }
    @Test("Whole coverage with infinite endpoints can skip detailed matching")
    func allInfinite() throws {
        #expect(try StationFieldProbe.canSkip(completedField: true,distances: [.infinity,.infinity],protectedEdges: []) { visit in
            try visit(0,0,1);try visit(0,0,1)
        })
    }
    @Test("Incomplete field and origin interior-edge candidates cannot prove a negative")
    func partialAndOrigin() throws {
        #expect(try !StationFieldProbe.canSkip(completedField: false,distances: [.infinity,.infinity],protectedEdges: []) { _ in
            Issue.record("Incomplete fields must not invoke the probe")
        })
        #expect(try !StationFieldProbe.canSkip(completedField: true,distances: [.infinity,.infinity],protectedEdges: [7]) { visit in
            try visit(7,0,1)
        })
    }
    @Test("Invalid state and NaN are unknown, and read failure propagates")
    func unavailable() throws {
        #expect(try !StationFieldProbe.canSkip(completedField: true,distances: [.nan,.infinity],protectedEdges: []) { try $0(0,0,1) })
        #expect(try !StationFieldProbe.canSkip(completedField: true,distances: [.infinity],protectedEdges: []) { try $0(0,0,2) })
        #expect(throws: RoutingPageError.cancelled) {
            _ = try StationFieldProbe.canSkip(completedField: true,distances: [.infinity],protectedEdges: []) { _ in
                throw RoutingPageError.cancelled
            }
        }
    }
    @Test("Global offsets do not confuse unreachable local nodes with another region")
    func regionalOffsets() throws {
        let field: [Double] = [0, 10, .infinity, .infinity, 20, .infinity]
        #expect(try StationFieldProbe.canSkip(completedField: true, distances: field,
            protectedEdges: []) { visit in try visit(0, 2, 3) })
        #expect(try !StationFieldProbe.canSkip(completedField: true, distances: field,
            protectedEdges: []) { visit in try visit(0, 4, 5) })
        #expect(try !StationFieldProbe.canSkip(completedField: true, distances: field,
            protectedEdges: [0]) { visit in try visit(0, 2, 3) })
    }
    @Test("A possible match immediately resumes normal matching")
    func shortCircuit() throws {
        var visits = 0
        let skipped = try StationFieldProbe.canSkip(completedField: true,
            distances: [0, .infinity], protectedEdges: []) { visit in
            visits += 1
            try visit(0, 0, 1)
            visits += 1
            try visit(1, 1, 1)
        }
        #expect(!skipped)
        #expect(visits == 1)
    }

    @Test("Sparse field predicate retains reachable and malformed node identities")
    func sparseField() throws {
        let reached: Set<Int> = [10]
        func possible(_ node: Int) -> Bool { node >= 20 || reached.contains(node) }
        #expect(try StationFieldProbe.canSkip(completedField: true, protectedEdges: [],
            isPossiblyReachedNode: possible) { visit in try visit(0, 2, 3) })
        #expect(try !StationFieldProbe.canSkip(completedField: true, protectedEdges: [],
            isPossiblyReachedNode: possible) { visit in try visit(0, 2, 10) })
        #expect(try !StationFieldProbe.canSkip(completedField: true, protectedEdges: [],
            isPossiblyReachedNode: possible) { visit in try visit(0, 20, 3) })
        #expect(try !StationFieldProbe.canSkip(completedField: true, protectedEdges: [],
            isPossiblyReachedNode: possible) { visit in try visit(0, -1, 3) })
    }

}
