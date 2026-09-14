import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct OnewayGraphTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: src.path) { return src }
        Issue.record("missing fixture \(name)")
        throw GraphV2Pack.PackError.truncated
    }

    private func loadCanary() throws -> GraphV2Pack {
        let graph = try fixtureURL("oneway-canary.graph.v3.bin")
        let geom = try fixtureURL("oneway-canary.geometry.v1.bin")
        let pack = try GraphV2Pack(data: Data(contentsOf: graph))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: geom))
        return pack
    }

    @Test func packedOneWayEdgeHasOnlyTheLegalArc() throws {
        let pack = try loadCanary()
        #expect(pack.undirectedEdgeCount == 1)
        #expect(pack.directedArcCount == 1)
        #expect(pack.hasDirectedArc(from: 0, to: 1, edge: 0))
        #expect(!pack.hasDirectedArc(from: 1, to: 0, edge: 0))
    }

    @Test func onDeviceRouterRefusesIllegalOneWayReversal() throws {
        let pack = try loadCanary()
        let router = try fixtureRouter(pack: pack)
        let east = CLLocationCoordinate2D(latitude: 45.8071, longitude: -64.1882)
        let west = CLLocationCoordinate2D(latitude: 45.8071, longitude: -64.1888)
        switch router.routeDetailed(
            from: east,
            to: west,
            profile: .balanced,
            allowUnknown: false
        ) {
        case .success:
            break
        case .failure(let error):
            Issue.record("legal westbound one-way ride failed: \(error)")
        }

        switch router.routeDetailed(
            from: west,
            to: east,
            profile: .balanced,
            allowUnknown: false
        ) {
        case .success:
            Issue.record("illegal eastbound reverse on a one-way edge succeeded")
        case .failure:
            break
        }
    }
}
