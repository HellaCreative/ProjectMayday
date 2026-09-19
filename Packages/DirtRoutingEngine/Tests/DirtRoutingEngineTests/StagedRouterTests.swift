import Foundation
import Testing
@testable import DirtRoutingEngine

struct StagedRouterTests {
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
        #expect(StagedRouter.overlappingWindows(["ns", "nb", "qc"]) == [["ns", "nb"], ["nb", "qc"]])
        #expect(StagedRouter.overlappingWindows(["on-s", "on-n"]) == [["on-s"], ["on-n"]])
        #expect(StagedRouter.overlappingWindows(["ns", "nb"]) == [["ns"], ["nb"]])
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
        // Two left / 60s: reserve 20s, current gets 40s.
        #expect(StagedRouter.dirtCandidateSliceSeconds(remainingSeconds: 60, candidatesLeft: 2) == 40)
        // Tight parent still keeps a 20s floor when reserve would go negative.
        #expect(StagedRouter.dirtCandidateSliceSeconds(remainingSeconds: 30, candidatesLeft: 5) == 20)
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
        // Stage0 next=qc-s; following window ends at on-n — aim qc-s↔on-n.
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
        let windows = [["ns", "nb"], ["nb", "qc-s"], ["qc-s", "on-n"], ["on-n", "mb"],
                       ["mb", "sk"], ["sk", "ab"], ["ab", "bc"]]
        let early = try StagedRouter.chainLocalAim(
            windows: windows, stageIndex: 0, next: "qc-s",
            finalDestination: rockies, repository: repo
        )
        #expect(abs(early.longitude - (-75.0)) < 0.2)
        #expect(abs(early.longitude - rockies.longitude) > 40)

        // Call site: stageIndex 3 window [on-n,mb], next=windows[4].last=sk.
        let prairie = try StagedRouter.chainLocalAim(
            windows: windows, stageIndex: 3, next: "sk",
            finalDestination: rockies, repository: repo
        )
        #expect(abs(prairie.longitude - (-110.0)) < 0.2)
        #expect(abs(prairie.longitude - rockies.longitude) > 10)

        // Penultimate stage has no following window — keep the rider destination.
        let last = try StagedRouter.chainLocalAim(
            windows: windows, stageIndex: 5, next: "bc",
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
