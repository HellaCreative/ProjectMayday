import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Balanced envelope limit classification", .serialized)
struct BalancedEnvelopeSearchTests {
    @Test func limitsNeverImplyWidening() {
        for failure: OnDeviceRouter.Failure in [.searchLimit("timeCap"),.searchLimit("labelMemoryCap"),.searchLimit("cancelled"),.cannotSnapEnd] {
            var widths: [Double] = []
            let result: Swift.Result<Int,OnDeviceRouter.Failure> = BalancedEnvelopeSearch.run(widths: [1,2,0],deadline: 16,now: { 0 }) {
                widths.append($0); return .failure(failure)
            }
            #expect(widths == [1])
            if case .failure(let actual) = result { #expect(actual == failure) }
            else { Issue.record("Limit incorrectly became success") }
        }
    }
    @Test func provedNoPathCanWidenButCannotRenewWindow() {
        var clock = 0.0, widths: [Double] = []
        let result: Swift.Result<Int,OnDeviceRouter.Failure> = BalancedEnvelopeSearch.run(widths: [1,2,3,0],deadline: 16,now: { clock }) {
            widths.append($0);clock += 8;return .failure(.noPath)
        }
        #expect(widths == [1,2])
        if case .failure(let failure) = result { #expect(failure == .searchLimit("timeCap")) }
        else { Issue.record("Expired calculation incorrectly succeeded") }
    }
    @Test func provedNoPathStillPermitsSuccessfulWiderEnvelope() {
        var widths: [Double] = []
        let result: Swift.Result<Int,OnDeviceRouter.Failure> = BalancedEnvelopeSearch.run(widths: [1,2,0],deadline: 16,now: { 0 }) {
            widths.append($0); return $0 == 1 ? .failure(.noPath) : .success(42)
        }
        #expect(widths == [1,2])
        if case .success(let value) = result { #expect(value == 42) }
        else { Issue.record("Proved-disconnected corridor prevented widening") }
    }
    @Test func limitedIncumbentReturnsUnchanged() {
        var meta = OnDeviceRouter.SearchMeta(timedOut: true,pass2Outcome: "labelMemoryCap")
        meta.rideObjective = "surface-balance"
        var count = 0
        let result = BalancedEnvelopeSearch.run(widths: [1,2,0],deadline: 16,now: { 0 }) { _ -> Swift.Result<OnDeviceRouter.SearchMeta,OnDeviceRouter.Failure> in
            count += 1; return .success(meta)
        }
        #expect(count == 1)
        if case .success(let actual) = result { #expect(actual == meta); #expect(actual.limitedSearchWarning != nil) }
        else { Issue.record("Legal incumbent was discarded") }
    }
    @Test func nativeExpiredBudgetReturnsLimitWithoutWideningOrChangingProfile() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let prefix = directory.appendingPathComponent("native-preferences-variety")
        let pack = try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path+".graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path+".geometry.v1.bin")))
        let start = try #require(pack.osmNodeIds.firstIndex(of: 1)), end = try #require(pack.osmNodeIds.firstIndex(of: 4))
        func point(_ node: Int) -> CLLocationCoordinate2D { .init(latitude: Double(pack.nodeCoords[node*2+1]),longitude: Double(pack.nodeCoords[node*2])) }
        var router = try fixtureRouter(pack: pack)
        router.matchLimitMeters = 30;router.recordedStartNode = start;router.recordedEndNode = end
        router.balancedEnvelopeTimeCapSeconds = 0
        let outcome = router.routeDetailed(from: point(start),to: point(end),profile: .balanced,allowUnknown: false,sessionSeed: 17)
        if case .failure(let failure) = outcome { #expect(failure == .searchLimit("timeCap")) }
        else { Issue.record("Expired Balanced budget produced a substitute") }
        router.balancedEnvelopeTimeCapSeconds = HopSearchPolicy.pass2TimeCapSeconds
        let normal = router.routeDetailed(from: point(start),to: point(end),profile: .balanced,allowUnknown: false,sessionSeed: 17)
        if case .success(let route) = normal { #expect(route.searchMeta.rideObjective == "surface-balance") }
        else { Issue.record("Unexpired fixture lost its legal Balanced route") }
    }
}
