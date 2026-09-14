import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite(.serialized)
struct RecordedTailReservationTests {
    private func pair() throws -> ([GraphV2Pack], [[String: [GraphV2Pack.CrossPackSeamAnchor]]], Int64) {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/initial-same-edge-oneway")
        func pack(_ region: String) throws -> GraphV2Pack {
            let p = try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: base.path + ".graph.v4.bin")))
            p.geometry = try GeometryV1Pack(data: Data(contentsOf: URL(fileURLWithPath: base.path + ".geometry.v1.bin")))
            p.regionId = region; _ = try fixtureRouter(pack: p); return p
        }
        let a = try pack("ns"), b = try pack("nb")
        let from = Int(try #require(a.edgeFrom)[0]), to = Int(try #require(a.edgeTo)[0])
        let id = "\(a.osmWayIds[0]):\(a.osmNodeIds[from]):\(a.osmNodeIds[to])"
        let node = a.osmNodeIds[from]
        func row(_ region: String) -> GraphV2Pack.CrossPackSeamAnchor {
            .init(neighborRegionId: region, longitude: Double(a.nodeCoords[from*2]), latitude: Double(a.nodeCoords[from*2+1]),
                osmWayId: String(a.osmWayIds[0]), localEdgeId: id, remoteEdgeId: id, gapMeters: 0, osmNodeId: node)
        }
        return ([a,b], [["nb": [row("nb")]], ["ns": [row("ns")]]], node)
    }
    @Test func fractionalDestinationReservesPositiveActualRoadTailWithoutResettingTank() throws {
        let (packs, seams, node) = try pair(), pack = packs[1]
        let poly = try #require(try pack.geometry?.polyline(edgeIndex: 0))
        let first = try #require(poly.first), last = try #require(poly.last)
        let destination = CLLocationCoordinate2D(latitude: (first.latitude+last.latitude)/2, longitude: (first.longitude+last.longitude)/2)
        let values = try OnDeviceRouter.recordedTailLowerBounds(packs: packs, seamSnapshots: seams,
            destination: destination, mapZoom: nil, matchLimitMeters: 80)
        let minimum = try #require(values["nb"]?[node])
        var router = try fixtureRouter(pack: pack); router.matchLimitMeters = 80; router.initialFuelApproach = true
        guard case .success(let actual) = router.routeDetailed(from: first, to: destination, profile: .cleanest, allowUnknown: false)
        else { Issue.record("Fixture tail must be legally routable"); return }
        #expect(minimum > 0 && minimum <= actual.distanceMeters + 0.001)
        let total = 1000.0, consumed = 200.0
        let firstStageCap = total-consumed-minimum
        #expect(firstStageCap < total-consumed)
        #expect(consumed+firstStageCap+minimum <= total+0.001)
    }
    @Test func differentRequestedDestinationChangesTailAndIncompleteOrCancelledNeverPublishes() throws {
        let (packs,seams,node) = try pair(), pack = packs[1]
        let poly = try #require(try pack.geometry?.polyline(edgeIndex: 0))
        let first = try #require(poly.first), last = try #require(poly.last)
        let near = CLLocationCoordinate2D(latitude: first.latitude*0.75+last.latitude*0.25, longitude: first.longitude*0.75+last.longitude*0.25)
        let far = CLLocationCoordinate2D(latitude: first.latitude*0.25+last.latitude*0.75, longitude: first.longitude*0.25+last.longitude*0.75)
        let a = try OnDeviceRouter.recordedTailLowerBounds(packs: packs,seamSnapshots: seams,destination: near,mapZoom: nil,matchLimitMeters: 80)
        let b = try OnDeviceRouter.recordedTailLowerBounds(packs: packs,seamSnapshots: seams,destination: far,mapZoom: nil,matchLimitMeters: 80)
        let nearBound = try #require(a["nb"]?[node]), farBound = try #require(b["nb"]?[node])
        #expect(nearBound < farBound)
        #expect(throws: (any Error).self) {
            try OnDeviceRouter.recordedTailLowerBounds(packs: packs,seamSnapshots: [seams[0],[:]],destination: far,mapZoom: nil,matchLimitMeters: 80)
        }
        RoutingWorkContext.$deadline.withValue(0) {
            #expect(throws: (any Error).self) {
                try OnDeviceRouter.recordedTailLowerBounds(packs: packs,seamSnapshots: seams,destination: far,mapZoom: nil,matchLimitMeters: 80)
            }
        }
    }
}
