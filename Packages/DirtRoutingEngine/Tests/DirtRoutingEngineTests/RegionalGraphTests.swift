import Foundation
import CryptoKit
import Testing
@testable import DirtRoutingEngine

struct RegionalGraphTests {
    @Test func sharedRoadGeometryConflictCannotJoinEvenWithMatchingDistance() throws {
        let original = try graph(), fixtures = ReferenceTests()
        let graphFile = try BinaryFile(url: fixtures.fixture("legal-topology-restrictions.graph.v4.bin"))
        var geometry = try Data(contentsOf: fixtures.fixture("legal-topology-restrictions.geometry.v1.bin"))
        let edge = try #require(original.outgoing(0).first).edge
        let offset = original.geometryCoordinatesOffset + Int(original.geometryOffsets[edge]) * (original.geometryIsDouble ? 8 : 4)
        if original.geometryIsDouble {
            var changed = (original.polyline(edge)[0].longitude + 0.001).bitPattern.littleEndian
            withUnsafeBytes(of: &changed) { geometry.replaceSubrange(offset..<(offset + 8), with: $0) }
        } else {
            var changed = Float(original.polyline(edge)[0].longitude + 0.001).bitPattern.littleEndian
            withUnsafeBytes(of: &changed) { geometry.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        var graphBytes = graphFile.data
        let hashAt = Int(try graphFile.read(136, as: UInt32.self))
        graphBytes.replaceSubrange(hashAt..<(hashAt + 32), with: Data(SHA256.hash(data: geometry)))
        let different = try GraphPack(graph: BinaryFile(data: graphBytes), geometry: BinaryFile(data: geometry), budget: .init())
        #expect(original.distance(edge) == different.distance(edge))
        do {
            _ = try RegionalGraph(graphs: [original, different], documents: documents(original), budget: .init())
            Issue.record("Shared road shape conflicts must remain fatal")
        } catch RoutingFailure.invalidPack(let detail) {
            #expect(detail.contains("shared road geometry differs"))
        }
    }

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

    @Test func joinedAdjacencyReservationPreservesEveryDirectedArc() throws {
        let pack = try graph()
        let joined = try RegionalGraph(graphs: [pack, pack], documents: documents(pack), budget: .init())
        let count = try joined.adjacencyCount(budget: .init())
        #expect(count == (0..<joined.nodeCount).reduce(0) { $0 + joined.outgoing($1).count })
        let ordinary = try ArcIndex(nodeCount: joined.nodeCount, budget: .init()) { joined.outgoing($0) }
        let reserved = try ArcIndex(nodeCount: joined.nodeCount, arcCapacity: count, budget: .init()) { joined.outgoing($0) }
        #expect(reserved.outSource == ordinary.outSource)
        #expect(reserved.inStart == ordinary.inStart)
        #expect(reserved.inArcs == ordinary.inArcs)
        for node in 0...joined.nodeCount { #expect(reserved.outStart[node] == ordinary.outStart[node]) }
        for arc in 0..<count {
            #expect(reserved.outEdge[arc] == ordinary.outEdge[arc])
            #expect(reserved.targets[arc] == ordinary.targets[arc])
            #expect(reserved.forward(arc) == ordinary.forward(arc))
            #expect(reserved.distance(arc) == ordinary.distance(arc))
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
