import Foundation
import Testing
@testable import DirtRoutingEngine

struct PolicyTests {
    struct Line: RoadGraph {
        let nodes: [Coordinate]
        let edges: [(Int,Int)]
        var surfaces: [String]
        var roads: [String]
        var access: UInt8 = 0
        var nodeCount: Int { nodes.count }
        var edgeCount: Int { edges.count }
        var urbanCores: [GeographicBox] { [] }
        var restrictionIndex: RestrictionIndex { .init([]) }
        func coordinate(node: Int) -> Coordinate { nodes[node] }
        func outgoing(_ node: Int) -> [RoadArc] {
            edges.enumerated().flatMap { i,e -> [RoadArc] in
                if e.0 == node { return [.init(target: e.1,edge: i,forward: true)] }
                if e.1 == node { return [.init(target: e.0,edge: i,forward: false)] }
                return []
            }
        }
        func endpoint(_ edge: Int,from: Bool) -> Int { from ? edges[edge].0 : edges[edge].1 }
        func restrictionEdge(_ edge: Int) -> Int { edge }
        func edgeID(_ edge: Int) -> String { "line-\(edge)" }
        func distance(_ edge: Int) -> Double { nodes[edges[edge].0].distance(to: nodes[edges[edge].1]) }
        func attributes(_ edge: Int) -> UInt16 { 0 }
        func crossingTime(_ edge: Int) -> Double { 0 }
        func accessCode(_ edge: Int,forward: Bool) -> UInt8 { access }
        func surfaceLeaf(_ edge: Int) -> String { surfaces[edge] }
        func roadClass(_ edge: Int) -> String { roads[edge] }
        func structure(_ edge: Int) -> String { "" }
        func polyline(_ edge: Int) -> [Coordinate] { [nodes[edges[edge].0],nodes[edges[edge].1]] }
    }

    @Test func wanderSoftensDirtAwayCostWithoutChangingSurfaceWeights() {
        var policy = ProfilePolicy(style: .dirt)
        let pack = Line(nodes: [.init(longitude: 0,latitude: 0),.init(longitude: -0.05,latitude: 0)],
                        edges: [(0,1)], surfaces: ["asphalt"], roads: ["tertiary"])
        let start = Coordinate(longitude: 0,latitude: 0), end = Coordinate(longitude: 0.2,latitude: 0)
        policy.wander = 1
        let full = policy.step(pack: pack,edge: 0,meters: 1000,objective: .pavement,
                               from: start,to: pack.nodes[1],start: start,end: end,startOnHighway: false,endOnHighway: false)
        policy.wander = 0
        let tight = policy.step(pack: pack,edge: 0,meters: 1000,objective: .pavement,
                                from: start,to: pack.nodes[1],start: start,end: end,startOnHighway: false,endOnHighway: false)
        #expect(full < tight)
        #expect(tight / full > 4)
        var wide = ProfilePolicy(style: .dirt); wide.wander = 1
        var tightBand = ProfilePolicy(style: .dirt); tightBand.wander = 0
        #expect(wide.corridorMeters(straightLine: 200_000) > tightBand.corridorMeters(straightLine: 200_000) * 3)
        let wideGate = ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: wide.corridorMeters(straightLine: 200_000) * 2, hasRoadCompass: true)
        let tightGate = ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: tightBand.corridorMeters(straightLine: 200_000) * 2, hasRoadCompass: true)
        #expect(wideGate > tightGate)
        policy.wander = 1
        let dirt = policy.step(pack: pack,edge: 0,meters: 1000,objective: .pavement,
                               from: start,to: Coordinate(longitude: 0.01,latitude: 0),start: start,end: end,
                               startOnHighway: false,endOnHighway: false)
        var balanced = ProfilePolicy(style: .balanced); balanced.wander = 1
        let mix = balanced.step(pack: pack,edge: 0,meters: 1000,objective: .profile,
                                from: start,to: Coordinate(longitude: 0.01,latitude: 0),start: start,end: end,
                                startOnHighway: false,endOnHighway: false)
        #expect(dirt > mix * 5)
    }

    @Test func destinationIntentPrefersArrivalFacingTravel() throws {
        let pack = Line(nodes: [.init(longitude: 0,latitude: 0),.init(longitude: 0.01,latitude: 0)],
                        edges: [(0,1)], surfaces: ["asphalt"], roads: ["tertiary"])
        let a = Coordinate(longitude: -0.001,latitude: 0), b = Coordinate(longitude: 0.011,latitude: 0)
        let intent = a.bearing(to: b)*180 / .pi
        let matcher = RoadMatcher(pack: pack)
        let starts = try matcher.matches(at: a,radius: 2000,start: true,policy: .init(),intent: intent,budget: .init())
        let ends = try matcher.matches(at: b,radius: 2000,start: false,policy: .init(),intent: intent+180,budget: .init())
        #expect(!starts.isEmpty && !ends.isEmpty)
        #expect(starts.first?.forward == true)
        #expect(ends.first?.forward == false)
    }

    @Test func oppositeCarriagewayIsSuppressedByIntent() throws {
        let pack = Line(nodes: [
            .init(longitude: 0,latitude: 0.0004),.init(longitude: 0.01,latitude: 0.0004),
            .init(longitude: 0,latitude: -0.0004),.init(longitude: 0.01,latitude: -0.0004)
        ], edges: [(0,1),(2,3)], surfaces: ["asphalt","asphalt"], roads: ["motorway","motorway"])
        let point = Coordinate(longitude: 0.005,latitude: 0)
        let matches = try RoadMatcher(pack: pack).matches(at: point,radius: 200,start: true,policy: .init(),
                                                          intent: 90,budget: .init())
        #expect(!matches.isEmpty)
        #expect(matches.allSatisfy { match in
            guard let forward = match.forward else { return false }
            let bearing = RoadMatcher.travelBearing(pack.polyline(match.edge), along: match.alongMeters, forward: forward)
            return RoadMatcher.angle(90, bearing) < 70
        })
    }

    @Test func arrivalEdgeIdentityIsHonoredAcrossIDFormats() throws {
        let pack = Line(nodes: [.init(longitude: 0,latitude: 0),.init(longitude: 0.01,latitude: 0),.init(longitude: 0.02,latitude: 0)],
                        edges: [(0,1),(1,2)], surfaces: ["asphalt","asphalt"], roads: ["tertiary","tertiary"])
        #expect(pack.edge(matching: ["line-1"]) == 1)
        #expect(pack.identity(of: 1) == "1:1:2")
        #expect(pack.edge(matching: [pack.identity(of: 1)]) == 1)
    }

    @Test func coincidentDuplicateNodesKeepABrokenWayConnected() throws {
        let pack = Line(
            nodes: [
                .init(longitude: 0,latitude: 0),
                .init(longitude: 0.01,latitude: 0),
                .init(longitude: 0.01,latitude: 0),
                .init(longitude: 0.02,latitude: 0)
            ],
            edges: [(0,1),(2,3)],
            surfaces: ["dirt","dirt"],
            roads: ["track","track"]
        )
        let indexed = try IndexedGraph(pack)
        #expect(!indexed.coincidentSiblings(1).isEmpty)
        #expect(indexed.coincidentSiblings(1).contains(2))
        let start = RoadMatch(edge: 0,coordinate: pack.nodes[0],distanceMeters: 0,alongMeters: 0,
                              geometryMeters: pack.distance(0),forward: true)
        let end = RoadMatch(edge: 1,coordinate: pack.nodes[3],distanceMeters: 0,alongMeters: pack.distance(1),
                            geometryMeters: pack.distance(1),forward: true)
        let route = try PathSearch(pack: indexed).search(start: start,end: end,policy: .init(style: .dirt),
                                                        access: .init(),options: .init(),budget: .init())
        #expect(route.distanceMeters > 0)
    }

    @Test func progressRegressionMatchesJavaScript() {
        #expect(ProfilePolicy.progressRegressionMeters(style: .cleanest, corridorMeters: 60_000, hasRoadCompass: false).isInfinite)
        #expect(ProfilePolicy.progressRegressionMeters(style: .balanced, corridorMeters: 240_000, hasRoadCompass: false) == 10_000)
        #expect(ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: 60_000, hasRoadCompass: false) == 15_000)
        #expect(ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: 120_000, hasRoadCompass: false) == 30_000)
        #expect(ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: 240_000, hasRoadCompass: false) == 60_000)
        #expect(ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: .infinity, hasRoadCompass: false).isInfinite)
        #expect(ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: 60_000, hasRoadCompass: true) == 15_000)
    }

    @Test func dirtPavementAwayScalesWithWander() {
        var policy = ProfilePolicy(style: .dirt)
        policy.wander = 0
        let tight = policy.approachAway(fromRemaining: 80_000, toRemaining: 81_000, startRemaining: 200_000, objective: .pavement)
        #expect(abs(tight - 95) < 0.01)
        policy.wander = 1
        let full = policy.approachAway(fromRemaining: 80_000, toRemaining: 81_000, startRemaining: 200_000, objective: .pavement)
        #expect(abs(full - 9.5 * policy.dirtPavementAwayAtFullWander) < 0.01)
        #expect(full < tight)
        let geodesic = policy.waypointPull(from: .init(longitude: 0, latitude: 0),
                                           to: .init(longitude: -0.01, latitude: 0),
                                           start: .init(longitude: 0, latitude: 0),
                                           end: .init(longitude: 0.2, latitude: 0),
                                           meters: 1000, objective: .pavement)
        #expect(tight > geodesic)
    }

    @Test func roadCompassIsExactDistanceOnALine() throws {
        let pack = Line(nodes: [.init(longitude: 0,latitude: 0),.init(longitude: 0.01,latitude: 0),.init(longitude: 0.02,latitude: 0)],
                        edges: [(0,1),(1,2)], surfaces: ["asphalt","asphalt"], roads: ["tertiary","tertiary"])
        let end = RoadMatch(edge: 1,coordinate: pack.nodes[2],distanceMeters: 0,alongMeters: pack.distance(1),
                            geometryMeters: pack.distance(1),forward: true)
        let compass = try RoadCompass.toward(end: end, pack: pack, budget: .init())
        #expect(abs(compass[2]) < 1)
        #expect(abs(compass[0] - pack.distance(0) - pack.distance(1)) < 1)
        let store = RoadCompassStore()
        let key = "1:\(end.alongMeters):false"
        let first = store.remaining(for: key) { compass.remaining }
        let second = store.remaining(for: key) {
            Issue.record("compass rebuilt for the same destination")
            return compass.remaining
        }
        #expect(first[0] == second[0])
    }

    @Test func defaultMetroWallIncludesHalifax() {
        let halifax = Coordinate(longitude: -63.58,latitude: 44.65)
        let start = Coordinate(longitude: -63.34,latitude: 44.76)
        let end = Coordinate(longitude: -67.29,latitude: 45.26)
        #expect(UrbanCores.defaults.contains { $0.contains(halifax) && !$0.contains(start) && !$0.contains(end) })
    }

    @Test func longChainCompletesWithBoundedAncestorWalk() throws {
        let count = 300
        let nodes = (0...count).map { Coordinate(longitude: Double($0) * 0.001, latitude: 0) }
        let edges = (0..<count).map { ($0, $0 + 1) }
        let surfaces = (0..<count).map { $0 % 3 == 0 ? "dirt" : "asphalt" }
        let roads = [String](repeating: "tertiary", count: count)
        let pack = Line(nodes: nodes, edges: edges, surfaces: surfaces, roads: roads)
        let start = RoadMatch(edge: 0, coordinate: nodes[0], distanceMeters: 0,
                              alongMeters: 0, geometryMeters: pack.distance(0), forward: true)
        let end = RoadMatch(edge: count - 1, coordinate: nodes[count], distanceMeters: 0,
                            alongMeters: pack.distance(count - 1),
                            geometryMeters: pack.distance(count - 1), forward: true)
        var options = SearchOptions()
        options.cityWall = false; options.corridorMeters = .infinity
        let route = try PathSearch(pack: pack).search(
            start: start, end: end, policy: .init(style: .dirt),
            access: .init(), options: options, budget: .init())
        #expect(route.distanceMeters > 0)
        #expect(route.segments.count == count)
    }
}
