import Foundation
import Testing
@testable import DirtRoutingEngine

struct OfflineContractTests {
    @Test func riderCountriesExcludeShorterInternationalDetoursAndFailClosed() throws {
        let graph = RegionConnectivity(neighbors: [
            "nh": ["qc-s", "vt"], "qc-s": ["nh", "on-n", "nb"],
            "on-n": ["qc-s", "mi"], "mi": ["on-n", "in", "oh"],
            "in": ["mi", "oh"], "vt": ["nh", "ny"], "ny": ["vt", "pa"],
            "pa": ["ny", "oh"], "oh": ["pa", "mi", "in"], "nb": ["qc-s"]])
        let domestic = graph.respectingCountries(from: "nh", to: "in")
        #expect(try domestic.chain(from: "nh", to: "in") == ["nh", "vt", "ny", "pa", "oh", "in"])
        for avoid in [true, false] {
            let paths = try domestic.chains(from: "nh", to: "in", roadNeighbors: graph.neighbors, avoidFerries: avoid)
            #expect(paths.allSatisfy { $0.allSatisfy(RegionConnectivity.unitedStatesRegions.contains) })
        }
        let missing = RegionConnectivity(neighbors: ["nh": ["qc-s"], "qc-s": ["nh", "on-n"], "on-n": ["in"], "in": []])
        #expect(throws: RoutingFailure.noPath) {
            try missing.respectingCountries(from: "nh", to: "in").chain(from: "nh", to: "in")
        }
        let canada = RegionConnectivity(neighbors: ["bc": ["wa", "ab"], "wa": ["bc", "on-n"], "ab": ["sk"], "sk": ["mb"], "mb": ["on-n"], "on-n": []])
        #expect(try canada.respectingCountries(from: "bc", to: "on-n").chain(from: "bc", to: "on-n") == ["bc", "ab", "sk", "mb", "on-n"])
    }

    @Test func explicitCrossBorderPinPermitsOneCrossingInEitherDirection() throws {
        let graph = RegionConnectivity(neighbors: ["nb": ["me"], "me": ["nb", "qc-s", "nh"], "qc-s": ["me", "ny"], "nh": ["me", "vt"], "vt": ["nh", "ny"], "ny": ["qc-s", "vt"]])
        #expect(try graph.respectingCountries(from: "nb", to: "ny").chain(from: "nb", to: "ny") == ["nb", "me", "nh", "vt", "ny"])
        #expect(try graph.respectingCountries(from: "ny", to: "nb").chain(from: "ny", to: "nb") == ["ny", "vt", "nh", "me", "nb"])
        #expect(try graph.respectingCountries(from: "me", to: "qc-s").chain(from: "me", to: "qc-s") == ["me", "qc-s"])
    }

    private func route(_ dirtMeters: Double, id: String) -> ComputedRoute {
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

    @Test func completedConnectionReturnsWithoutBuildingAnotherJourney() throws {
        var attempted: [[String]] = []
        let result = try StagedRouter.firstCompletedConnection([["first"], ["unused"]], budget: .init(seconds: 60)) { chain, _ in
            attempted.append(chain)
            return route(50_000, id: chain[0])
        }
        #expect(attempted == [["first"]])
        #expect(result.segments.first?.edgeID == "first:dirt")
        #expect(result.limit == nil)
    }

    @Test func failedConnectionTriesFallbackWithoutTaintingItsCompleteResult() throws {
        for failure: RoutingFailure in [.noPath, .resourceLimit("labels")] {
            var attempted: [[String]] = []
            let result = try StagedRouter.firstCompletedConnection([["blocked"], ["working"], ["unused"]], budget: .init(seconds: 60)) { chain, _ in
                attempted.append(chain)
                if chain == ["blocked"] { throw failure }
                return route(50_000, id: chain[0])
            }
            #expect(attempted == [["blocked"], ["working"]])
            #expect(result.segments.first?.edgeID == "working:dirt")
            #expect(result.limit == nil)
        }
    }

    @Test func unfinishedConnectionDoesNotMasqueradeAsCompletionOrDisconnection() {
        #expect(throws: RoutingFailure.resourceLimit("labels")) {
            try StagedRouter.firstCompletedConnection([["incomplete"], ["disconnected"]], budget: .init(seconds: 60)) { chain, _ in
                if chain == ["disconnected"] { throw RoutingFailure.noPath }
                return route(50_000, id: "unfinished").reportingLimit("labels")
            }
        }
        #expect(throws: RoutingFailure.noPath) {
            try StagedRouter.firstCompletedConnection([["disconnected"]], budget: .init(seconds: 60)) { _, _ in
                throw RoutingFailure.noPath
            }
        }
    }

    @Test func connectionCancellationDoesNotLaunchFallback() {
        var attempts = 0
        #expect(throws: CancellationError.self) {
            try StagedRouter.firstCompletedConnection([["first"], ["unused"]], budget: .init(seconds: 60)) { _, _ in
                attempts += 1
                throw CancellationError()
            }
        }
        #expect(attempts == 1)
    }
    @Test func bridgeCorridorSurvivesAShorterFerryRegionChain() throws {
        let all: [String:Set<String>] = ["ns":["nb","pe"],"nb":["ns","pe"],"pe":["ns","nb"]]
        let road: [String:Set<String>] = ["ns":["nb"],"nb":["ns","pe"],"pe":["nb"]]
        let connectivity = RegionConnectivity(neighbors: all)
        #expect(try connectivity.chains(from: "ns", to: "pe", roadNeighbors: road) == [["ns","pe"],["ns","nb","pe"]])
        #expect(try connectivity.chains(from: "pe", to: "ns", roadNeighbors: road) == [["pe","ns"],["pe","nb","ns"]])
        #expect(try connectivity.chains(from: "ns", to: "pe", roadNeighbors: [:]) == [["ns","pe"],["ns","nb","pe"]])
        let island = RegionConnectivity(neighbors: ["mainland":["island"],"island":["mainland"]])
        #expect(try island.chains(from: "mainland", to: "island", roadNeighbors: [:]) == [["mainland","island"]])
    }
    @Test func sharedFerryDoesNotEraseIntermediateLandingRegion() throws {
        let all: [String:Set<String>] = [
            "origin":["island","inland"], "island":["origin","landing","destination"],
            "landing":["island","destination","inland"], "inland":["origin","landing"],
            "destination":["island","landing"]]
        let roads: [String:Set<String>] = ["origin":["inland"], "inland":["origin","landing"],
            "landing":["inland","destination"], "destination":["landing"]]
        let chains = try RegionConnectivity(neighbors: all).chains(from: "origin", to: "destination", roadNeighbors: roads)
        #expect(chains.first == ["origin","island","destination"])
        #expect(chains.contains(["origin","island","landing","destination"]))
        #expect(chains.contains(["origin","inland","landing","destination"]))
        #expect(chains.count == 3)
        #expect(chains.allSatisfy { Set($0).count == $0.count })
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
