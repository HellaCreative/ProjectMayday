import Foundation
import Testing
@testable import DirtRoutingEngine

struct CityDistanceBoundTests {
    @Test func lowerBoundUsesExistingCityTaxButAllowsUntaxedDetour() throws {
        let nodes: [Coordinate] = [
            .init(longitude: -0.03, latitude: 0), .init(longitude: -0.02, latitude: 0),
            .init(longitude: 0.02, latitude: 0), .init(longitude: 0.03, latitude: 0),
            .init(longitude: -0.02, latitude: 0.03), .init(longitude: 0.02, latitude: 0.03),
            .init(longitude: 1, latitude: 1)]
        let line = PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(2,3),(1,4),(4,5),(5,2),(3,6)],
            surfaces: Array(repeating: "asphalt", count: 7), roads: Array(repeating: "tertiary", count: 7))
        let start = RoadMatch(edge: 0, coordinate: nodes[0], distanceMeters: 0,
            alongMeters: 0, geometryMeters: line.distance(0))
        let end = RoadMatch(edge: 2, coordinate: nodes[3], distanceMeters: 0,
            alongMeters: line.distance(2), geometryMeters: line.distance(2))
        let cores = [GeographicBox(minLat: -0.005, maxLat: 0.005, minLon: -0.005, maxLon: 0.005, name: "city")]
        let bound = try RoadCompass.cityDistanceLowerBound(start: start, end: end,
            pack: line, cores: cores, multiplier: 120, budget: .init())
        let detour = line.distance(3) + line.distance(4) + line.distance(5)
        #expect(abs(bound[1] - detour) < 0.001)
        #expect(bound[1] < line.distance(1) * 120)
        #expect(bound[0] == bound[1])
        #expect(bound[2] == 0 && bound[3] == 0)
        #expect(bound[6] == bound[1])
        #expect(bound[6] < line.distance(6))
        var blocked = line
        blocked.edgeAccess = [0,0,0,0,2,0,0]
        let closedBound = try RoadCompass.cityDistanceLowerBound(start: start, end: end,
            pack: blocked, cores: cores, multiplier: 120, budget: .init())
        #expect(abs(closedBound[1] - line.distance(1) * 120) < 0.001)
        blocked.edgeAccess = [0,0,0,0,1,0,0]
        let unknownBound = try RoadCompass.cityDistanceLowerBound(start: start, end: end,
            pack: blocked, cores: cores, multiplier: 120, budget: .init())
        #expect(unknownBound[1] == bound[1])
        blocked.edgeAccess = nil
        blocked.structures = ["", "", "", "", "ferry", "", ""]
        let landBound = try RoadCompass.cityDistanceLowerBound(start: start, end: end,
            pack: blocked, cores: cores, multiplier: 120, avoidFerries: true, budget: .init())
        #expect(landBound[1] == closedBound[1])

    }

    @Test(arguments: ReferenceTests.cases) func endpointRelaxationNeverOverstatesOracleDistance(_ name: String) throws {
        let fixtures = ReferenceTests()
        let raw = try GraphPack(graphURL: fixtures.fixture(name + ".graph.v4.bin"),
                                geometryURL: fixtures.fixture(name + ".geometry.v1.bin"))
        let oracle = try JSONDecoder().decode(ReferenceTests.Oracle.self,
            from: Data(contentsOf: fixtures.fixture(name + ".json")))
        for expected in oracle.routes where expected.objective == "distance" && expected.distance != nil {
            let start = expected.start.native, end = expected.end.native
            let bound = try RoadCompass.cityDistanceLowerBound(start: start, end: end,
                pack: raw, cores: [], multiplier: 120, budget: .init())
            let a = raw.endpoint(start.edge, from: true), b = raw.endpoint(start.edge, from: false)
            #expect(min(bound[a], bound[b]) <= expected.distance! + 0.001)
        }
    }
}
