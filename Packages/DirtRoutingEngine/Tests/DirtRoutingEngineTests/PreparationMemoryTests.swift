import Foundation
import CryptoKit
import Testing
@testable import DirtRoutingEngine

struct PreparationMemoryTests {
    @Test func chunkedSearchHistoryKeepsIndicesAndIndependentCopies() {
        var history = ChunkedArray<Int>()
        #expect(history.count == 0)
        for i in 0..<10_003 { history.append(i * 7) }
        #expect(history.count == 10_003)
        for i in 0..<history.count { #expect(history[i] == i * 7) }
        var branch = history
        branch.append(-1)
        history.append(-2)
        #expect(branch[10_003] == -1)
        #expect(history[10_003] == -2)
        for i in 10_004..<20_007 { history.append(i * 7) }
        #expect(branch.count == 10_004)
        #expect(history[20_006] == 20_006 * 7)
    }

    @Test func unrelatedRoadsAtSameCoordinatesCannotBecomeAJunction() throws {
        // Distinct source nodes can occupy the same map position at an
        // overpass, barrier or divided road. Only source topology joins them.
        let raw = PolicyTests.Line(nodes: [.init(longitude: 0, latitude: 0),
            .init(longitude: 0.01, latitude: 0), .init(longitude: 0.01, latitude: 0),
            .init(longitude: 0.02, latitude: 0)], edges: [(0,1),(2,3)],
            surfaces: ["asphalt", "asphalt"], roads: ["tertiary", "tertiary"])
        let graph = try IndexedGraph(raw)
        let start = RoadMatch(edge: 0, coordinate: raw.nodes[0], distanceMeters: 0,
            alongMeters: 0, geometryMeters: raw.distance(0), forward: true)
        let end = RoadMatch(edge: 1, coordinate: raw.nodes[3], distanceMeters: 0,
            alongMeters: raw.distance(1), geometryMeters: raw.distance(1), forward: true)
        #expect(graph.coincidentSiblings(1).isEmpty)
        #expect(throws: RoutingFailure.noPath) {
            try PathSearch(pack: graph).search(start: start, end: end,
                policy: .init(style: .cleanest), access: .init(), options: .init(), budget: .init())
        }
    }

    @Test func preparedGeometryPreservesMatchingAndRejectsDamagedTables() throws {
        let fixtures = ReferenceTests(), raw = try RegionalGraphTests().graph()
        let graphFile = try BinaryFile(url: fixtures.fixture("legal-topology-restrictions.graph.v4.bin"))
        var geometry = try Data(contentsOf: fixtures.fixture("legal-topology-restrictions.geometry.v1.bin"))
        let tableAt = geometry.count
        geometry[6] |= 2
        for edge in 0..<raw.edgeCount {
            let bounds = try raw.matchingGridBounds(edge)
            for value in bounds.map({ [$0.x0, $0.x1, $0.y0, $0.y1] }) ?? [32767, -32768, 32767, -32768] {
                var word = Int16(value).littleEndian
                withUnsafeBytes(of: &word) { geometry.append(contentsOf: $0) }
            }
        }
        func open(_ bytes: Data, bindHash: Bool = true) throws -> GraphPack {
            var graph = graphFile.data
            let hashAt = Int(try graphFile.read(136, as: UInt32.self))
            if bindHash { graph.replaceSubrange(hashAt..<(hashAt + 32), with: Data(SHA256.hash(data: bytes))) }
            return try GraphPack(graph: BinaryFile(data: graph), geometry: BinaryFile(data: bytes), budget: .init())
        }
        let prepared = try open(geometry)
        let before = try IndexedGraph(raw), after = try IndexedGraph(prepared)
        let joined = try RegionalGraph(graphs: [prepared, prepared],
            documents: RegionalGraphTests().documents(prepared), budget: .init())
        for edge in 0..<raw.edgeCount {
            #expect(try prepared.matchingGridBounds(edge) == raw.matchingGridBounds(edge))
            #expect(try joined.matchingGridBounds(edge + raw.edgeCount) == raw.matchingGridBounds(edge))
            #expect(prepared.polyline(edge) == raw.polyline(edge))
            for point in raw.polyline(edge) {
                #expect(before.candidates(near: point, radius: 2000) == after.candidates(near: point, radius: 2000))
                for unknown in [false, true] {
                    let policy = AccessPolicy(allowUnknown: unknown)
                    let a = try RoadMatcher(pack: before).matches(at: point, radius: 2000, start: true, policy: policy, budget: .init())
                    let b = try RoadMatcher(pack: after).matches(at: point, radius: 2000, start: true, policy: policy, budget: .init())
                    #expect(a.map(\.edge) == b.map(\.edge))
                    #expect(a.map(\.forward) == b.map(\.forward))
                    #expect(a.map(\.alongMeters) == b.map(\.alongMeters))
                }
            }
        }
        #expect(throws: RoutingFailure.self) { try open(geometry, bindHash: false) }
        #expect(throws: RoutingFailure.self) { try open(Data(geometry.dropLast())) }
        var broken = geometry
        broken[tableAt] = 255; broken[tableAt + 1] = 127
        #expect(throws: RoutingFailure.self) { try open(broken).matchingGridBounds(0) }
    }

    @Test func completedStageRenewsItsWindowButAttemptsCannotExtendIt() throws {
        let parent = ComputationBudget(seconds: 1, maximumLabels: 17)
        let attempt = parent.limited(to: 20)
        #expect(attempt.deadline == parent.deadline)
        let committed = try parent.afterCommittedStage()
        #expect(committed.deadline >= parent.deadline)
        #expect(committed.maximumLabels == parent.maximumLabels)
    }

    @Test func cancellationReachesChildBudgetsAndPreventsRenewal() async throws {
        let parent = ComputationBudget(seconds: 30)
        let child = parent.limited(to: 5)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            #expect(throws: CancellationError.self) { try parent.check() }
        }
        task.cancel()
        await task.value
        #expect(throws: CancellationError.self) { try child.check() }
        #expect(throws: CancellationError.self) { try parent.afterCommittedStage() }
    }

    @Test func compactConnectionsPreserveOrderDistancesAndReverseGuidance() throws {
        let raw = try RegionalGraphTests().graph()
        let envelope = try GraphPack.nodeBounds(BinaryFile(url: ReferenceTests().fixture("legal-topology-restrictions.graph.v4.bin")), budget: .init())
        for node in 0..<raw.nodeCount { #expect(envelope.contains(raw.coordinate(node: node))) }
        let indexed = try IndexedGraph(raw)
        for node in 0..<raw.nodeCount {
            let original = raw.outgoing(node), compact = indexed.outgoing(node)
            #expect(original.map(\.edge) == compact.map(\.edge))
            #expect(original.map(\.target) == compact.map(\.target))
            #expect(original.map(\.forward) == compact.map(\.forward))
            #expect(original.map(\.meters) == compact.map(\.meters))
        }
        for edge in 0..<raw.edgeCount {
            let end = RoadMatch(edge: edge, coordinate: raw.coordinate(node: raw.endpoint(edge, from: true)),
                                distanceMeters: 0, alongMeters: 0, geometryMeters: raw.distance(edge))
            let a = try RoadCompass.toward(end: end, pack: raw, budget: .init())
            let b = try RoadCompass.toward(end: end, pack: indexed, budget: .init())
            #expect(a.remaining == b.remaining)
        }
    }

    @Test func mappedAdjacencyPreservesEveryDirectedArcAndReverseOrder() throws {
        for name in ["legal-topology-canary", "legal-topology-restrictions",
                     "legal-topology-forecourt", "legal-topology-forecourt-blocked"] {
            let fixture = ReferenceTests()
            let graph = try GraphPack(graphURL: fixture.fixture(name + ".graph.v4.bin"),
                geometryURL: fixture.fixture(name + ".geometry.v1.bin"))
            let owned = try ArcIndex(nodeCount: graph.nodeCount, budget: .init()) { graph.outgoing($0) }
            let mapped = try ArcIndex(pack: graph, budget: .init())
            #expect(mapped.ownedAdjacencyBytes == 0)
            #expect(owned.ownedAdjacencyBytes > 0)
            #expect(mapped.inStart == owned.inStart)
            #expect(mapped.inArcs == owned.inArcs)
            #expect(mapped.outEdge.count == owned.outEdge.count)
            for node in 0...graph.nodeCount { #expect(mapped.outStart[node] == owned.outStart[node]) }
            for arc in 0..<owned.outEdge.count {
                #expect(mapped.outEdge[arc] == owned.outEdge[arc])
                #expect(mapped.targets[arc] == owned.targets[arc])
                #expect(mapped.source(arc) == owned.source(arc))
                #expect(mapped.forward(arc) == owned.forward(arc))
                #expect(mapped.distance(arc) == owned.distance(arc))
            }
            #expect(throws: RoutingFailure.self) {
                try ArcIndex(pack: graph, budget: .init(seconds: 0))
            }
        }
    }

    @Test func spatialIndexPreservesAllSupportedAccessMatches() throws {
        let nodes = [Coordinate(longitude: 0.001, latitude: 0.001),
                     Coordinate(longitude: 0.002, latitude: 0.001)]
        for code: UInt8 in [0, 1, 2, 3, 4, 5] {
            let raw = PolicyTests.Line(nodes: nodes, edges: [(0, 1)],
                surfaces: ["gravel"], roads: ["track"], access: code)
            let forbidden = code == 2 || code == 5
            // Forbidden roads use no lookup slots even with a zero-entry budget.
            let indexed = try IndexedGraph(raw, maximumEntries: forbidden ? 0 : 1)
            #expect(indexed.edgeCount == raw.edgeCount)
            #expect(indexed.outgoing(0).map(\.edge) == raw.outgoing(0).map(\.edge))
            for unknown in [false, true] {
                for customer in [false, true] {
                    let policy = AccessPolicy(allowUnknown: unknown,
                        startIsCustomer: customer, endIsCustomer: customer)
                    for start in [false, true] {
                        let expected = try RoadMatcher(pack: raw).matches(at: nodes[0],
                            radius: 50, start: start, policy: policy, budget: .init())
                        let actual = try RoadMatcher(pack: indexed).matches(at: nodes[0],
                            radius: 50, start: start, policy: policy, budget: .init())
                        #expect(actual.map(\.edge) == expected.map(\.edge))
                        #expect(actual.map(\.forward) == expected.map(\.forward))
                    }
                }
            }
        }
    }

    @Test func warmPreparationIsBoundedAndRevalidatesChangedBytes() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fixtures = ReferenceTests()
        let geometry = try Data(contentsOf: fixtures.fixture("legal-topology-restrictions.geometry.v1.bin"))
        let source = try Data(contentsOf: fixtures.fixture("legal-topology-restrictions.graph.v4.bin"))
        var roots: [String: URL] = [:]
        for region in ["aa", "bb", "cc"] {
            let root = temporary.appendingPathComponent(region)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var graph = source
            // Same-size JSON replacement leaves all binary offsets intact.
            let needle = Data("\"fix\"".utf8), replacement = Data("\"\(region)\" ".utf8)
            while let range = graph.range(of: needle) { graph.replaceSubrange(range, with: replacement) }
            let artifacts: [(String, Data)] = [("graph.v4.bin", graph), ("geometry.v1.bin", geometry), ("fuel.v1.json", Data("{}".utf8))]
            var manifest: [String: Any] = ["schema": "pack-manifest.v2", "fabricReleaseId": "test", "regionId": region,
                "sourceEpoch": "fixture", "timezone": "America/Halifax", "capabilities": ["legal-topology.v1"]]
            for (name, bytes) in artifacts {
                try bytes.write(to: root.appendingPathComponent(name))
                let field = name.hasPrefix("graph") ? "graph" : name.hasPrefix("geometry") ? "geometry" : "fuel"
                manifest[field] = ["name": name, "bytes": bytes.count,
                    "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
            }
            try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("pack-manifest.v2.json"))
            roots[region] = root
        }
        let repository = try PackRepository(installedDirectories: roots), store = PreparedGraphStore(capacity: 2)
        let a = try store.indexed(["aa"], repository: repository, budget: .init())
        #expect(try store.indexed(["aa"], repository: repository, budget: .init()).cacheIdentity == a.cacheIdentity)
        _ = try store.indexed(["bb"], repository: repository, budget: .init())
        _ = try store.indexed(["cc"], repository: repository, budget: .init())
        #expect(try store.peek(["aa"], repository: repository) == nil)
        #expect(try store.peek(["bb"], repository: repository) != nil)
        #expect(try store.peek(["cc"], repository: repository) != nil)
        // A still-live route owner retains its graph safely after cache eviction.
        #expect(a.edgeCount > 0)
        let envelope = try repository.planningEnvelope("cc", budget: .init())
        #expect(envelope.contains(a.coordinate(node: 0)))
        let changed = roots["cc"]!.appendingPathComponent("fuel.v1.json")
        try Data("[]".utf8).write(to: changed, options: .atomic)
        #expect(try store.peek(["cc"], repository: repository) == nil)
        #expect(throws: RoutingFailure.self) { try store.indexed(["cc"], repository: repository, budget: .init()) }
        #expect(try repository.preparationIdentity(["aa", "bb"]) != repository.preparationIdentity(["bb", "aa"]))
    }
}
