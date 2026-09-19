import Foundation
import Testing
@testable import DirtRoutingEngine

struct OfflineContractTests {
    @Test func connectionSelectionUsesRidingStyleRatherThanFirstRegionChain() {
        func route(_ dirtMeters: Double, id: String) -> ComputedRoute {
            let a = Coordinate(longitude: 0, latitude: 0)
            let c = Coordinate(longitude: 1, latitude: 0)
            // Both mixes are distributed across the ride, as Balanced requires.
            var segments: [RouteSegment] = []
            for quarter in 0..<4 {
                let begin = Coordinate(longitude: Double(quarter) / 4, latitude: 0)
                let turn = Coordinate(longitude: Double(quarter) / 4 + dirtMeters / 400_000, latitude: 0)
                let end = Coordinate(longitude: Double(quarter + 1) / 4, latitude: 0)
                let suffix = quarter == 0 ? "" : ":\(quarter)"
                segments.append(.init(edge: quarter * 2, edgeID: id + ":dirt" + suffix,
                    forward: true, meters: dirtMeters / 4, surface: .gravel, surfaceLeaf: "gravel",
                    roadClass: "track", structure: "", access: 0, geometry: [begin,turn]))
                segments.append(.init(edge: quarter * 2 + 1, edgeID: id + ":paved" + suffix,
                    forward: true, meters: (100_000 - dirtMeters) / 4, surface: .paved, surfaceLeaf: "asphalt",
                    roadClass: "tertiary", structure: "", access: 0, geometry: [turn,end]))
            }
            return .init(start: .init(edge: 0, coordinate: a, distanceMeters: 0, alongMeters: 0, geometryMeters: 100_000),
                end: .init(edge: 1, coordinate: c, distanceMeters: 0, alongMeters: 100_000, geometryMeters: 100_000),
                segments: segments, distanceMeters: 100_000, searchCost: 100_000, poppedLabels: 1, arrivalRestrictions: [])
        }
        let dirt = route(90_000, id: "more-packs"), balanced = route(50_000, id: "fewer-packs")
        let paved = route(0, id: "paved")
        for options in [[balanced,paved,dirt], [dirt,paved,balanced]] {
            #expect(StagedRouter.selectConnectionRoute(options, style: .dirt)?.segments.first?.edgeID == "more-packs:dirt")
            #expect(StagedRouter.selectConnectionRoute(options, style: .balanced)?.segments.first?.edgeID == "fewer-packs:dirt")
            #expect(StagedRouter.selectConnectionRoute(options, style: .cleanest)?.segments.first?.edgeID == "paved:dirt")
        }
    }
    @Test func bridgeCorridorSurvivesAShorterFerryRegionChain() throws {
        let all: [String:Set<String>] = ["ns":["nb","pe"],"nb":["ns","pe"],"pe":["ns","nb"]]
        let road: [String:Set<String>] = ["ns":["nb"],"nb":["ns","pe"],"pe":["nb"]]
        let connectivity = RegionConnectivity(neighbors: all)
        #expect(try connectivity.chains(from: "ns", to: "pe", roadNeighbors: road) == [["ns","nb","pe"],["ns","pe"]])
        #expect(try connectivity.chains(from: "pe", to: "ns", roadNeighbors: road) == [["pe","nb","ns"],["pe","ns"]])
        #expect(try connectivity.chains(from: "ns", to: "pe", roadNeighbors: [:]) == [["ns","pe"]])
        let island = RegionConnectivity(neighbors: ["mainland":["island"],"island":["mainland"]])
        #expect(try island.chains(from: "mainland", to: "island", roadNeighbors: [:]) == [["mainland","island"]])
    }
    @Test func networkURLsAreRejectedBeforeAnyRead() {
        #expect(throws: RoutingFailure.self) { try PackRepository(installedDirectories: ["ns": URL(string: "https://invalid.example/ns")!]) }
        #expect(throws: RoutingFailure.self) { try BinaryFile(url: URL(string: "https://invalid.example/graph.v4.bin")!) }
    }
    @Test func missingDataIsNotNoPath() throws {
        let repository = try PackRepository(installedDirectories: [:])
        #expect(repository.missing(["ns","nb","qc","ns"]) == ["nb","ns","qc"])
        #expect(throws: RoutingFailure.missingPacks(["ns"])) { try repository.open("ns") }
    }
    @Test func intermediateRegionIsRequiredEvenWithoutARiderPin() throws {
        let topology = RegionConnectivity(neighbors: ["ns":["nb"],"nb":["ns","qc"],"qc":["nb","on"],"on":["qc"]])
        #expect(try topology.chain(from: "ns",to: "on") == ["ns","nb","qc","on"])
        #expect(try topology.chain(from: "on",to: "ns") == ["on","qc","nb","ns"])
        let repository = try PackRepository(installedDirectories: ["ns": URL(fileURLWithPath: "/unused/ns"),"on": URL(fileURLWithPath: "/unused/on")])
        #expect(try repository.missing(topology.chain(from: "ns",to: "on")) == ["nb","qc"])
    }
    @Test func betterWeakestSectionWinsDirtTie() {
        var a = RouteQuality(), b = RouteQuality()
        a.knownDirtPercent = 68; b.knownDirtPercent = 67
        a.minimumSectionDirtPercent = 12; b.minimumSectionDirtPercent = 38
        a.longestPavedRunMeters = 46_000; b.longestPavedRunMeters = 24_000
        a.pavedMeters = 130_000; b.pavedMeters = 145_000
        #expect(RouteQuality.prefersDirt(b,over: a,widthA: 120_000,widthB: 60_000))
        #expect(!RouteQuality.prefersDirt(a,over: b,widthA: 60_000,widthB: 120_000))
    }
    @Test func cancelledComputationCannotRun() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try ComputationBudget().check(); Issue.record("cancelled budget accepted") }
            catch is CancellationError { }
            catch { Issue.record("wrong cancellation error: \(error)") }
        }
        await task.value
    }
}
