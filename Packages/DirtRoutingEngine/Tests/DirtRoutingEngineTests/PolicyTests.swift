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
        var edgeAccess: [UInt8]? = nil
        var nodeCount: Int { nodes.count }
        var edgeCount: Int { edges.count }
        var urbanCores: [GeographicBox] = []
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
        func accessCode(_ edge: Int,forward: Bool) -> UInt8 { edgeAccess?[edge] ?? access }
        func surfaceLeaf(_ edge: Int) -> String { surfaces[edge] }
        func roadClass(_ edge: Int) -> String { roads[edge] }
        var structures: [String]? = nil
        func structure(_ edge: Int) -> String { structures?[edge] ?? "" }
        func polyline(_ edge: Int) -> [Coordinate] { [nodes[edges[edge].0],nodes[edges[edge].1]] }
    }

    @Test func cityConnectivityProofKeepsAnAvailableRideAroundTheCity() throws {
        let nodes: [Coordinate] = [
            .init(longitude: 0, latitude: 0), .init(longitude: 0.01, latitude: 0),
            .init(longitude: 0.04, latitude: 0), .init(longitude: 0.025, latitude: 0.03),
            .init(longitude: 0.05, latitude: 0)
        ]
        let graph = try IndexedGraph(Line(nodes: nodes, edges: [(0,1),(1,2),(1,3),(3,2),(2,4)],
            surfaces: Array(repeating: "asphalt", count: 5), roads: Array(repeating: "tertiary", count: 5),
            urbanCores: [.init(minLat: -0.005, maxLat: 0.005, minLon: 0.015, maxLon: 0.035, name: "city")]))
        var request = RoutingRequest(start: nodes[0], end: nodes[4], style: .cleanest)
        request.options.counter = SearchCounter()
        let route = try RoutingEngine(pack: graph).route(request)
        #expect(route.segments.contains { $0.edge == 2 })
        #expect(route.segments.contains { $0.edge == 3 })
        #expect(!route.segments.contains { $0.edge == 1 })
        #expect(request.options.counter!.stageSummary.contains("cityConnectivity"))
        #expect(!request.options.counter!.stageSummary.contains("necessaryCityConnection"))
    }

    @Test func necessaryCityConnectionPreservesStyleAndAccess() throws {
        let nodes = (0...3).map { Coordinate(longitude: Double($0) * 0.02, latitude: 0) }
        let city = GeographicBox(minLat: -0.005, maxLat: 0.005,
                                 minLon: 0.025, maxLon: 0.035, name: "required crossing")
        var graph = Line(nodes: nodes, edges: [(0,1),(1,2),(2,3)],
                         surfaces: ["asphalt", "asphalt", "asphalt"],
                         roads: ["tertiary", "tertiary", "tertiary"], urbanCores: [city])
        for style: RidingStyle in [.dirt, .balanced, .cleanest] {
            var request = RoutingRequest(start: nodes[0], end: nodes[3], style: style)
            request.options.counter = SearchCounter()
            let route = try RoutingEngine(pack: graph).route(request)
            #expect(route.end.coordinate.distance(to: nodes[3]) < 1)
            #expect(Set(route.segments.map(\.edge)) == Set([0,1,2]))
            #expect(request.options.counter!.stageSummary.contains("necessaryCityConnection"))
            #expect(request.options.counter!.stageSummary.contains("cityConnectivity"))
        }
        graph.access = 2
        #expect(throws: RoutingFailure.noMatch) {
            try RoutingEngine(pack: graph).route(.init(start: nodes[0], end: nodes[3],
                                                       style: .balanced, allowUnknown: true))
        }
    }

    @Test func cityAvoidanceKeepsAnAvailableBypass() throws {
        let nodes = [Coordinate(longitude: 0, latitude: 0),
                     .init(longitude: 0.02, latitude: 0),
                     .init(longitude: 0.04, latitude: 0),
                     .init(longitude: 0.06, latitude: 0),
                     .init(longitude: 0.02, latitude: 0.015),
                     .init(longitude: 0.04, latitude: 0.015)]
        let graph = Line(nodes: nodes, edges: [(0,1),(1,2),(2,3),(1,4),(4,5),(5,2)],
                         surfaces: Array(repeating: "asphalt", count: 6),
                         roads: Array(repeating: "tertiary", count: 6), urbanCores: [
                            .init(minLat: -0.005, maxLat: 0.005, minLon: 0.025,
                                  maxLon: 0.035, name: "avoidable town")])
        var request = RoutingRequest(start: nodes[0], end: nodes[3], style: .balanced)
        request.options.counter = SearchCounter()
        let route = try RoutingEngine(pack: graph).route(request)
        #expect(!route.segments.contains { $0.edge == 1 })
        #expect(!request.options.counter!.stageSummary.contains("necessaryCityConnection"))
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
        #expect(wide.corridorMeters(straightLine: 200_000) > wide.corridorMeters(straightLine: 50_000))
        #expect(wide.roadExtraMeters(startRemaining: 200_000)
                > tightBand.roadExtraMeters(startRemaining: 200_000) * 2)
        #expect(wide.roadSidewaysFraction() > tightBand.roadSidewaysFraction())
        #expect(wide.roadBackwardAllowanceMeters(startRemaining: 200_000)
                > tightBand.roadBackwardAllowanceMeters(startRemaining: 200_000) * 5)
        let wideGate = ProfilePolicy.progressRegressionMeters(
            style: .dirt, corridorMeters: wide.corridorMeters(straightLine: 200_000) * 2,
            hasRoadCompass: true, wander: 1)
        let tightGate = ProfilePolicy.progressRegressionMeters(
            style: .dirt, corridorMeters: tightBand.corridorMeters(straightLine: 200_000) * 2,
            hasRoadCompass: true, wander: 0)
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

    @Test func junctionDepartureCanInitiallyHeadAwayFromDestination() throws {
        // The west-facing spur is a dead end. The only continuous ride leaves
        // this junction east, then follows the roads around to the destination.
        let nodes: [Coordinate] = [
            .init(longitude: 0, latitude: 0),
            .init(longitude: -0.0004, latitude: 0.0002),
            .init(longitude: 0.01, latitude: -0.004),
            .init(longitude: 0.015, latitude: 0.01),
            .init(longitude: -0.02, latitude: 0.02)]
        let pack = Line(nodes: nodes, edges: [(0,1),(0,2),(2,3),(3,4)],
                        surfaces: Array(repeating: "asphalt", count: 4),
                        roads: Array(repeating: "tertiary", count: 4))
        let matches = try RoadMatcher(pack: pack).matches(at: nodes[0], radius: 250,
            start: true, policy: .init(), intent: nodes[0].bearing(to: nodes[4]) * 180 / .pi,
            budget: .init())
        #expect(matches.contains { $0.edge == 1 && $0.forward == true })
        let route = try RoutingEngine(pack: pack).route(.init(start: nodes[0], end: nodes[4], style: .balanced))
        #expect(route.end.coordinate.distance(to: nodes[4]) < 1)
        #expect(route.segments.filter { $0.meters > 1 }.map(\.edge) == [1,2,3])
    }

    @Test func arrivalEdgeIdentityIsHonoredAcrossIDFormats() throws {
        let pack = Line(nodes: [.init(longitude: 0,latitude: 0),.init(longitude: 0.01,latitude: 0),.init(longitude: 0.02,latitude: 0)],
                        edges: [(0,1),(1,2)], surfaces: ["asphalt","asphalt"], roads: ["tertiary","tertiary"])
        #expect(pack.edge(matching: ["line-1"]) == 1)
        #expect(pack.identity(of: 1) == "1:1:2")
        #expect(pack.edge(matching: [pack.identity(of: 1)]) == 1)
    }

    @Test func coincidentDistinctSourceNodesDoNotRepairABrokenWay() throws {
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
        #expect(indexed.coincidentSiblings(1).isEmpty)
        let start = RoadMatch(edge: 0,coordinate: pack.nodes[0],distanceMeters: 0,alongMeters: 0,
                              geometryMeters: pack.distance(0),forward: true)
        let end = RoadMatch(edge: 1,coordinate: pack.nodes[3],distanceMeters: 0,alongMeters: pack.distance(1),
                            geometryMeters: pack.distance(1),forward: true)
        #expect(throws: RoutingFailure.noPath) {
            try PathSearch(pack: indexed).search(start: start,end: end,policy: .init(style: .dirt),
                                                access: .init(),options: .init(),budget: .init())
        }
    }

    @Test func progressRegressionScalesWithWanderNotAFixedFifteenKm() {
        #expect(ProfilePolicy.progressRegressionMeters(style: .cleanest, corridorMeters: 60_000, hasRoadCompass: false).isInfinite)
        #expect(ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: .infinity, hasRoadCompass: false).isInfinite)
        let tight = ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: 60_000, hasRoadCompass: true, wander: 0)
        let full = ProfilePolicy.progressRegressionMeters(style: .dirt, corridorMeters: 60_000, hasRoadCompass: true, wander: 1)
        #expect(tight == 2_000)
        #expect(full > tight * 5)
        let balancedTight = ProfilePolicy.progressRegressionMeters(style: .balanced, corridorMeters: 240_000, hasRoadCompass: false, wander: 0)
        let balancedFull = ProfilePolicy.progressRegressionMeters(style: .balanced, corridorMeters: 240_000, hasRoadCompass: false, wander: 1)
        #expect(balancedTight == 2_000)
        #expect(balancedFull > balancedTight * 5)
    }

    @Test func shortDirtClawbackPricesNibblesAsPaved() {
        var dirt = ProfilePolicy(style: .dirt)
        dirt.minimumMeaningfulDirtMeters = 1_000
        let nibble = dirt.shortDirtClawback(contiguousDirtMeters: 300, objective: .pavement)
        let km = dirt.shortDirtClawback(contiguousDirtMeters: 1_000, objective: .pavement)
        #expect(nibble > 40) // ~0.3 km × (150 − 0.05)
        #expect(abs(km - 149.95) < 0.01)
        #expect(dirt.shortDirtClawback(contiguousDirtMeters: 0, objective: .pavement) == 0)
        #expect(dirt.shortDirtClawback(contiguousDirtMeters: 300, objective: .distance) == 0)
        var balanced = ProfilePolicy(style: .balanced)
        balanced.balancedDirtPreference = 0.5
        let mix = balanced.shortDirtClawback(contiguousDirtMeters: 300, objective: .profile)
        #expect(mix > 0)
        #expect(mix < nibble) // profile gap is smaller than dirt pavement gap
    }

    @Test func dirtEnterTransitionDiscouragesScatteredGrabs() {
        var dirt = ProfilePolicy(style: .dirt)
        let enter = dirt.dirtEnterTransitionCost(objective: .pavement)
        #expect(enter > 200)
        #expect(dirt.dirtEnterTransitionCost(objective: .distance) == 0)
        var balanced = ProfilePolicy(style: .balanced)
        balanced.balancedDirtPreference = 0.5
        let mix = balanced.dirtEnterTransitionCost(objective: .profile)
        #expect(mix > 0)
        #expect(mix < enter)
    }

    @Test func dirtEnterTransitionDilutesOnLongHops() {
        var dirt = ProfilePolicy(style: .dirt)
        let short = dirt.dirtEnterTransitionCost(objective: .pavement, hopMeters: 40_000)
        let long = dirt.dirtEnterTransitionCost(objective: .pavement, hopMeters: 200_000)
        #expect(abs(short - 280) < 0.01)
        #expect(long < short)
        // Floor at half base so uncapped From-Here legs cannot erase scrap penalties.
        #expect(abs(long - 140) < 0.01)
        #expect(long * 5 < short * 5)
    }

    @Test func shortDirtLeaveAbortPunishesIncompleteRuns() {
        var dirt = ProfilePolicy(style: .dirt)
        let nibble = dirt.shortDirtLeaveAbortCost(contiguousDirtMeters: 300, objective: .pavement)
        let useful = dirt.shortDirtLeaveAbortCost(contiguousDirtMeters: 1_500, objective: .pavement)
        let corridor = dirt.shortDirtLeaveAbortCost(contiguousDirtMeters: 2_500, objective: .pavement)
        #expect(abs(nibble - 280) < 0.01)
        #expect(useful > 0)
        #expect(useful < nibble)
        #expect(corridor == 0)
        #expect(dirt.shortDirtLeaveAbortCost(contiguousDirtMeters: 300, objective: .distance) == 0)
    }

    @Test func deferredDirtEntryPressuresEarlyDirtTurn() {
        var dirt = ProfilePolicy(style: .dirt)
        #expect(dirt.deferredDirtEntryCost(pavedWithoutMeaningfulMeters: 2_000, objective: .pavement) == 0)
        let late = dirt.deferredDirtEntryCost(pavedWithoutMeaningfulMeters: 8_000, objective: .pavement)
        #expect(late > 50) // ~5 km × 18
        #expect(dirt.deferredDirtEntryCost(pavedWithoutMeaningfulMeters: 8_000, objective: .distance) == 0)
        var balanced = ProfilePolicy(style: .balanced)
        #expect(balanced.deferredDirtEntryCost(pavedWithoutMeaningfulMeters: 8_000, objective: .profile) == 0)
    }

    @Test func earlyOpeningAwayTaxesPavedDipNotDirt() {
        let dirt = ProfilePolicy(style: .dirt)
        let start = Coordinate(longitude: -63.34, latitude: 44.76)
        let end = Coordinate(longitude: -60.49, latitude: 46.92)
        // ~1 km south of start — away from the Cape Breton pin.
        let south = Coordinate(longitude: -63.34, latitude: 44.751)
        let away = dirt.earlyOpeningAwayCost(
            from: start, to: south, end: end,
            riddenMetersBeforeArc: 0,
            achievedMeaningfulDirt: false,
            onDirt: false,
            objective: .pavement)
        #expect(away > 40)
        // Dirt payoff is exempt — dipping for dirt stays intentional.
        #expect(dirt.earlyOpeningAwayCost(
            from: start, to: south, end: end,
            riddenMetersBeforeArc: 0,
            achievedMeaningfulDirt: false,
            onDirt: true,
            objective: .pavement) == 0)
        // After first meaningful dirt, opening tax ends.
        #expect(dirt.earlyOpeningAwayCost(
            from: start, to: south, end: end,
            riddenMetersBeforeArc: 0,
            achievedMeaningfulDirt: true,
            onDirt: false,
            objective: .pavement) == 0)
        // Past the opening window, no tax.
        #expect(dirt.earlyOpeningAwayCost(
            from: start, to: south, end: end,
            riddenMetersBeforeArc: 12_000,
            achievedMeaningfulDirt: false,
            onDirt: false,
            objective: .pavement) == 0)
        // Toward the pin is free.
        let toward = Coordinate(longitude: -63.33, latitude: 44.77)
        #expect(dirt.earlyOpeningAwayCost(
            from: start, to: toward, end: end,
            riddenMetersBeforeArc: 0,
            achievedMeaningfulDirt: false,
            onDirt: false,
            objective: .pavement) == 0)
        // Short edges with small away still tax — the old >50 m floor skipped them.
        let nudge = Coordinate(longitude: -63.34, latitude: 44.7598)
        let small = dirt.earlyOpeningAwayCost(
            from: start, to: nudge, end: end,
            riddenMetersBeforeArc: 0,
            achievedMeaningfulDirt: false,
            onDirt: false,
            objective: .pavement)
        #expect(small > 0)
        #expect(small < 5)
        let balanced = ProfilePolicy(style: .balanced)
        #expect(balanced.earlyOpeningAwayCost(
            from: start, to: south, end: end,
            riddenMetersBeforeArc: 0,
            achievedMeaningfulDirt: false,
            onDirt: false,
            objective: .profile) == 0)
    }

    @Test func earlyOpeningSuspendsArterialFleeBeforeDirt() {
        let dirt = ProfilePolicy(style: .dirt)
        let pack = Line(
            nodes: [.init(longitude: 0, latitude: 0), .init(longitude: 0.01, latitude: 0)],
            edges: [(0, 1)], surfaces: ["asphalt"], roads: ["primary"])
        let start = Coordinate(longitude: 0, latitude: 0)
        let end = Coordinate(longitude: 0.2, latitude: 0.15)
        let opening = dirt.step(pack: pack, edge: 0, meters: 1_000, objective: .pavement,
                                from: start, to: pack.nodes[1], start: start, end: end,
                                startOnHighway: false, endOnHighway: false,
                                riddenMetersBeforeArc: 500, achievedMeaningfulDirt: false)
        let afterDirt = dirt.step(pack: pack, edge: 0, meters: 1_000, objective: .pavement,
                                  from: start, to: pack.nodes[1], start: start, end: end,
                                  startOnHighway: false, endOnHighway: false,
                                  riddenMetersBeforeArc: 500, achievedMeaningfulDirt: true)
        let collector = Line(
            nodes: [.init(longitude: 0, latitude: 0), .init(longitude: 0.01, latitude: 0)],
            edges: [(0, 1)], surfaces: ["asphalt"], roads: ["secondary"])
        let collectorCost = dirt.step(pack: collector, edge: 0, meters: 1_000, objective: .pavement,
                                      from: start, to: collector.nodes[1], start: start, end: end,
                                      startOnHighway: false, endOnHighway: false,
                                      riddenMetersBeforeArc: 500, achievedMeaningfulDirt: false)
        // Before meaningful dirt, primary matches collector — no ×8 flee.
        #expect(abs(opening - collectorCost) < 0.01)
        // After meaningful dirt, arterial avoidance returns.
        #expect(afterDirt > opening * 5)
    }

    @Test func prefersDirtRejectsScrapInflatedCandidates() {
        var scraps = RouteQuality()
        scraps.knownDirtPercent = 64
        scraps.shortDirtScrapMeters = 2_400
        scraps.leadingPavedMeters = 18_000
        var continuous = RouteQuality()
        continuous.knownDirtPercent = 60
        continuous.shortDirtScrapMeters = 0
        continuous.leadingPavedMeters = 2_000
        #expect(RouteQuality.prefersDirt(continuous, over: scraps, widthA: .infinity, widthB: .infinity))
        #expect(!RouteQuality.prefersDirt(scraps, over: continuous, widthA: .infinity, widthB: .infinity))
    }

    @Test func shortDirtExcursionsCatchUsefulLengthScraps() {
        func seg(_ id: String, _ meters: Double, _ surface: Surface) -> RouteSegment {
            RouteSegment(edge: 0, edgeID: id, forward: true, meters: meters, surface: surface,
                         surfaceLeaf: surface == .paved ? "asphalt" : "dirt", roadClass: "track",
                         structure: "", access: 0, geometry: [])
        }
        let scraps = [
            seg("p0", 500, .paved),
            seg("d0", 1_200, .loose),
            seg("p1", 500, .paved),
            seg("d1", 3_000, .loose),
            seg("p2", 500, .paved)
        ]
        let flagged = RouteQuality.shortDirtExcursions(scraps)
        #expect(flagged.contains("d0"))
        #expect(!flagged.contains("d1"))
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

    @Test func reriddenMetersCountsEveryRepeatOfARoad() {
        func seg(_ id: String, _ meters: Double, forward: Bool = true) -> RouteSegment {
            RouteSegment(edge: 0, edgeID: id, forward: forward, meters: meters, surface: .paved,
                         surfaceLeaf: "asphalt", roadClass: "tertiary", structure: "", access: 0, geometry: [])
        }
        // Consecutive splits of one edge are one run, so nothing is re-ridden.
        #expect(RouteQuality.reriddenMeters([seg("a", 200), seg("a", 200), seg("b", 500)]) == 0)
        // Coming back down the same road is its return leg.
        #expect(RouteQuality.reriddenMeters([seg("a", 400), seg("b", 400), seg("a", 400, forward: false)]) == 400)
    }

    @Test func returnMetersSeesALoopOnDifferentRoadsAndIgnoresAStraightRun() {
        func chain(_ points: [Coordinate]) -> [RouteSegment] {
            zip(points, points.dropFirst()).enumerated().map { index, pair in
                RouteSegment(edge: index, edgeID: "e\(index)", forward: true,
                             meters: pair.0.distance(to: pair.1), surface: .paved, surfaceLeaf: "asphalt",
                             roadClass: "tertiary", structure: "", access: 0, geometry: [pair.0, pair.1])
            }
        }
        // 20 km straight north: never returns to anywhere it has been.
        let straight = (0...20).map { Coordinate(longitude: -63, latitude: 45 + Double($0) * 0.009) }
        #expect(RouteQuality.returnMeters(chain(straight)) == 0)
        // 15 km north, then back south on a road 400 m to the side: the return counts,
        // and no edge id repeats, so edge reuse alone would report nothing.
        var loop = (0...15).map { Coordinate(longitude: -63, latitude: 45 + Double($0) * 0.009) }
        loop += (0...15).reversed().map { Coordinate(longitude: -63.005, latitude: 45 + Double($0) * 0.009) }
        let segments = chain(loop)
        #expect(RouteQuality.reriddenMeters(segments) == 0)
        #expect(RouteQuality.returnMeters(segments) > 5_000)
    }

    @Test func shapeFaultsCatchOutAndBackAndIgnoreSplitRuns() {
        func seg(_ id: String, _ meters: Double, forward: Bool = true) -> RouteSegment {
            RouteSegment(edge: 0, edgeID: id, forward: forward, meters: meters, surface: .paved,
                         surfaceLeaf: "asphalt", roadClass: "tertiary", structure: "", access: 0, geometry: [])
        }
        #expect(RouteQuality.shapeFaults([seg("a", 500), seg("b", 500), seg("c", 500)]).issueCount == 0)
        #expect(RouteQuality.shapeFaults([seg("a", 200), seg("a", 200), seg("b", 500)]).issueCount == 0)
        let back = RouteQuality.shapeFaults([seg("a", 400), seg("b", 400), seg("a", 400, forward: false)])
        #expect(back.reusedEdgeIDs.contains("a"))
        #expect(back.issueCount >= 1)
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
