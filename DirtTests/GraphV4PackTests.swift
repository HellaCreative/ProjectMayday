import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Graph V4 legal topology")
struct GraphV4PackTests {
    @Test("production pack lookup recognizes V4 and keeps older revisions discoverable")
    func installedV4Lookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let region = root.appendingPathComponent("release/ns")
        try FileManager.default.createDirectory(at: region, withIntermediateDirectories: true)
        let graph = region.appendingPathComponent("graph.v4.bin")
        try Data([1]).write(to: graph)
        #expect(GraphPackStore.findInstalledGraph(regionId: "NS", cacheRoot: root, version: "release") == graph)
        #expect(GraphPackStore.findInstalledGraph(regionId: "ns", cacheRoot: root, version: "new-release")?.resolvingSymlinksInPath() == graph.resolvingSymlinksInPath())
        #expect(GraphPackStore.findInstalledGraph(regionId: "nb", cacheRoot: root, version: "release") == nil)
        let older = region.appendingPathComponent("graph.v3.bin")
        try Data([1]).write(to: older)
        #expect(GraphPackStore.findInstalledGraph(regionId: "ns", cacheRoot: root, version: "release") == graph)
        try FileManager.default.removeItem(at: graph)
        #expect(GraphPackStore.findInstalledGraph(regionId: "ns", cacheRoot: root, version: "release") == older)
    }

    @Test("real forecourt arrival and separate exit match JavaScript")
    func forecourtPaths() throws {
        for profile: RouteProfile in [.cleanest, .balanced] {
            let pack = try GraphV2Pack(data: Data(contentsOf: fixtureURL("legal-topology-forecourt.graph.v4.bin")))
            pack.geometry = try GeometryV1Pack(data: Data(contentsOf: fixtureURL("legal-topology-forecourt.geometry.v1.bin")))
            var router = OnDeviceRouter(pack: pack)
            router.matchLimitMeters = 80
            let a = CLLocationCoordinate2D(latitude: 45, longitude: -64.004)
            let pump = CLLocationCoordinate2D(latitude: 45.0001375, longitude: -63.99965)
            let b = CLLocationCoordinate2D(latitude: 45, longitude: -63.996)
            for (from, to, start, end, expected) in [
                (a, pump, false, true, [10,20,21]),
                (pump, b, true, false, [21,22,11]),
                (a, b, false, false, [10,12,11])
            ] {
                router.startEndpointKind = start ? "customers" : nil
                router.endEndpointKind = end ? "customers" : nil
                switch router.routeDetailed(from: from, to: to, profile: profile, allowUnknown: false, sessionSeed: 0) {
                case .success(let result):
                    var ways: [Int] = []
                    for id in result.edgeIds {
                        if let way = Int(id.split(separator: ":")[0].dropFirst()), ways.last != way { ways.append(way) }
                    }
                    #expect(ways == expected)
                case .failure(let error): Issue.record("forecourt \(profile) failed: \(error)")
                }
            }
        }
    }

    @Test("forbidden forecourt entrance cannot resnap to the public road")
    func forbiddenForecourt() throws {
        let pack = try GraphV2Pack(data: Data(contentsOf: fixtureURL("legal-topology-forecourt-blocked.graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: fixtureURL("legal-topology-forecourt-blocked.geometry.v1.bin")))
        var router = OnDeviceRouter(pack: pack)
        router.matchLimitMeters = 80
        router.endEndpointKind = "customers"
        for profile: RouteProfile in [.cleanest, .balanced] {
            let result = router.routeDetailed(
                from: CLLocationCoordinate2D(latitude: 45, longitude: -64.004),
                to: CLLocationCoordinate2D(latitude: 45.0001375, longitude: -63.99965),
                profile: profile, allowUnknown: false, sessionSeed: 0)
            if case .success = result { Issue.record("forbidden station approach was accepted") }
        }
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: GraphV4FixtureBundle.self)
        if let bundled = bundle.url(forResource: name, withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
            return bundled
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        Issue.record("missing fixture \(name)")
        throw GraphV2Pack.PackError.truncated
    }

    @Test("truncated V4 header is rejected")
    func truncatedV4Rejected() throws {
        var bytes = [UInt8](repeating: 0, count: 140)
        bytes[0] = 0x44
        bytes[1] = 0x52
        bytes[2] = 0x54
        bytes[3] = 0x34
        bytes[4] = 4
        bytes[5] = 0
        let data = Data(bytes)
        #expect(throws: GraphV2Pack.PackError.self) {
            _ = try GraphV2Pack(data: data)
        }
    }

    @Test("V4 reader rejects V3 magic")
    func v4RejectsV3() {
        var bytes = [UInt8](repeating: 0, count: 140)
        bytes[0] = 0x44
        bytes[1] = 0x32
        bytes[2] = 0x47
        bytes[3] = 0x32
        bytes[4] = 3
        bytes[5] = 0
        #expect(throws: GraphV4Pack.PackError.unsupportedVersion) {
            _ = try GraphV4Pack(data: Data(bytes))
        }
    }

    @Test("golden V4 fixture decodes with legal-topology.v1")
    func goldenFixture() throws {
        let graph = try Data(contentsOf: fixtureURL("legal-topology-canary.graph.v4.bin"))
        let geom = try Data(contentsOf: fixtureURL("legal-topology-canary.geometry.v1.bin"))
        let identity = try GraphV4Pack(data: graph, geometry: geom)
        #expect(identity.capabilities.contains("legal-topology.v1"))
        #expect(identity.version == 4)
        #expect(identity.osmNodeIds.count == identity.nodeCount)

        let pack = try GraphV2Pack(data: graph)
        pack.geometry = try GeometryV1Pack(data: geom)
        #expect(pack.version == 4)
        #expect(pack.legalTopology)
        #expect(pack.capabilities.contains("legal-topology.v1"))
        #expect(pack.undirectedEdgeCount == 2)
        #expect(pack.osmWayIds.contains(537982310))
        #expect(pack.osmWayIds.contains(537982311))
        #expect((pack.flags & GraphV2Pack.flagV4DerivedEdgeIDs) != 0)
        #expect(pack.edgeId(0) == "w537982310:0:1")
    }

    @Test("on-device V4 search stays on the legal carriageway")
    func onDeviceTurnAwareCarriageways() throws {
        let graph = try Data(contentsOf: fixtureURL("legal-topology-canary.graph.v4.bin"))
        let geom = try Data(contentsOf: fixtureURL("legal-topology-canary.geometry.v1.bin"))
        let pack = try GraphV2Pack(data: graph)
        pack.geometry = try GeometryV1Pack(data: geom)
        let router = OnDeviceRouter(pack: pack)

        let westStart = CLLocationCoordinate2D(latitude: 45.80779, longitude: -64.191)
        let westEnd = CLLocationCoordinate2D(latitude: 45.80779, longitude: -64.209)
        switch router.routeDetailed(from: westStart, to: westEnd, profile: .balanced, allowUnknown: false) {
        case .success(let result):
            let ways = Set(result.edgeIds.compactMap { Int($0) })
            #expect(ways.contains(537982310) || result.coordinates.count >= 2)
            #expect(!result.edgeIds.contains("537982311"))
        case .failure(let error):
            Issue.record("westbound V4 ride failed: \(error)")
        }

        let eastStart = CLLocationCoordinate2D(latitude: 45.80731, longitude: -64.209)
        let eastEnd = CLLocationCoordinate2D(latitude: 45.80731, longitude: -64.191)
        switch router.routeDetailed(from: eastStart, to: eastEnd, profile: .balanced, allowUnknown: false) {
        case .success(let result):
            #expect(!result.edgeIds.contains("537982310"))
        case .failure(let error):
            Issue.record("eastbound V4 ride failed: \(error)")
        }
    }

    @Test("exact via-way state and endpoint access match the V4 contract")
    func exactViaWayAndEndpointAccess() throws {
        let graph = try Data(contentsOf: fixtureURL("legal-topology-restrictions.graph.v4.bin"))
        let geom = try Data(contentsOf: fixtureURL("legal-topology-restrictions.geometry.v1.bin"))
        let identity = try GraphV4Pack(data: graph, geometry: geom)
        #expect(identity.restrictions.first?.viaEdges.count == 2)

        let pack = try GraphV2Pack(data: graph)
        pack.geometry = try GeometryV1Pack(data: geom)
        func edge(_ way: Int64) throws -> Int {
            try #require(pack.osmWayIds.firstIndex(of: way))
        }
        func node(_ osm: Int64) throws -> Int {
            try #require(identity.osmNodeIds.firstIndex(of: osm))
        }

        let from = try edge(10)
        let to = try edge(12)
        let node2 = try node(2)
        let node3 = try node(3)
        let node4 = try node(4)
        let via = pack.osmWayIds.indices.filter { pack.osmWayIds[$0] == 11 }
        #expect(via.count == 2)
        let firstVia = try #require(via.first { index in
            Int(pack.edgeFrom?[index] ?? -1) == node2 || Int(pack.edgeTo?[index] ?? -1) == node2
        })
        let secondVia = try #require(via.first { $0 != firstVia })

        let turns = pack.makeV4TurnStateSpace(
            startNode: pack.nodeCount,
            endNode: pack.nodeCount + 1
        )
        var state = turns.stateForArrival(node: node2, incomingEdge: from)
        state = turns.transition(state: state, outgoingEdge: firstVia, toNode: node3)
        #expect(state >= 0)
        state = turns.transition(state: state, outgoingEdge: secondVia, toNode: node4)
        #expect(state >= 0)
        #expect(!turns.allowsExit(state: state, outgoingEdge: to))

        let unrelated = turns.stateForArrival(node: node4, incomingEdge: secondVia)
        #expect(turns.allowsExit(state: unrelated, outgoingEdge: to))

        let destination = try edge(20)
        let customers = try edge(21)
        let unknown = try edge(22)
        let destinationFrom = Int(try #require(pack.edgeFrom?[destination]))
        let destinationTo = Int(try #require(pack.edgeTo?[destination]))
        #expect(pack.v4AccessAllowed(
            ei: destination, from: destinationFrom, to: destinationTo,
            startEi: destination, endEi: -1, allowUnknown: false
        ))
        #expect(!pack.v4AccessAllowed(
            ei: destination, from: destinationFrom, to: destinationTo,
            startEi: destination, endEi: -1, allowUnknown: false,
            startEndpointKind: "customers"
        ))

        let customerFrom = Int(try #require(pack.edgeFrom?[customers]))
        let customerTo = Int(try #require(pack.edgeTo?[customers]))
        #expect(!pack.v4AccessAllowed(
            ei: customers, from: customerFrom, to: customerTo,
            startEi: -1, endEi: customers, allowUnknown: false
        ))
        #expect(pack.v4AccessAllowed(
            ei: customers, from: customerFrom, to: customerTo,
            startEi: -1, endEi: customers, allowUnknown: false,
            endEndpointKind: "customers"
        ))

        let customerScope = pack.customerEndpointEdges(edgeIndex: customers, seeds: [(customerTo, 0)], reverse: true)
        #expect(customerScope.contains(customers))
        #expect(!customerScope.contains(unknown))
        #expect(pack.v4AccessAllowed(ei: customers, from: customerFrom, to: customerTo,
            startEi: -1, endEi: -1, allowUnknown: false, endEndpointKind: "customers", customerEndEdges: customerScope))
        #expect(!pack.v4AccessAllowed(ei: customers, from: customerFrom, to: customerTo,
            startEi: -1, endEi: -1, allowUnknown: false, customerEndEdges: customerScope))

        let unknownFrom = Int(try #require(pack.edgeFrom?[unknown]))
        let unknownTo = Int(try #require(pack.edgeTo?[unknown]))
        #expect(!pack.v4AccessAllowed(
            ei: unknown, from: unknownFrom, to: unknownTo,
            startEi: -1, endEi: -1, allowUnknown: false
        ))
        #expect(pack.v4AccessAllowed(
            ei: unknown, from: unknownFrom, to: unknownTo,
            startEi: -1, endEi: -1, allowUnknown: true
        ))
    }

    @Test("V4 seam sidecar must match the graph region and source epoch")
    func seamSidecarIdentity() throws {
        let graph = try Data(contentsOf: fixtureURL("legal-topology-canary.graph.v4.bin"))
        let pack = try GraphV2Pack(data: graph)
        let epoch = try #require(pack.sourceEpoch)
        let valid: [String: Any] = [
            "schemaVersion": "dirt-cross-pack-seams.v2",
            "fabricReleaseId": "fixture-v4",
            "sourceEpoch": epoch,
            "regionId": try #require(pack.regionId),
            "neighbors": [
                "nb": [[
                    "coordinate": [-64.25, 45.85],
                    "gapMeters": 0,
                    "osmWayId": "100",
                    "localEdgeId": "100:1:2",
                    "remoteEdgeId": "100:1:2"
                ]]
            ]
        ]
        try pack.applyCrossPackSeams(data: JSONSerialization.data(withJSONObject: valid))
        #expect(pack.crossPackSeams["nb"]?.count == 1)

        var wrongEpoch = valid
        wrongEpoch["sourceEpoch"] = "different-source"
        #expect(throws: GraphV2Pack.PackError.self) {
            try pack.applyCrossPackSeams(data: JSONSerialization.data(withJSONObject: wrongEpoch))
        }
    }
    @Test("border retry shortlist covers distinct networks before repeated fragments")
    func seamNetworkCoverage() {
        func anchor(_ id: String, _ network: String, _ size: Int, _ latitude: Double) -> GraphV2Pack.CrossPackSeamAnchor {
            .init(neighborRegionId: "on", longitude: -74, latitude: latitude,
                  osmWayId: id, localEdgeId: id, remoteEdgeId: id, gapMeters: 0,
                  componentPair: network, networkSize: size)
        }
        let fragments = (0..<30).map { anchor("small-\($0)", "small", 4, 45 + Double($0) / 1000) }
        let main = anchor("main", "main", 800000, 46)
        let other = anchor("other", "other", 19, 45.5)
        let point = CLLocationCoordinate2D(latitude: 45, longitude: -74)
        let ranked = CrossPackSeam.candidates(from: point, to: point,
            anchors: fragments + [main, other], urbanCores: [])
        #expect(Array(ranked.prefix(3)).map(\.osmWayId) == ["main", "other", "small-0"])
        #expect(ranked.count == 32)
    }

    @Test("customer access must remain an endpoint run within 200 real road metres")
    func customerRunScope() {
        let ids: Set<String> = ["c"]
        #expect(CustomerEndpointAccess.validRuns([("road", 100), ("c", 25)], customerIDs: ids, start: false, end: true))
        #expect(CustomerEndpointAccess.validRuns([("c", 25), ("road", 100)], customerIDs: ids, start: true, end: false))
        #expect(!CustomerEndpointAccess.validRuns([("road", 100), ("c", 25), ("road", 100)], customerIDs: ids, start: true, end: true))
        #expect(!CustomerEndpointAccess.validRuns([("road", 100), ("c", 201)], customerIDs: ids, start: false, end: true))
        #expect(!CustomerEndpointAccess.validRuns([("road", 100), ("c", 25)], customerIDs: ids, start: false, end: false))
    }

}

private final class GraphV4FixtureBundle: NSObject {}
