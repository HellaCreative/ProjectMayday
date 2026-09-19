import Foundation
import CryptoKit
import Testing
@testable import DirtRoutingEngine

struct PreparationMemoryTests {
    @Test func compactConnectionsPreserveOrderDistancesAndReverseGuidance() throws {
        let raw = try RegionalGraphTests().graph()
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
        let changed = roots["cc"]!.appendingPathComponent("fuel.v1.json")
        try Data("[]".utf8).write(to: changed, options: .atomic)
        #expect(try store.peek(["cc"], repository: repository) == nil)
        #expect(throws: RoutingFailure.self) { try store.indexed(["cc"], repository: repository, budget: .init()) }
        #expect(try repository.preparationIdentity(["aa", "bb"]) != repository.preparationIdentity(["bb", "aa"]))
    }
}
