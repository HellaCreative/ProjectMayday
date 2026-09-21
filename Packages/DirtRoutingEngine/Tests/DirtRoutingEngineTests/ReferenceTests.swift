import Foundation
import Testing
@testable import DirtRoutingEngine

struct ReferenceTests {
    struct Oracle: Decodable {
        struct Edge: Decodable {
            struct Leaves: Decodable { let surfaceLeaf: String?; let roadClassLeaf: String }
            let id: String; let from: Int; let to: Int; let meters: Double
            let forward: UInt8; let reverse: UInt8; let way: String; let leaves: Leaves
        }
        struct Turn: Decodable {
            struct Active: Decodable { let id: Int; let progress: Int }
            let node: Int; let from: Int; let to: Int; let allowed: Bool; let active: [Active]
        }
        struct Route: Decodable {
            struct Match: Decodable {
                let edgeIndex: Int; let coord: [Double]; let distanceAlongM: Double; let edgeMeters: Double
                var native: RoadMatch { .init(edge: edgeIndex,coordinate: .init(longitude: coord[0],latitude: coord[1]),
                                             distanceMeters: 0,alongMeters: distanceAlongM,geometryMeters: edgeMeters) }
            }
            let start: Match; let end: Match; let customer: Bool; let distance: Double?; let edgeIDs: [String]
            let style: String; let objective: String
        }
        let nodeCount: Int; let edgeCount: Int; let arcCount: Int
        let graphHash: String; let geometryHash: String
        let edges: [Edge]; let turns: [Turn]
        let routes: [Route]
    }
    @Test(arguments: cases) func actualPathsMatchExecutedJavaScript(_ name: String) throws {
        let oracle = try JSONDecoder().decode(Oracle.self,from: Data(contentsOf: fixture(name+".json")))
        let pack = try GraphPack(graphURL: fixture(name+".graph.v4.bin"),geometryURL: fixture(name+".geometry.v1.bin"))
        var options = SearchOptions()
        options.objective = .distance; options.cityWall = false; options.varietyEnabled = false
        var policy = ProfilePolicy(style: .balanced)
        policy.avoidMajorHighways = false; policy.preferBackRoads = false
        for expected in oracle.routes {
            options.objective = SearchObjective(rawValue: expected.objective)!
            policy.style = RidingStyle(rawValue: expected.style)!
            let context = "\(name): \(expected.start.edgeIndex)→\(expected.end.edgeIndex), customer=\(expected.customer) \(expected.style)/\(expected.objective)"
            do {
                let route = try PathSearch(pack: pack).search(start: expected.start.native,end: expected.end.native,policy: policy,
                    access: .init(startIsCustomer: expected.customer,endIsCustomer: expected.customer),options: options)
                #expect(expected.distance != nil, "Unexpected path: \(context)")
                #expect(abs(route.distanceMeters-(expected.distance ?? .infinity)) < 0.01, "Distance: \(context)")
                #expect(route.segments.map(\.edgeID) == expected.edgeIDs, "Edges: \(context)")
            } catch RoutingFailure.noPath {
                #expect(expected.distance == nil, "Missing path: \(context)")
            }
        }
    }
    @Test(arguments: cases) func bidirectionalProofNeverRejectsAnOraclePath(_ name: String) throws {
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: fixture(name + ".json")))
        let pack = try GraphPack(graphURL: fixture(name + ".graph.v4.bin"),
                                geometryURL: fixture(name + ".geometry.v1.bin"))
        let checker = try EndpointReachability(graph: pack, budget: .init())
        for expected in oracle.routes where expected.distance != nil {
            #expect(try checker.mayConnectBidirectionally(start: expected.start.native,
                end: expected.end.native, budget: .init()))
        }
    }
    static let cases = ["legal-topology-canary", "legal-topology-forecourt", "legal-topology-forecourt-blocked", "legal-topology-restrictions"]
    func fixture(_ name: String) -> URL { Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")! }
    @Test(arguments: cases) func decodeAndTransitionsMatchExecutedJavaScript(_ name: String) throws {
        let expected = try JSONDecoder().decode(Oracle.self,from: Data(contentsOf: fixture(name+".json")))
        let pack = try GraphPack(graphURL: fixture(name+".graph.v4.bin"),geometryURL: fixture(name+".geometry.v1.bin"))
        #expect(pack.nodeCount == expected.nodeCount)
        #expect(pack.edgeCount == expected.edgeCount)
        #expect(pack.arcCount == expected.arcCount)
        #expect(pack.graphSHA256 == expected.graphHash)
        #expect(pack.geometrySHA256 == expected.geometryHash)
        for (i,e) in expected.edges.enumerated() {
            #expect(pack.edgeID(i) == e.id)
            #expect(pack.edgeFrom[i] == e.from && pack.edgeTo[i] == e.to)
            #expect(pack.distance(i) == e.meters)
            #expect(pack.accessCode(i,forward: true) == e.forward)
            #expect(pack.accessCode(i,forward: false) == e.reverse)
            #expect(String(pack.osmWayID(i)) == e.way)
            #expect(pack.surfaceLeaf(i) == (e.leaves.surfaceLeaf ?? ""))
            #expect(pack.roadClass(i) == e.leaves.roadClassLeaf)
            let validGeometry = pack.polyline(i).allSatisfy { $0.isValid }
            #expect(validGeometry)
        }
        for t in expected.turns {
            let actual = pack.restrictionIndex.advance([],from: t.from,to: t.to,at: t.node)
            #expect((actual != nil) == t.allowed)
            if let actual {
                #expect(actual == t.active.map { .init(pattern: $0.id,progress: $0.progress) })
            }
        }
    }
    @Test func mismatchedGeometryIsRejected() throws {
        #expect(throws: RoutingFailure.self) {
            try GraphPack(graphURL: fixture("legal-topology-canary.graph.v4.bin"),
                          geometryURL: fixture("legal-topology-forecourt.geometry.v1.bin"))
        }
    }
    @Test func malformedHeadersAreErrorsRatherThanMemoryAccesses() throws {
        for n in 0..<140 {
            #expect(throws: RoutingFailure.self) {
                try GraphPack(graph: BinaryFile(data: Data(repeating: 0,count: n)),geometry: BinaryFile(data: Data()),budget: .init())
            }
        }
    }
    @Test func viaWayStateIsScopedToActualArrival() {
        let index = RestrictionIndex([.init(relationID: 9,fromEdge: 0,toEdge: 3,viaNode: 1,viaEdges: [1,2],only: false)])
        let first = index.advance([],from: 0,to: 1,at: 1)!
        let second = index.advance(first,from: 1,to: 2,at: 2)!
        #expect(index.advance(second,from: 2,to: 3,at: 3) == nil)
        #expect(index.advance([],from: 2,to: 3,at: 3) == [])
        #expect(index.advance(first,from: 1,to: 4,at: 2) == [])
    }
    @Test func expiredBudgetStopsPreparation() throws {
        #expect(throws: RoutingFailure.resourceLimit("time")) {
            try GraphPack(graphURL: fixture("legal-topology-canary.graph.v4.bin"),
                          geometryURL: fixture("legal-topology-canary.geometry.v1.bin"),budget: .init(seconds: 0))
        }
    }
}
