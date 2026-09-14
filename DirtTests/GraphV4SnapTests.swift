import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("V4 snap radius and connectivity")
struct GraphV4SnapTests {
    @Test("tap radius is zoom-aware and capped at 2000 m for V4")
    func tapRadiusZoomAware() {
        let yarmouth = TapRadius.meters(zoom: 10, latitude: 43.65, graphBinaryVersion: 4)
        #expect(yarmouth >= 1_700)
        #expect(yarmouth <= TapRadius.v4CapMeters)
        let street = TapRadius.meters(zoom: 16, latitude: 43.65, graphBinaryVersion: 4)
        #expect(street < 250)
        #expect(TapRadius.meters(latitude: 43.65, requestedMeters: 5_000, graphBinaryVersion: 4) == TapRadius.v4CapMeters)
        #expect(TapRadius.meters(latitude: 43.65, requestedMeters: 5_000, graphBinaryVersion: 3) == TapRadius.v3CapMeters)
    }

    @Test("divided highway snap keeps heading scores, not nearest edge-index")
    func dividedHighwayKeepsHeadingScores() throws {
        let graph = try Data(contentsOf: fixtureURL("legal-topology-canary.graph.v4.bin"))
        let geom = try Data(contentsOf: fixtureURL("legal-topology-canary.geometry.v1.bin"))
        let pack = try GraphV2Pack(data: graph)
        pack.geometry = try GeometryV1Pack(data: geom)
        var router = try fixtureRouter(pack: pack)
        router.mapZoom = 16
        let westStart = CLLocationCoordinate2D(latitude: 45.80779, longitude: -64.191)
        let westEnd = CLLocationCoordinate2D(latitude: 45.80779, longitude: -64.209)
        switch router.routeDetailed(from: westStart, to: westEnd, profile: .balanced, allowUnknown: false) {
        case .success(let result):
            #expect(result.snapDiagnostics?.end?.osmWayId == "537982310" || result.coordinates.count >= 2)
            #expect(!(result.snapDiagnostics?.end?.osmWayId == "537982311"))
            #expect(result.allowUnknownLogged == false)
            #expect(result.tapRadiusMeters != nil)
        case .failure(let error):
            Issue.record("westbound V4 snap/search failed: \(error)")
        }
    }

    @Test("Yarmouth harbour fixture prefers the connected town road")
    func yarmouthHarbourConnectedRoad() throws {
        let graphURL = fixtureURL("yarmouth-harbour.graph.v4.bin")
        guard FileManager.default.fileExists(atPath: graphURL.path) else {
            Issue.record("missing yarmouth-harbour fixture")
            return
        }
        let graph = try Data(contentsOf: graphURL)
        let geom = try Data(contentsOf: fixtureURL("yarmouth-harbour.geometry.v1.bin"))
        let pack = try GraphV2Pack(data: graph)
        pack.geometry = try GeometryV1Pack(data: geom)
        var router = try fixtureRouter(pack: pack)
        router.mapZoom = 10
        let start = CLLocationCoordinate2D(latitude: 45.390440, longitude: -63.201514)
        let harbour = CLLocationCoordinate2D(latitude: 43.648606, longitude: -65.774864)
        switch router.routeDetailed(from: start, to: harbour, profile: .balanced, allowUnknown: false) {
        case .success(let result):
            #expect(result.snapDiagnostics?.end?.osmWayId != "100")
            #expect(["200", "400"].contains(result.snapDiagnostics?.end?.osmWayId ?? ""))
            let snapped = result.coordinates.last
            #expect(snapped != nil)
        case .failure(let error):
            Issue.record("Yarmouth harbour tap failed: \(error)")
        }
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }
}
