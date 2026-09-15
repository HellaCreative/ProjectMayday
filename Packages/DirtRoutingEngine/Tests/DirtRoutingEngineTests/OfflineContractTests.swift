import Foundation
import Testing
@testable import DirtRoutingEngine

struct OfflineContractTests {
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
