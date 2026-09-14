import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Native read pointer cache equivalence", .serialized)
struct NativeReadPointerCacheTests {
    @Test func nativeRoutesMatchWithReadPointerCacheEnabledAndDisabled() throws {
        for profile: RouteProfile in [.balanced,.dirt,.cleanest] {
            for seed: UInt64 in [0,17] {
                let a=try route(profile: profile,seed: seed,enabled: false)
                let b=try route(profile: profile,seed: seed,enabled: true)
                #expect(a.edgeIds == b.edgeIds)
                #expect(a.coordinates.map(\.latitude) == b.coordinates.map(\.latitude))
                #expect(a.coordinates.map(\.longitude) == b.coordinates.map(\.longitude))
                #expect(a.distanceMeters == b.distanceMeters)
                #expect(a.dirtPercent == b.dirtPercent)
                #expect(a.backtrackMeters == b.backtrackMeters)
                #expect(a.searchMeta.resourceSelectionCost == b.searchMeta.resourceSelectionCost)
                #expect(a.searchMeta.resourceSelectionDirtMeters == b.searchMeta.resourceSelectionDirtMeters)
                #expect(!a.searchMeta.timedOut && !b.searchMeta.timedOut)
                if profile == .balanced { #expect(a.searchMeta.resourceSelectionCost != nil) }
            }
        }
    }
    private func route(profile: RouteProfile,seed: UInt64,enabled: Bool) throws -> OnDeviceRouter.Result {
        let directory=URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let prefix=directory.appendingPathComponent("native-preferences-variety")
        let pack=try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path+".graph.v4.bin")))
        pack.geometry=try GeometryV1Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path+".geometry.v1.bin")))
        func point(_ id: Int64) throws -> CLLocationCoordinate2D {
            let node=try #require(pack.osmNodeIds.firstIndex(of: id))
            return .init(latitude: Double(pack.nodeCoords[node*2+1]),longitude: Double(pack.nodeCoords[node*2]))
        }
        var router=try fixtureRouter(pack: pack)
        router.matchLimitMeters=30
        router.recordedStartNode=try #require(pack.osmNodeIds.firstIndex(of: 1))
        router.recordedEndNode=try #require(pack.osmNodeIds.firstIndex(of: 4))
        router.useLabelReadPointerCache=enabled
        let outcome=router.routeDetailed(from: try point(1),to: try point(4),profile: profile,allowUnknown: false,sessionSeed: seed)
        guard case .success(let result)=outcome else { throw TestFailure.route("\(outcome)") }
        return result
    }
    private enum TestFailure: Error { case route(String) }
}
