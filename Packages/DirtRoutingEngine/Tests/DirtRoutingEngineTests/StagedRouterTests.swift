import Foundation
import CryptoKit
import Testing
@testable import DirtRoutingEngine

struct StagedRouterTests {
    @Test func seamSearchMustArriveInTheProvedOnwardDirection() throws {
        let graph = PolicyTests.Line(nodes: [
            .init(longitude: 0, latitude: 0), .init(longitude: 0.001, latitude: 0),
            .init(longitude: 0.002, latitude: 0), .init(longitude: 0.001, latitude: 0.001)
        ], edges: [(0,1), (1,2), (1,3), (3,2)],
            surfaces: Array(repeating: "gravel", count: 4), roads: Array(repeating: "track", count: 4))
        let length = graph.polyline(0)[0].distance(to: graph.polyline(0)[1])
        let start = RoadMatch(edge: 0, coordinate: .init(longitude: 0.0005, latitude: 0),
            distanceMeters: 0, alongMeters: length / 2, geometryMeters: length, forward: true)
        for fraction in [0.0, 0.5] {
            let end = RoadMatch(edge: 1, coordinate: .init(longitude: 0.001 + fraction * 0.001, latitude: 0),
                distanceMeters: 0, alongMeters: length * fraction, geometryMeters: length, forward: true)
            var options = SearchOptions(); options.objective = .distance; options.cityWall = false
            options.requiredArrivalRoads = [graph.identity(of: 1)]
            options.requiredArrivalDirections = [graph.identity(of: 1) + "|0"]
            let result = try PathSearch(pack: graph).search(start: start, end: end,
                policy: .init(style: .dirt), access: .init(), options: options)
            #expect(result.segments.last?.edge == 1)
            #expect(result.segments.last?.forward == false)
            #expect(result.segments.contains { $0.edge == 3 })
            var denied = graph
            denied.reverseAccess = [0, 2, 0, 0]
            #expect(throws: RoutingFailure.noPath) {
                try PathSearch(pack: denied).search(start: start, end: end,
                    policy: .init(style: .dirt), access: .init(), options: options)
            }
            if fraction == 0.5 {
                options.requiredArrivalRoads = []
                options.requiredArrivalDirections = []
                let riderPin = try PathSearch(pack: graph).search(start: start, end: end,
                    policy: .init(style: .dirt), access: .init(), options: options)
                #expect(riderPin.segments.last?.forward == true)
                #expect(riderPin.distanceMeters < result.distanceMeters)
            }
        }
    }

    @Test func seamDirectionUsesLegalRouteProofRatherThanInitialBearing() throws {
        // The east-facing direction looks correct but ends at a cul-de-sac.
        // The west-facing direction reaches the onward road after a legal loop.
        let nodes: [Coordinate] = [
            .init(longitude: 0, latitude: 0), .init(longitude: 0.01, latitude: 0),
            .init(longitude: 0.02, latitude: 0), .init(longitude: 0, latitude: 0.01),
            .init(longitude: 0.02, latitude: 0.01)
        ]
        let graph = PolicyTests.Line(nodes: nodes,
            edges: [(0,1),(1,2),(0,3),(3,4)],
            surfaces: Array(repeating: "asphalt", count: 4),
            roads: Array(repeating: "tertiary", count: 4))
        let point = Coordinate(longitude: 0.005, latitude: 0)
        let starts = [
            RoadMatch(edge: 0, coordinate: point, distanceMeters: 0,
                alongMeters: graph.distance(0) / 2, geometryMeters: graph.distance(0), forward: true),
            RoadMatch(edge: 0, coordinate: point, distanceMeters: 0,
                alongMeters: graph.distance(0) / 2, geometryMeters: graph.distance(0), forward: false)
        ]
        let end = RoadMatch(edge: 3, coordinate: nodes[4], distanceMeters: 0,
            alongMeters: graph.distance(3), geometryMeters: graph.distance(3), forward: true)
        let request = RoutingRequest(start: point, end: nodes[4], style: .dirt)
        let proved = try StagedRouter.exactlyReachableDirections(starts, ends: [end],
            graph: graph, request: request, budget: .init(seconds: 2))
        #expect(proved.map(\.forward) == [false])
    }

    @Test func handoverScreeningConsidersTheLegalDirectionAwayFromTheDestination() throws {
        let nodes: [Coordinate] = [.init(longitude: 0, latitude: 0),
            .init(longitude: 0.01, latitude: 0), .init(longitude: 0, latitude: 0.02),
            .init(longitude: 0.02, latitude: 0.02)]
        let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes, edges: [(0,1),(0,2),(2,3)],
            surfaces: ["asphalt","asphalt","asphalt"], roads: ["tertiary","tertiary","tertiary"]))
        let origin = Coordinate(longitude: 0.005, latitude: 0)
        for style: RidingStyle in [.dirt, .balanced, .cleanest] {
            let request = RoutingRequest(start: origin, end: nodes[3], style: style)
            var reach: EndpointReachability?
            #expect(try StagedRouter.hopLooksLive(nodes[3], origin: origin, graph: graph,
                request: request, budget: .init(), reach: &reach))
            let route = try RoutingEngine(pack: graph).route(request)
            #expect(route.end.coordinate.distance(to: nodes[3]) < 1)
            #expect(route.segments.first?.forward == false)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRT_BRIDGE_PACK_ROOT"] != nil))
    func ownerBridgeMidpointHasAConnectedHandover() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DIRT_BRIDGE_PACK_ROOT"]))
        let repository = try PackRepository(installedDirectories: ["ns": root.appendingPathComponent("ns"),
            "nb": root.appendingPathComponent("nb")])
        var request = RoutingRequest(start: .init(longitude: -63.340266, latitude: 44.764843),
            end: .init(longitude: -63.774129, latitude: 46.193790), style: .dirt, seed: 1)
        request.profile.wander = 0.5
        request.mapZoom = 9.2
        let route = try StagedRouter.route(request, repository: repository, regions: ["ns","nb"],
            budget: .init(seconds: 60))
        #expect(route.limit == nil)
        #expect(route.end.coordinate.distance(to: request.end) < 15)
        #expect(route.segments.last?.edgeID.contains("646650186") == true)
        #expect(RouteQuality(route: route).reriddenMeters == 0)
        #expect(route.segments.allSatisfy { $0.access != 2 && $0.access != 5 })
    }

    @Test func cleanHandoverRejectsAnUnknownOnlyApproachWithoutRejectingDirtConnector() throws {
        let nodes: [Coordinate] = [.init(longitude: 0, latitude: 0),
            .init(longitude: 0.01, latitude: 0), .init(longitude: 0.0105, latitude: 0),
            .init(longitude: 0.02, latitude: 0)]
        let line = PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(2,3)],
            surfaces: ["asphalt","gravel","gravel"], roads: ["tertiary","track","track"],
            edgeAccess: [0,1,0])
        let graph = try IndexedGraph(line)
        for style: RidingStyle in [.cleanest, .dirt] {
            let request = RoutingRequest(start: nodes[0], end: nodes[3], style: style)
            var reach: EndpointReachability?
            let live = try StagedRouter.hopLooksLive(nodes[3], origin: nodes[0], graph: graph,
                request: request, budget: .init(), reach: &reach)
            #expect(live == (style == .dirt))
        }
    }

    @Test func joinedStagesCannotEraseAnIncompleteSearch() throws {
        let match = RoadMatch(edge: 0, coordinate: .init(longitude: -63.5, latitude: 44.7),
                              distanceMeters: 0, alongMeters: 0, geometryMeters: 0)
        let complete = ComputedRoute(start: match, end: match, segments: [],
            distanceMeters: 0, searchCost: 0, poppedLabels: 0, arrivalRestrictions: [])
        for reason in ["time", "labels"] {
            let incomplete = complete.reportingLimit(reason)
            for parts in [[incomplete, complete], [complete, incomplete]] {
                #expect(throws: RoutingFailure.resourceLimit(reason)) {
                    try StagedRouter.stitch(parts, windows: [["ns"], ["nb"]])
                }
            }
        }
        #expect(try StagedRouter.stitch([complete, complete], windows: [["ns"], ["nb"]]).limit == nil)
    }

    @Test func continuationChoosesUnusedRoadsAndRetainsNecessaryAccessFallback() throws {
        let nodes: [Coordinate] = [.init(longitude: 0, latitude: 0),.init(longitude: 0.01, latitude: 0),
            .init(longitude: 0.02, latitude: 0),.init(longitude: 0.03, latitude: 0),
            .init(longitude: 0.02, latitude: 0.01),.init(longitude: 0.04, latitude: 0)]
        let graph = PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(2,3),(1,4),(4,3),(3,5)],
            surfaces: Array(repeating: "gravel", count: 6), roads: Array(repeating: "track", count: 6))
        var request = RoutingRequest(start: nodes[0], end: nodes[5], style: .dirt)
        request.options.priorEdges = [graph.identity(of: 1),graph.identity(of: 2)]
        let ride = try StagedRouter.routeAvoidingEarlierRoads(request, graph: graph, compassStore: nil, budget: .init())
        #expect(!ride.segments.contains { $0.edge == 1 || $0.edge == 2 })
        #expect(ride.segments.contains { $0.edge == 3 })
        #expect(ride.end.coordinate.distance(to: request.end) < 1)

        let single = PolicyTests.Line(nodes: Array(nodes.prefix(4)), edges: [(0,1),(1,2),(2,3)],
            surfaces: Array(repeating: "gravel", count: 3), roads: Array(repeating: "track", count: 3))
        var unavoidable = RoutingRequest(start: nodes[0], end: nodes[3], style: .dirt)
        unavoidable.options.priorEdges = [single.identity(of: 1)]
        let fallback = try StagedRouter.routeAvoidingEarlierRoads(unavoidable, graph: single, compassStore: nil, budget: .init())
        #expect(fallback.segments.contains { $0.edge == 1 })
        #expect(fallback.end.coordinate.distance(to: unavoidable.end) < 1)
    }

    @Test func joiningClippedRoadPreservesOnwardDistanceAndVisibleReversal() throws {
        func part(_ from: Double, _ to: Double, meters: Double, forward: Bool) -> ComputedRoute {
            let a = Coordinate(longitude: from, latitude: 0), b = Coordinate(longitude: to, latitude: 0)
            let segment = RouteSegment(edge: 0, edgeID: "same-source-road", forward: forward, meters: meters,
                surface: .gravel, surfaceLeaf: "gravel", roadClass: "track", structure: "", access: 0, geometry: [a,b])
            return ComputedRoute(start: .init(edge: 0, coordinate: a, distanceMeters: 0, alongMeters: 0, geometryMeters: 100),
                end: .init(edge: 0, coordinate: b, distanceMeters: 0, alongMeters: meters, geometryMeters: 100),
                segments: [segment], distanceMeters: meters, searchCost: 1, poppedLabels: 1, arrivalRestrictions: [])
        }
        let a = part(0, 0.0005, meters: 50, forward: true)
        let onward = try StagedRouter.stitch([a,part(0.0005,0.001,meters: 50,forward: true)], windows: [["a"],["b"]])
        #expect(onward.distanceMeters == 100)
        #expect(RouteQuality.reriddenMeters(onward.segments) == 0)
        let reversed = try StagedRouter.stitch([a,part(0.0005,0.0002,meters: 30,forward: false)], windows: [["a"],["b"]])
        #expect(reversed.distanceMeters == 80)
        #expect(RouteQuality.reriddenMeters(reversed.segments) == 30)
    }

    @Test func continuationCannotSnapToANearbyUnrelatedRoad() {
        let graph = PolicyTests.Line(nodes: [.init(longitude: 0, latitude: 0),.init(longitude: 0.01, latitude: 0)],
            edges: [(0,1)], surfaces: ["gravel"], roads: ["track"])
        var request = RoutingRequest(start: graph.nodes[0], end: graph.nodes[1], style: .dirt)
        request.options.arrivalEdgeID = "a-different-road-in-the-previous-pack"
        #expect(throws: RoutingFailure.noMatch) { try RoutingEngine(pack: graph).route(request) }
    }

    @Test func generatedHandoverCanMoveToASharedJunctionButNotEraseAnActiveTurnSequence() throws {
        for restricted in [false, true] {
            var graph = UnknownConnectorTests.Graph(lengths: [100,100,100], access: [0,0,0])
            if restricted {
                graph.restrictions = [.init(relationID: 1, fromEdge: 0, toEdge: 2, viaNode: 1, viaEdges: [1], only: true)]
            }
            var request = RoutingRequest(start: graph.coordinate(node: 0), end: graph.coordinate(node: 3), style: .dirt)
            request.options.objective = .distance
            let start = RoadMatch(edge: 0, coordinate: request.start, distanceMeters: 0, alongMeters: 0, geometryMeters: 100, forward: true)
            let end = RoadMatch(edge: 2, coordinate: request.end, distanceMeters: 0, alongMeters: 100, geometryMeters: 100, forward: true)
            let route = try PathSearch(pack: graph).search(start: start, end: end, policy: request.profile,
                access: request.access, options: request.options)
            var nextGraph = graph
            nextGraph.wayIDs = [-1, 1, 2] // The first incoming road is not shared.
            let result = try StagedRouter.handoverBeforeFinalRoad(route, request: request, graph: graph,
                nextGraph: nextGraph, budget: .init())
            #expect(result.segments.count == (restricted ? 3 : 2))
            #expect(result.distanceMeters == (restricted ? 300 : 200))
            #expect(result.end.coordinate == graph.coordinate(node: restricted ? 3 : 2))
        }
    }

    @Test(arguments: [[Int64(10),20,20,20], [Int64(10),20,30,40]])
    func generatedHandoverDoesNotRequireAnArbitrarySharedApproach(wayIDs: [Int64]) throws {
        var graph = UnknownConnectorTests.Graph(lengths: [100,100,100,100], access: [0,0,0,0])
        graph.wayIDs = wayIDs
        var request = RoutingRequest(start: graph.coordinate(node: 0), end: graph.coordinate(node: 4), style: .dirt)
        request.options.objective = .distance
        let route = try PathSearch(pack: graph).search(
            start: .init(edge: 0, coordinate: request.start, distanceMeters: 0, alongMeters: 0, geometryMeters: 100, forward: true),
            end: .init(edge: 3, coordinate: request.end, distanceMeters: 0, alongMeters: 100, geometryMeters: 100, forward: true),
            policy: request.profile, access: request.access, options: request.options)
        let handover = try StagedRouter.handoverBeforeFinalRoad(route, request: request, graph: graph,
            nextGraph: graph, budget: .init())
        #expect(handover.segments.map(\.edge) == [0,1,2])
        #expect(handover.distanceMeters == 300)
        #expect(handover.end.coordinate == graph.coordinate(node: 3))
    }

    @Test func sharedInteriorContinuesWhenTheApproachRoadIsLocalToOnePack() throws {
        let nodes: [Coordinate] = [.init(longitude: 0, latitude: 0),
            .init(longitude: 0.01, latitude: 0), .init(longitude: 0.02, latitude: 0),
            .init(longitude: 0.10, latitude: 0), .init(longitude: 0.11, latitude: 0)]
        let first = PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2)],
            surfaces: ["asphalt", "asphalt"], roads: ["tertiary", "tertiary"])
        let next = PolicyTests.Line(nodes: nodes, edges: [(3,4),(1,2)],
            surfaces: ["asphalt", "asphalt"], roads: ["tertiary", "tertiary"])
        let points = try StagedRouter.sharedHandoverPoints([nodes[1]], first: first,
            next: next, access: .init(), budget: .init())
        #expect(points.count == 1)
        let point = try #require(points.first)
        #expect(point.longitude > nodes[1].longitude && point.longitude < nodes[2].longitude)
        var hop = RoutingRequest(start: nodes[0], end: point, style: .balanced)
        hop.options.requiredArrivalRoads = [next.identity(of: 1)]
        let approach = try RoutingEngine(pack: first).route(hop)
        #expect(approach.segments.last?.edge == 1)
        var tail = RoutingRequest(start: point, end: nodes[2], style: .balanced)
        tail.options.arrivalEdgeID = first.identity(of: approach.segments.last!.edge)
        tail.options.continuationForward = approach.segments.last!.forward
        let onward = try RoutingEngine(pack: next).route(tail)
        let whole = try StagedRouter.stitch([approach,onward], windows: [["first"],["next"]])
        #expect(abs(whole.distanceMeters - first.distance(0) - first.distance(1)) < 0.01)
        #expect(RouteQuality.reriddenMeters(whole.segments) == 0)
        #expect(whole.end.coordinate == nodes[2])
    }

    @Test func generatedHandoverActuallyTraversesASharedIncomingRoad() throws {
        let nodes: [Coordinate] = [.init(longitude: 0, latitude: 0),
            .init(longitude: 0.01, latitude: 0), .init(longitude: 0.02, latitude: 0),
            .init(longitude: 0.01, latitude: 0.01)]
        let graph = PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(0,3),(3,2)],
            surfaces: Array(repeating: "asphalt", count: 4), roads: Array(repeating: "tertiary", count: 4))
        var request = RoutingRequest(start: nodes[0], end: nodes[2], style: .balanced)
        let original = try RoutingEngine(pack: graph).route(request)
        #expect(original.segments.last?.edge == 1)
        request.options.requiredArrivalRoads = [graph.identity(of: 3)]
        let shared = try RoutingEngine(pack: graph).route(request)
        #expect(shared.segments.last?.edge == 3)
        #expect(shared.segments.last!.meters > 100)
        #expect(shared.end.coordinate == request.end)
        #expect(request.with(start: request.start, end: nodes[1]).options.requiredArrivalRoads.isEmpty)
    }

    @Test func generatedCutPreservesTravelDirectionOnTheIncomingRoad() throws {
        let nodes: [Coordinate] = [.init(longitude: 0, latitude: 0),.init(longitude: 0.02, latitude: 0),
            .init(longitude: 0.01, latitude: 0.02)]
        let graph = PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(2,0)],
            surfaces: ["gravel","gravel","gravel"], roads: ["track","track","track"])
        var request = RoutingRequest(start: .init(longitude: 0.01, latitude: 0), end: nodes[0], style: .dirt)
        request.options.arrivalEdgeID = graph.identity(of: 0)
        request.options.continuationForward = true
        let route = try RoutingEngine(pack: graph).route(request)
        #expect(route.segments.first?.edge == 0)
        #expect(route.segments.first?.forward == true)
        #expect(route.segments.contains { $0.edge == 1 })
        #expect(route.end.coordinate.distance(to: request.end) < 1)
    }

    @Test func sharedRoadStubIsNotAnOnwardConnection() {
        let request = RoutingRequest(start: .init(longitude: 0, latitude: 0), end: .init(longitude: 1, latitude: 0), style: .dirt)
        let stub = UnknownConnectorTests.Graph(lengths: [100], access: [0])
        let match = RoadMatch(edge: 0, coordinate: stub.coordinate(node: 1), distanceMeters: 0,
            alongMeters: 100, geometryMeters: 100, forward: true)
        #expect(!StagedRouter.canContinueForward(match, graph: stub, request: request))
        let through = UnknownConnectorTests.Graph(lengths: [100,100], access: [0,0])
        #expect(StagedRouter.canContinueForward(match, graph: through, request: request))
        let blocked = UnknownConnectorTests.Graph(lengths: [100,100], access: [0,2])
        #expect(!StagedRouter.canContinueForward(match, graph: blocked, request: request))
        var prohibitedTurn = through
        prohibitedTurn.restrictions = [.init(relationID: 1, fromEdge: 0, toEdge: 1, viaNode: 1, only: false)]
        #expect(!StagedRouter.canContinueForward(match, graph: prohibitedTurn, request: request))
    }

    @Test func shortBorderRetainsNearbyTopologyAlternativesWithinTheExistingLimit() {
        let points = (0..<20).map { Coordinate(longitude: -64.2 + Double($0)*0.0001, latitude: 45.8) }
        let picks = StagedRouter.pickHandoverCandidates(from: points,
            origin: .init(longitude: -63.5, latitude: 44.7), toward: .init(longitude: -67.3, latitude: 45.2), limit: 12)
        #expect(picks.count == 12)
        #expect(Set(picks.map(\.longitude)).count == 12)
        #expect(picks.allSatisfy { points.contains($0) })
    }

    private var portersLake: Coordinate { .init(longitude: -63.34024797349485, latitude: 44.764804567541226) }
    private var gaspe: Coordinate { .init(longitude: -64.273363, latitude: 48.922934) }
    private var dartmouth: Coordinate { .init(longitude: -63.57, latitude: 44.67) }

    @Test func longTwoPackAndThreePackStageWithCorrectWindows() {
        #expect(StagedRouter.shouldStage(regionCount: 3, start: portersLake, end: gaspe))
        #expect(StagedRouter.shouldStage(regionCount: 2, start: portersLake, end: gaspe))
        #expect(!StagedRouter.shouldStage(regionCount: 3, start: portersLake, end: dartmouth))
        #expect(!StagedRouter.shouldStage(regionCount: 2, start: portersLake, end: dartmouth))
        let sudbury = Coordinate(longitude: -81.0, latitude: 46.49)
        let parrySound = Coordinate(longitude: -80.035, latitude: 45.347)
        #expect(StagedRouter.shouldStage(regionCount: 2, start: parrySound, end: sudbury))
        #expect(StagedRouter.overlappingWindows(["ns", "nb", "qc"]) == [["ns"], ["nb"], ["qc"]])
        #expect(StagedRouter.overlappingWindows(["on-s", "on-n"]) == [["on-s"], ["on-n"]])
        #expect(StagedRouter.overlappingWindows(["ns", "nb"]) == [["ns"], ["nb"]])
        // Every long corridor keeps one prepared region resident per stage.
        let three = StagedRouter.overlappingWindows(["ns", "nb", "me"])
        #expect(three == [["ns"], ["nb"], ["me"]])
        #expect(three.allSatisfy { $0.count == 1 })
    }

    @Test func handoverDiversifiesAwayFromWesternStubClusters() {
        let origin = Coordinate(longitude: -81.25, latitude: 42.98) // London
        let dest = Coordinate(longitude: -89.25, latitude: 48.38) // Thunder Bay
        var points: [Coordinate] = []
        // Dense western stub cluster — pure detour would pick only these.
        for i in 0..<2_000 {
            let lon = -83.95 - Double(i % 20) * 0.01
            let lat = 46.05 + Double(i / 20) * 0.001
            points.append(.init(longitude: lon, latitude: lat))
        }
        // Connected Hwy 69 / French River band pins.
        let central = Coordinate(longitude: -80.46, latitude: 45.82)
        let east = Coordinate(longitude: -80.02, latitude: 45.93)
        points.append(central)
        points.append(east)
        let picks = StagedRouter.pickHandoverCandidates(from: points, origin: origin, toward: dest, limit: 8)
        #expect(picks.count >= 2)
        #expect(picks.contains(where: { abs($0.longitude - central.longitude) < 0.05 }))
        #expect(picks.contains(where: { abs($0.longitude - east.longitude) < 0.05 }))
    }

    @Test func handoverNarrowLongitudeBeltDiversifiesByLatitude() {
        // co↔ks / nb↔ns class: proofs collapse under a longitude-only grid.
        let origin = Coordinate(longitude: -104.0, latitude: 37.0)
        let dest = Coordinate(longitude: -95.0, latitude: 39.0)
        var points: [Coordinate] = []
        for i in 0..<40 {
            points.append(.init(longitude: -102.05 - Double(i % 3) * 0.01,
                                latitude: 37.0 + Double(i) * 0.05))
        }
        let picks = StagedRouter.pickHandoverCandidates(
            from: points, origin: origin, toward: dest, limit: 8)
        #expect(picks.count >= 4)
        let lats = picks.map(\.latitude)
        #expect((lats.max() ?? 0) - (lats.min() ?? 0) > 0.3)
    }

    @Test func handoverWindowLiveOutranksNextOnlyStub() {
        let origin = Coordinate(longitude: -63.34, latitude: 44.76)
        let dest = Coordinate(longitude: -71.41, latitude: 41.82)
        let windowLive = Coordinate(longitude: -67.68, latitude: 45.62)
        let windowDead = Coordinate(longitude: -66.98, latitude: 44.85)
        let picks = StagedRouter.pickHandoverCandidates(
            from: [
                .init(coordinate: windowDead, waterLike: false, stubOnSearch: true, stubOnNext: false),
                .init(coordinate: windowLive, waterLike: false, stubOnSearch: false, stubOnNext: true)
            ],
            origin: origin, toward: dest, limit: 8)
        #expect(picks.first?.longitude == windowLive.longitude)
    }

    @Test func handoverStubIslandDemotesDisconnectedSeamProofs() {
        let origin = Coordinate(longitude: -66.1, latitude: 45.3)
        let dest = Coordinate(longitude: -69.8, latitude: 43.7)
        let giant = Coordinate(longitude: -67.28, latitude: 45.19)
        // Better detour than giant, but marked stub-island and far enough in
        // both lon and lat to survive 2D cell + 8 km spacing as a demoted fallback.
        let stub = Coordinate(longitude: -67.00, latitude: 44.90)
        let picks = StagedRouter.pickHandoverCandidates(
            from: [
                .init(coordinate: stub, waterLike: false, stubOnSearch: true, stubOnNext: true),
                .init(coordinate: giant, waterLike: false, stubOnSearch: false, stubOnNext: false)
            ],
            origin: origin, toward: dest, limit: 8)
        #expect(picks.first?.longitude == giant.longitude)
        #expect(picks.first?.latitude == giant.latitude)
        #expect(picks.contains(where: { abs($0.longitude - stub.longitude) < 0.01 }))
    }

    @Test func handoverStructuralQualityDemotesFerryAndWaterCrossing() {
        let origin = Coordinate(longitude: -66.1, latitude: 45.3) // Fredericton-ish
        let dest = Coordinate(longitude: -69.8, latitude: 43.7) // Portland-ish
        let ferry = Coordinate(longitude: -67.00, latitude: 45.00)
        let ford = Coordinate(longitude: -67.06, latitude: 45.05)
        let land = Coordinate(longitude: -67.35, latitude: 45.20)
        let picks = StagedRouter.pickHandoverCandidates(
            from: [
                .init(coordinate: ferry, waterLike: true),
                .init(coordinate: ford, waterLike: true),
                .init(coordinate: land, waterLike: false)
            ],
            origin: origin, toward: dest, limit: 8)
        #expect(!picks.isEmpty)
        #expect(picks.first?.longitude == land.longitude)
        #expect(picks.first?.latitude == land.latitude)
    }

    @Test func handoverCorridorIQRPrefersLandBorderOverIslandApproaches() {
        // Replaces the removed NB/ME lon ≤ -67.05 gate: island approaches sit
        // on the eastern fringe when riding west; land Calais belt stays.
        let origin = Coordinate(longitude: -66.1, latitude: 45.3)
        let dest = Coordinate(longitude: -69.8, latitude: 43.7)
        var points: [StagedRouter.HandoverCandidate] = []
        // Dense land belt (IQR bulk).
        for i in 0..<40 {
            points.append(.init(
                coordinate: .init(longitude: -67.40 + Double(i % 10) * 0.02,
                                  latitude: 45.10 + Double(i / 10) * 0.03),
                waterLike: false))
        }
        let land = Coordinate(longitude: -67.28, latitude: 45.19)
        let island = Coordinate(longitude: -66.96, latitude: 44.91)
        points.append(.init(coordinate: land, waterLike: false))
        points.append(.init(coordinate: island, waterLike: false))
        let picks = StagedRouter.pickHandoverCandidates(
            from: points, origin: origin, toward: dest, limit: 8)
        #expect(picks.contains(where: { abs($0.longitude - land.longitude) < 0.05 }))
        #expect(picks.first.map { abs($0.longitude - island.longitude) > 0.05 } ?? false)
    }

    @Test func handoverProgressSideFringeStaysEligibleWhenRidingWest() {
        // Winnipeg/BC class: western qc-s↔on-n pins are lon-IQR fringe but
        // must not be demoted when the onward aim is further west.
        let origin = Coordinate(longitude: -67.2, latitude: 47.5)
        let towardMB = Coordinate(longitude: -95.0, latitude: 49.5)
        var points: [StagedRouter.HandoverCandidate] = []
        for i in 0..<40 {
            points.append(.init(
                coordinate: .init(longitude: -76.0 + Double(i % 10) * 0.05,
                                  latitude: 45.5 + Double(i / 10) * 0.1),
                waterLike: false))
        }
        let western = Coordinate(longitude: -78.5, latitude: 46.0) // progress-side fringe
        let eastern = Coordinate(longitude: -74.0, latitude: 45.5) // anti-progress fringe
        points.append(.init(coordinate: western, waterLike: false))
        points.append(.init(coordinate: eastern, waterLike: false))
        let flags = StagedRouter.seamFringeFlags(for: points, toward: towardMB)
        let westFlag = flags[points.count - 2]
        let eastFlag = flags[points.count - 1]
        #expect(westFlag == false)
        #expect(eastFlag == true)
        let picks = StagedRouter.pickHandoverCandidates(
            from: points, origin: origin, toward: towardMB, limit: 8)
        #expect(picks.contains(where: { abs($0.longitude - western.longitude) < 0.05 }))
    }

    @Test func handoverStructuralQualityKeepsWaterOnlyFallbacks() {
        let origin = Coordinate(longitude: -66.1, latitude: 45.3)
        let dest = Coordinate(longitude: -69.8, latitude: 43.7)
        let picks = StagedRouter.pickHandoverCandidates(
            from: [
                .init(coordinate: .init(longitude: -67.00, latitude: 45.00), waterLike: true),
                .init(coordinate: .init(longitude: -67.45, latitude: 45.20), waterLike: true)
            ],
            origin: origin, toward: dest, limit: 8)
        #expect(picks.count == 2)
    }

    @Test func dirtHandoverSlicesReserveTimeForLaterCandidates() {
        // 12 candidates / 300s parent: reserve 11×20s, first pin gets ~80s.
        #expect(StagedRouter.dirtCandidateSliceSeconds(remainingSeconds: 300, candidatesLeft: 12) == 80)
        // A normal app window retains one useful retry after a hard approach.
        #expect(StagedRouter.dirtCandidateSliceSeconds(remainingSeconds: 60, candidatesLeft: 2) == 45)
        #expect(StagedRouter.dirtCandidateSliceSeconds(remainingSeconds: 60, candidatesLeft: 12) == 45)
        #expect(StagedRouter.dirtCandidateSliceSeconds(remainingSeconds: 30, candidatesLeft: 5) == 15)
        // Never invent time beyond the parent remainder.
        #expect(StagedRouter.dirtCandidateSliceSeconds(remainingSeconds: 15, candidatesLeft: 3) == 15)
    }

    @Test func timedSeamProofIsWaterLikeWhenFerryLeafIsMissing() {
        let timed = SeamDocument.EdgeProof(
            osmWayId: "ferry", fromOsmNodeId: "a", toOsmNodeId: "b",
            accessForward: 1, accessReverse: 1, layer: 0,
            structureLeaf: nil, crossingSeconds: 3_600
        )
        #expect(StagedRouter.isWaterLike(timed))
        let leafOnly = SeamDocument.EdgeProof(
            osmWayId: "ford", fromOsmNodeId: "a", toOsmNodeId: "b",
            accessForward: 1, accessReverse: 1, layer: 0,
            structureLeaf: "ford", crossingSeconds: nil
        )
        #expect(StagedRouter.isWaterLike(leafOnly))
        let land = SeamDocument.EdgeProof(
            osmWayId: "road", fromOsmNodeId: "a", toOsmNodeId: "b",
            accessForward: 1, accessReverse: 1, layer: 0,
            structureLeaf: nil, crossingSeconds: 0
        )
        #expect(!StagedRouter.isWaterLike(land))
    }

    @Test func stageAimContractUsesNextPackSeamNotFinalDestination() throws {
        // Early NS→west hops must aim at the next onward seam belt, not Whistler.
        // Same eastern half set already clears NS→Winnipeg; dest-biased ranking
        // is what kills nb→qc-s when the rider pin is in BC.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("staged-chain-aim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Stage0 lands in qc-s; the following window ends at on-n — aim qc-s↔on-n.
        try writeSeamFixture(
            root: root, region: "qc-s",
            neighbors: ["on-n": [
                Coordinate(longitude: -75.0, latitude: 45.5),
                Coordinate(longitude: -75.2, latitude: 45.4),
                Coordinate(longitude: -74.8, latitude: 45.6)
            ]]
        )
        // West of Winnipeg: stage on-n+mb into sk aims at sk↔ab (~-110), not BC.
        try writeSeamFixture(
            root: root, region: "sk",
            neighbors: ["ab": [
                Coordinate(longitude: -110.0, latitude: 50.5),
                Coordinate(longitude: -110.2, latitude: 51.0),
                Coordinate(longitude: -109.8, latitude: 49.8)
            ]]
        )
        let repo = try PackRepository(installedDirectories: [
            "qc-s": root.appendingPathComponent("qc-s"),
            "sk": root.appendingPathComponent("sk")
        ])
        let rockies = Coordinate(longitude: -122.9, latitude: 50.5)
        // Mirrors NS→BC overlapping windows once catalog has sk/ab/bc.
        let windows = [["ns"], ["nb"], ["qc-s"], ["on-n"], ["mb"], ["sk"], ["ab"], ["bc"]]
        let early = try StagedRouter.chainLocalAim(
            windows: windows, stageIndex: 1, next: "qc-s",
            finalDestination: rockies, repository: repo
        )
        #expect(abs(early.longitude - (-75.0)) < 0.2)
        #expect(abs(early.longitude - rockies.longitude) > 40)

        // Call site: stageIndex 4 leaves mb for sk and aims at sk↔ab.
        let prairie = try StagedRouter.chainLocalAim(
            windows: windows, stageIndex: 4, next: "sk",
            finalDestination: rockies, repository: repo
        )
        #expect(abs(prairie.longitude - (-110.0)) < 0.2)
        #expect(abs(prairie.longitude - rockies.longitude) > 10)

        // Penultimate stage has no following window — keep the rider destination.
        let last = try StagedRouter.chainLocalAim(
            windows: windows, stageIndex: 6, next: "bc",
            finalDestination: rockies, repository: repo
        )
        #expect(last.longitude == rockies.longitude)
        #expect(last.latitude == rockies.latitude)

        // The two-pack branch invokes the same aim function; its only handover
        // is followed by the final rider destination, not an invented seam aim.
        let twoPackFinal = try StagedRouter.chainLocalAim(
            windows: [["nb"], ["me"]], stageIndex: 0, next: "me",
            finalDestination: rockies, repository: repo
        )
        #expect(twoPackFinal.longitude == rockies.longitude)
        #expect(twoPackFinal.latitude == rockies.latitude)
    }

    @Test func cappedAimKeepsLocalDifferentiationOnFarOnwardBelts() {
        let belt = Coordinate(longitude: -76.0, latitude: 46.0)
        let far = Coordinate(longitude: -95.0, latitude: 49.5)
        let capped = StagedRouter.cappedAim(from: belt, toward: far, maxMeters: 350_000)
        #expect(belt.distance(to: capped) <= 350_000 + 1)
        #expect(capped.longitude < belt.longitude)
        #expect(capped.longitude > far.longitude)
        let near = Coordinate(longitude: -78.0, latitude: 46.2)
        #expect(StagedRouter.cappedAim(from: belt, toward: near, maxMeters: 350_000).longitude == near.longitude)
    }

    @Test func compactNeighborLookupAndWarmSeamsRejectChangedArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSeamFixture(root: root, region: "aa", neighbors: ["bb": [.init(longitude: 1, latitude: 2)]])
        let repository = try PackRepository(installedDirectories: ["aa": root.appendingPathComponent("aa")])
        #expect(try repository.seamNeighborIDs("aa") == ["bb"])
        #expect(try repository.loadSeams("aa").neighbors["bb"]?.count == 1)
        #expect(try repository.loadSeams("aa").neighbors["bb"]?.count == 1)
        try Data("{}".utf8).write(to: root.appendingPathComponent("aa/cross-pack-seams.v2.json"), options: .atomic)
        #expect(throws: RoutingFailure.self) { try repository.loadSeams("aa") }
        #expect(throws: RoutingFailure.self) { try repository.seamNeighborIDs("aa") }
    }

    private func writeSeamFixture(root: URL, region: String, neighbors: [String:[Coordinate]]) throws {
        let dir = root.appendingPathComponent(region, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var neighborJSON: [String:Any] = [:]
        for (id, points) in neighbors {
            neighborJSON[id] = points.enumerated().map { index, point in
                [
                    "coordinate": [point.longitude, point.latitude],
                    "gapMeters": 0,
                    "osmNodeId": "\(region)-\(id)-\(index)",
                    "osmWayId": "way-\(index)",
                    "proof": "test",
                    "barrierDecision": 0,
                    "edge": [
                        "osmWayId": "way-\(index)",
                        "fromOsmNodeId": "a\(index)",
                        "toOsmNodeId": "b\(index)",
                        "accessForward": 1,
                        "accessReverse": 1,
                        "layer": 0,
                        "structureLeaf": NSNull()
                    ]
                ] as [String:Any]
            }
        }
        let doc: [String:Any] = [
            "schemaVersion": "dirt-cross-pack-seams.v2",
            "fabricReleaseId": "fixture",
            "sourceEpoch": "fixture",
            "regionId": region,
            "neighbors": neighborJSON
        ]
        let data = try JSONSerialization.data(withJSONObject: doc)
        try data.write(to: dir.appendingPathComponent("cross-pack-seams.v2.json"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func artifact(_ name: String) -> [String: Any] { ["name": name, "bytes": data.count, "sha256": hash] }
        let manifest: [String: Any] = ["schema": "pack-manifest.v2", "fabricReleaseId": "fixture",
            "regionId": region, "sourceEpoch": "fixture", "timezone": "America/Halifax",
            "capabilities": ["legal-topology.v1", "cross-pack-seams.v2"],
            "graph": artifact("graph.v4.bin"), "geometry": artifact("geometry.v1.bin"),
            "fuel": artifact("fuel.v1.json"), "seams": artifact("cross-pack-seams.v2.json")]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("pack-manifest.v2.json"))
    }

    @Test func compassCapDoesNotChangeAnUncappedTableOnATinyGraph() throws {
        let nodes = (0...4).map { Coordinate(longitude: Double($0) * 0.01, latitude: 0) }
        let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes, edges: (0..<4).map { ($0, $0 + 1) },
            surfaces: Array(repeating: "asphalt", count: 4), roads: Array(repeating: "tertiary", count: 4)))
        let end = RoadMatch(edge: 3, coordinate: nodes[4], distanceMeters: 0, alongMeters: graph.distance(3),
                            geometryMeters: graph.distance(3))
        let full = try RoadCompass.toward(end: end, pack: graph, budget: .init())
        let capped = try RoadCompass.toward(end: end, pack: graph, budget: .init(), maxRemaining: .infinity)
        #expect(full.remaining == capped.remaining)
    }
}
