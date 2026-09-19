import Foundation
import Testing
@testable import DirtRoutingEngine

struct RegionalGraphTests {
    func graph() throws -> GraphPack {
        let fixtures = ReferenceTests()
        return try GraphPack(graphURL: fixtures.fixture("legal-topology-restrictions.graph.v4.bin"),
                             geometryURL: fixtures.fixture("legal-topology-restrictions.geometry.v1.bin"))
    }
    func documents(_ graph: GraphPack, corrupt: Bool = false) -> [SeamDocument] {
        let anchors: [SeamDocument.Anchor] = (0..<graph.nodeCount).compactMap { n in
            guard let arc = graph.outgoing(n).first else { return nil }
            let e = arc.edge, p = graph.coordinate(node: n), structure = graph.structure(e)
            // Corrupt OSM way identity (topology). Layer/access drift alone must
            // not reject a reciprocal seam after the Maine pack join fix.
            let edge = SeamDocument.EdgeProof(osmWayId: corrupt ? "999999999" : String(graph.osmWayID(e)),
                fromOsmNodeId: String(graph.osmNodeID(graph.endpoint(e,from: true))),
                toOsmNodeId: String(graph.osmNodeID(graph.endpoint(e,from: false))),
                accessForward: graph.accessCode(e,forward: true),accessReverse: graph.accessCode(e,forward: false),
                layer: Int(graph.layers[e]),structureLeaf: structure.isEmpty ? nil : structure)
            return .init(coordinate: [p.longitude,p.latitude],gapMeters: 0,osmNodeId: String(graph.osmNodeID(n)),
                         osmWayId: edge.osmWayId,proof: "shared-osm-node-way-edge-legal-topology.v1",edge: edge,
                         barrierDecision: graph.barriers[n,default: 0])
        }
        return [SeamDocument(schemaVersion: "dirt-cross-pack-seams.v2",fabricReleaseId: "fixture",sourceEpoch: "fixture",regionId: "aa",neighbors: ["bb":anchors]),
                SeamDocument(schemaVersion: "dirt-cross-pack-seams.v2",fabricReleaseId: "fixture",sourceEpoch: "fixture",regionId: "bb",neighbors: ["aa":anchors])]
    }
    @Test func seamClaimsAreReprovedAgainstBothGraphs() throws {
        let pack = try graph()
        #expect(throws: RoutingFailure.self) {
            try RegionalGraph(graphs: [pack,pack],documents: documents(pack,corrupt: true),budget: .init())
        }
        var rows = documents(pack)
        rows[1] = .init(schemaVersion: rows[1].schemaVersion,fabricReleaseId: "fixture",sourceEpoch: "fixture",regionId: "bb",neighbors: [:])
        #expect(throws: RoutingFailure.self) {
            try RegionalGraph(graphs: [pack,pack],documents: rows,budget: .init())
        }
    }
    @Test func crossingPackIdentityDoesNotEscapeTurnRestrictions() throws {
        let pack = try graph(), joined = try RegionalGraph(graphs: [pack,pack],documents: documents(pack),budget: .init())
        let expected = try JSONDecoder().decode(ReferenceTests.Oracle.self,
            from: Data(contentsOf: ReferenceTests().fixture("legal-topology-restrictions.json")))
        var options = SearchOptions(); options.objective = .distance; options.cityWall = false
        for row in expected.routes where row.objective == "distance" {
            let right = row.end.native
            let end = RoadMatch(edge: right.edge+pack.edgeCount,coordinate: right.coordinate,distanceMeters: 0,
                                alongMeters: right.alongMeters,geometryMeters: right.geometryMeters)
            do {
                let route = try PathSearch(pack: joined).search(start: row.start.native,end: end,policy: .init(style: .balanced),
                    access: .init(startIsCustomer: row.customer,endIsCustomer: row.customer),options: options)
                #expect(row.distance != nil)
                #expect(abs(route.distanceMeters-(row.distance ?? .infinity)) < 0.01)
            } catch RoutingFailure.noPath { #expect(row.distance == nil) }
        }
    }

    @Test func sharedRoadDistanceConflictIdentifiesDataWithoutJoiningIt() throws {
        let original = try graph(), fixtures = ReferenceTests()
        let source = try BinaryFile(url: fixtures.fixture("legal-topology-restrictions.graph.v4.bin"))
        var bytes = source.data
        let edge = try #require(original.outgoing(0).first).edge
        let offset = Int(try source.read(40, as: UInt32.self)) + edge * 4
        var changed = (UInt32(original.distance(edge)) + 19).littleEndian
        withUnsafeBytes(of: &changed) { bytes.replaceSubrange(offset..<(offset + 4), with: $0) }
        let different = try GraphPack(graph: BinaryFile(data: bytes),
            geometry: BinaryFile(url: fixtures.fixture("legal-topology-restrictions.geometry.v1.bin")), budget: .init())
        do {
            _ = try RegionalGraph(graphs: [original, different], documents: documents(original), budget: .init())
            Issue.record("Conflicting distances for the same shared road must not be joined")
        } catch RoutingFailure.invalidPack(let detail) {
            #expect(detail.contains("shared road geometry differs regions=aa,bb"))
            #expect(detail.contains("way=\(original.osmWayID(edge))"))
            #expect(detail.contains("from=\(original.osmNodeID(original.endpoint(edge, from: true)))"))
            #expect(detail.contains("to=\(original.osmNodeID(original.endpoint(edge, from: false)))"))
        }
    }
}
