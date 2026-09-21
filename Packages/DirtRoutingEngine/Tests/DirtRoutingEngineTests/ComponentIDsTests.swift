import Testing
@testable import DirtRoutingEngine

struct ComponentIDsTests {
    @Test func connectivityModesPreserveAccessAndFerryBoundaries() throws {
        var line = PolicyTests.Line(
            nodes: (0..<8).map { .init(longitude: Double($0) * 0.01, latitude: 0) },
            edges: [(0,1),(1,2),(2,3),(3,4),(4,5),(5,6)],
            surfaces: Array(repeating: "asphalt", count: 6),
            roads: Array(repeating: "tertiary", count: 6))
        line.edgeAccess = [0, 1, 3, 4, 2, 0]
        line.structures = ["", "", "ferry", "", "", ""]
        let graph = try IndexedGraph(line)
        #expect(Array(WeakComponents.ids(in: graph, allowUnknown: false)) == [0,0,2,2,2,5,5,7])
        #expect(Array(WeakComponents.ids(in: graph, allowUnknown: true)) == [0,0,0,0,0,5,5,7])
        #expect(Array(try WeakComponents.landIDs(in: graph, budget: .init())) == [0,0,0,3,3,5,5,7])
        // The cached modes must remain separate after all three are requested.
        #expect(Array(WeakComponents.ids(in: graph, allowUnknown: false)) == [0,0,2,2,2,5,5,7])
    }

    @Test(arguments: ReferenceTests.cases) func componentRootsMatchIndependentFloodFill(_ name: String) throws {
        let fixtures = ReferenceTests()
        let pack = try GraphPack(graphURL: fixtures.fixture(name + ".graph.v4.bin"),
                                 geometryURL: fixtures.fixture(name + ".geometry.v1.bin"))
        for unknown in [false, true] {
            var neighbors = [[Int]](repeating: [], count: pack.nodeCount)
            for edge in 0..<pack.edgeCount {
                let codes: Set<UInt8> = unknown ? [0,1,3,4] : [0,3,4]
                guard codes.contains(pack.accessCode(edge, forward: true))
                    || codes.contains(pack.accessCode(edge, forward: false)) else { continue }
                let a = pack.endpoint(edge, from: true), b = pack.endpoint(edge, from: false)
                neighbors[a].append(b); neighbors[b].append(a)
            }
            var expected = [Int](repeating: -1, count: pack.nodeCount)
            for node in expected.indices where expected[node] == -1 {
                var queue = [node], head = 0
                expected[node] = node
                while head < queue.count {
                    let current = queue[head]; head += 1
                    for next in neighbors[current] where expected[next] == -1 {
                        expected[next] = node; queue.append(next)
                    }
                }
            }
            let roots = WeakComponents.compute(in: pack, allowUnknown: unknown)
            #expect(Array(roots) == expected)
            #expect(roots.ownedBytes == pack.nodeCount * 4)
        }
    }

    @Test func compactRootsKeepIndependentValueSemantics() {
        let original = ComponentIDs(nodeCount: 100)
        var copy = original
        copy[99] = 2
        #expect(original[99] == 99)
        #expect(copy[99] == 2)
        #expect(original.ownedBytes == 400)
        #expect(ComponentIDs(nodeCount: 0).isEmpty)
    }
}
