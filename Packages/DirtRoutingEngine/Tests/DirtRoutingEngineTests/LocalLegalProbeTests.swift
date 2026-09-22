import Foundation
import Testing
@testable import DirtRoutingEngine

struct LocalLegalProbeTests {
    // Reuse independent factory/reference fixtures, including one-way roads,
    // customer access and via-way restrictions, rather than a second algorithm.
    @Test(arguments: ReferenceTests.cases)
    func preservesOracleLegalConnections(_ name: String) throws {
        let fixture = ReferenceTests()
        let oracle = try JSONDecoder().decode(ReferenceTests.Oracle.self,
            from: Data(contentsOf: fixture.fixture(name + ".json")))
        let graph = try GraphPack(graphURL: fixture.fixture(name + ".graph.v4.bin"),
            geometryURL: fixture.fixture(name + ".geometry.v1.bin"))
        let engine = RoutingEngine(pack: graph)
        for row in oracle.routes {
            var request = RoutingRequest(start: row.start.native.coordinate,
                end: row.end.native.coordinate, style: RidingStyle(rawValue: row.style)!)
            request.profile.avoidMajorHighways = false
            request.profile.preferBackRoads = false
            request.access = .init(startIsCustomer: row.customer, endIsCustomer: row.customer)
            request.options.varietyEnabled = false
            let possible = try engine.localLegalConnectionPossible(request,
                start: row.start.native, end: row.end.native, budget: .init())
            #expect(possible == (row.distance != nil), "Oracle connection: \(name), customer=\(row.customer)")
        }
    }

    private func line(structure: String = "", access: UInt8 = 0) -> PolicyTests.Line {
        .init(nodes: (0...3).map { .init(longitude: Double($0) * 0.02, latitude: 0) },
            edges: [(0,1),(1,2),(2,3)], surfaces: Array(repeating: "asphalt", count: 3),
            roads: Array(repeating: "tertiary", count: 3), edgeAccess: [0,access,0],
            urbanCores: [.init(minLat: -0.005, maxLat: 0.005,
                minLon: 0.025, maxLon: 0.035, name: "required town")],
            structures: ["",structure,""])
    }

    private func possible(_ line: PolicyTests.Line, _ configure: (inout RoutingRequest) -> Void) throws -> Bool {
        let start = RoadMatch(edge: 0, coordinate: line.nodes[0], distanceMeters: 0,
            alongMeters: 0, geometryMeters: line.distance(0), forward: true)
        let end = RoadMatch(edge: 2, coordinate: line.nodes[3], distanceMeters: 0,
            alongMeters: line.distance(2), geometryMeters: line.distance(2), forward: true)
        var request = RoutingRequest(start: start.coordinate, end: end.coordinate, style: .dirt)
        configure(&request)
        return try RoutingEngine(pack: IndexedGraph(line)).localLegalConnectionPossible(request,
            start: start, end: end, budget: .init())
    }

    @Test func scenicBoundsDoNotRejectNecessaryTownConnection() throws {
        #expect(try possible(line()) { request in
            request.options.cityWall = true
            request.options.maximumMeters = 1
            request.options.corridorMeters = 1
            request.options.extentCenter = request.start
            request.options.maxExtentMeters = 1
            request.options.avoidCircuitNodes = [1,2]
            request.options.preventLocalCircuits = true
        })
    }

    @Test func ferryNeedsExplicitPermissionAndCannotOverrideBlockedAccess() throws {
        #expect(try !possible(line(structure: "ferry")) { $0.access.avoidFerries = true })
        #expect(try possible(line(structure: "ferry")) { $0.access.avoidFerries = false })
        #expect(try !possible(line(structure: "ferry", access: 2)) {
            $0.access.avoidFerries = false
            $0.access.allowUnknown = true
        })
    }

    @Test func riderAvoidedRoadRemainsForbidden() throws {
        #expect(try !possible(line()) { $0.options.avoidEdges = ["line-1"] })
    }

    @Test func cancelledProbeDoesNotBecomeUnknownOrSuccess() async {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try possible(line()) { _ in }
                Issue.record("Cancelled probe returned a result")
            } catch is CancellationError { }
            catch { Issue.record("Unexpected error: \(error)") }
        }.value
    }
}
