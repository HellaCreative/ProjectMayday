import Foundation
import Testing
@testable import DirtRoutingEngine

struct FuelPlannerTests {
    struct Road: RoadGraph {
        var nodes: [Coordinate] = (0...6).map { .init(longitude: Double($0)*0.2,latitude: 0) }
        var nodeCount: Int { nodes.count }
        var edgeCount: Int { nodes.count-1 }
        var urbanCores: [GeographicBox] { [] }
        var restrictionIndex: RestrictionIndex { .init([]) }
        func coordinate(node: Int) -> Coordinate { nodes[node] }
        func outgoing(_ n: Int) -> [RoadArc] {
            var result: [RoadArc] = []
            if n > 0 { result.append(.init(target: n-1,edge: n-1,forward: false)) }
            if n+1 < nodes.count { result.append(.init(target: n+1,edge: n,forward: true)) }
            return result
        }
        func endpoint(_ e: Int,from: Bool) -> Int { from ? e : e+1 }
        func restrictionEdge(_ e: Int) -> Int { e }
        func edgeID(_ e: Int) -> String { "road-\(e)" }
        func distance(_ e: Int) -> Double { nodes[e].distance(to: nodes[e+1]) }
        func attributes(_ e: Int) -> UInt16 { 0 }
        func crossingTime(_ e: Int) -> Double { 0 }
        func accessCode(_ e: Int,forward: Bool) -> UInt8 { 0 }
        func surfaceLeaf(_ e: Int) -> String { "asphalt" }
        func roadClass(_ e: Int) -> String { "secondary" }
        func structure(_ e: Int) -> String { "" }
        func polyline(_ e: Int) -> [Coordinate] { [nodes[e],nodes[e+1]] }
    }
    let pumps: [FuelStation] = [0.3,0.6,0.9].map { .init(id: "pump-\($0)",coordinate: .init(longitude: $0,latitude: 0)) }
    var request: RoutingRequest { .init(start: .init(longitude: 0.01,latitude: 0),end: .init(longitude: 1.19,latitude: 0),style: .cleanest) }
    @Test func everyPumpHasAnActualBoundedRoadApproachAndOnwardRoute() throws {
        let graph = try IndexedGraph(Road())
        // Hops are ~33 km on this graph; usable range must cover a real approach
        // with no planTank slack.
        let plan = try FuelPlanner(graph: graph,stations: pumps).plan(request,requirements: .init(usableRangeMeters: 45_000,firstLegMaxMeters: 45_000))
        #expect(plan.complete)
        #expect(plan.stops.map(\.id) == pumps.map(\.id))
        #expect(plan.routes.count == 4)
        for (i,route) in plan.routes.enumerated() {
            #expect(route.distanceMeters <= 45_000)
            if i > 0 { #expect(route.start.coordinate == plan.routes[i-1].end.coordinate) }
        }
        #expect(plan.routes.last!.end.coordinate.distance(to: request.end) < 0.01)
    }
    @Test func missingPumpDoesNotProduceAFuelQualifiedRoute() throws {
        let planner = try FuelPlanner(graph: Road(),stations: [pumps[0],pumps[2]])
        let plan = try planner.plan(request,requirements: .init(usableRangeMeters: 45_000,firstLegMaxMeters: 40_000))
        #expect(!plan.complete)
        #expect(plan.foundation == nil)
        #expect(plan.limit?.contains("no fuel stop found within range") == true)
        // Proven hops before the gap may be retained; they are not an advisory A→B.
        #expect(plan.stops.count <= 1)
    }
    @Test func firstStationProbeRespectsRemainingFuel() throws {
        var fuel = FuelRequirements(usableRangeMeters: 45_000,firstLegMaxMeters: 10_000)
        fuel.probeFirstStation = true
        let plan = try FuelPlanner(graph: Road(),stations: pumps).plan(request,requirements: fuel)
        #expect(!plan.complete)
        #expect(plan.firstReachableStationMeters == nil)
    }
    @Test func arrivalFuelMustAlsoCoverDestinationEscape() throws {
        var fuel = FuelRequirements(usableRangeMeters: 45_000,firstLegMaxMeters: 40_000)
        fuel.ensureDestinationEscape = true
        let plan = try FuelPlanner(graph: Road(),stations: pumps).plan(request,requirements: fuel)
        #expect(plan.complete)
        #expect(plan.destinationEscapeMeters == nil)
        #expect(plan.routes.last!.end.coordinate.distance(to: request.end) < 0.01)
    }
    @Test func necessaryNearbyRefillsAreNotExcludedByAMinimumSpacing() throws {
        var graph = Road()
        graph.nodes = (0...6).map { .init(longitude: Double($0)*0.0002,latitude: 0) }
        let stations = [0.0003,0.0006,0.0009].map {
            FuelStation(id: "nearby-\($0)",coordinate: .init(longitude: $0,latitude: 0))
        }
        var request = RoutingRequest(start: .init(longitude: 0.00001,latitude: 0),
                                     end: .init(longitude: 0.00119,latitude: 0),style: .cleanest)
        request.matchRadiusMeters = 1
        let plan = try FuelPlanner(graph: graph,stations: stations).plan(request,
            requirements: .init(usableRangeMeters: 40,firstLegMaxMeters: 40))
        #expect(plan.complete)
        #expect(plan.stops.map(\.id) == stations.map(\.id))
        #expect(plan.routes.allSatisfy { $0.distanceMeters <= 40 })
    }
    @Test func fuelResourceExhaustionReportsExplicitFailureWithoutAdvisoryRoute() throws {
        let stations = (1...50).map {
            FuelStation(id: "dense-\($0)",coordinate: .init(longitude: Double($0)*0.02,latitude: 0))
        }
        var fuel = FuelRequirements(usableRangeMeters: 45_000,firstLegMaxMeters: 40_000)
        fuel.minimumStops = 40
        let plan = try FuelPlanner(graph: Road(),stations: stations).plan(request,requirements: fuel,
            budget: .init(seconds: 10,maximumLabels: 32))
        #expect(!plan.complete)
        #expect(plan.foundation == nil)
        #expect(plan.limit?.contains("no fuel stop found within range") == true)
    }
    @Test func firstAutomaticStopIsTheNearestReachableStation() throws {
        let plan = try FuelPlanner(graph: Road(),stations: pumps).plan(request,
            requirements: .init(usableRangeMeters: 80_000,firstLegMaxMeters: 80_000))
        #expect(plan.complete)
        #expect(plan.stops.first?.id == pumps[0].id)
    }
    @Test func laterStopsPreferUsefulOnwardProgressOverANearbyCluster() throws {
        var graph = Road()
        graph.nodes = (0...10).map { .init(longitude: Double($0)*0.1,latitude: 0) }
        let cluster = [0.05,0.051,0.052].map {
            FuelStation(id: "cluster-\($0)",coordinate: .init(longitude: $0,latitude: 0))
        }
        let onward = FuelStation(id: "onward",coordinate: .init(longitude: 0.55,latitude: 0))
        var request = RoutingRequest(start: .init(longitude: 0.01,latitude: 0),
                                     end: .init(longitude: 0.99,latitude: 0),style: .cleanest)
        request.matchRadiusMeters = 1_000
        let plan = try FuelPlanner(graph: graph,stations: cluster+[onward]).plan(request,
            requirements: .init(usableRangeMeters: 80_000,firstLegMaxMeters: 80_000))
        #expect(plan.complete)
        #expect(plan.stops.first?.id == "cluster-0.05")
        #expect(plan.stops.contains { $0.id == "onward" })
        #expect(plan.stops.filter { $0.id.hasPrefix("cluster-") }.count == 1)
    }
    @Test func windowResumeAtAPumpSkipsTheNearestFirstPumpHop() throws {
        var graph = Road()
        graph.nodes = (0...10).map { .init(longitude: Double($0)*0.1,latitude: 0) }
        let sitting = FuelStation(id: "resume-pump",coordinate: .init(longitude: 0.1,latitude: 0))
        let neighbour = FuelStation(id: "neighbour",coordinate: .init(longitude: 0.13,latitude: 0))
        let onward = FuelStation(id: "onward",coordinate: .init(longitude: 0.5,latitude: 0))
        var request = RoutingRequest(start: sitting.coordinate,
                                     end: .init(longitude: 0.99,latitude: 0),style: .cleanest)
        request.matchRadiusMeters = 8_000
        var fuel = FuelRequirements(usableRangeMeters: 80_000,firstLegMaxMeters: 80_000)
        fuel.resumeAtPump = true
        let plan = try FuelPlanner(graph: graph,stations: [sitting, neighbour, onward]).plan(request,requirements: fuel)
        #expect(plan.styleSummary?.contains("leg0:distance") != true)
        #expect(plan.styleSummary?.contains("leg0:skip") == true)
        #expect(!plan.stops.contains { $0.id == "neighbour" })
        #expect(!plan.stops.contains { $0.id == sitting.id })
        #expect(plan.stops.contains { $0.id == "onward" } || plan.complete)
    }
    @Test func laterPumpIsNotCommittedWithinFiveKmOrUnderTwentyKm() throws {
        var graph = Road()
        graph.nodes = (0...10).map { .init(longitude: Double($0)*0.1,latitude: 0) }
        let first = FuelStation(id: "first",coordinate: .init(longitude: 0.05,latitude: 0))
        let close = FuelStation(id: "close",coordinate: .init(longitude: 0.12,latitude: 0))
        let onward = FuelStation(id: "onward",coordinate: .init(longitude: 0.55,latitude: 0))
        var request = RoutingRequest(start: .init(longitude: 0.01,latitude: 0),
                                     end: .init(longitude: 0.99,latitude: 0),style: .cleanest)
        request.matchRadiusMeters = 1_000
        let plan = try FuelPlanner(graph: graph,stations: [first, close, onward]).plan(request,
            requirements: .init(usableRangeMeters: 80_000,firstLegMaxMeters: 80_000))
        #expect(plan.stops.first?.id == "first")
        #expect(!plan.stops.contains { $0.id == "close" })
        #expect(plan.stops.contains { $0.id == "onward" })
        for (index, route) in plan.routes.enumerated() where index < plan.stops.count {
            if index == 0 { continue }
            #expect(route.distanceMeters >= FuelPlanner.minimumOnwardPumpLegMeters)
            let from = index == 1 ? first.coordinate : plan.stops[index - 1].coordinate
            #expect(from.distance(to: plan.stops[index].coordinate)
                    >= FuelPlanner.minimumOnwardPumpSeparationMeters)
        }
    }
    @Test func preferredStationsAreTriedBeforeOrdinaryCandidates() throws {
        var fuel = FuelRequirements(usableRangeMeters: 80_000,firstLegMaxMeters: 80_000)
        fuel.preferredStationIDs = [pumps[1].id]
        fuel.requiredFirstStationID = pumps[0].id
        let plan = try FuelPlanner(graph: Road(),stations: pumps).plan(request,requirements: fuel)
        #expect(plan.complete)
        #expect(plan.stops.first?.id == pumps[0].id)
        #expect(plan.stops.contains { $0.id == pumps[1].id || $0.id == pumps[2].id })
    }
    @Test func indexPreservesExactMatcherResults() throws {
        let fixtures = ReferenceTests()
        let graph = try GraphPack(graphURL: fixtures.fixture("legal-topology-forecourt.graph.v4.bin"),
                                  geometryURL: fixtures.fixture("legal-topology-forecourt.geometry.v1.bin"))
        let indexed = try IndexedGraph(graph)
        for n in 0..<graph.nodeCount {
            let p = graph.coordinate(node: n)
            let a = try RoadMatcher(pack: graph).matches(at: p,radius: 2000,start: true,policy: .init(startIsCustomer: true),budget: .init())
            let b = try RoadMatcher(pack: indexed).matches(at: p,radius: 2000,start: true,policy: .init(startIsCustomer: true),budget: .init())
            #expect(a == b)
        }
    }
}
