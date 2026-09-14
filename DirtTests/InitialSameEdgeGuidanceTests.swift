import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite struct InitialSameEdgeGuidanceTests {
    @Test func interiorPumpWithinRangeSurvivesUnreachedEndpoints() throws {
        var router = try fixture(oneWay: false)
        router.initialFuelApproach = true
        router.matchLimitMeters = 20
        for (from, to) in [(point(0.045), point(0.046)), (point(0.046), point(0.045))] {
            let found = try reachable(router, from: from, to: to, cap: 150)
            let distance = try #require(found["pump"])
            #expect(distance > 100 && distance < 120)
            guard case .success(let actual) = router.routeDetailed(from: from, to: to,
                profile: .balanced, allowUnknown: false, maxRouteMeters: 150) else {
                Issue.record("Mapped same-edge pump must have a real short legal approach"); continue
            }
            #expect(abs(actual.distanceMeters - distance) < 0.01)
            #expect(try reachable(router, from: from, to: to, cap: 100).isEmpty)
        }
    }

    @Test func oneWayApproachCannotUseReverseFraction() throws {
        let router = try fixture(oneWay: true)
        #expect(try reachable(router, from: point(0.045), to: point(0.046), cap: 150)["pump"] != nil)
        #expect(try reachable(router, from: point(0.046), to: point(0.045), cap: 150).isEmpty)
    }

    @Test func directedUnknownAndDeniedRemainDistinct() throws {
        for code: UInt8 in [1, 2, 5] {
            let router = try fixture(oneWay: false, reverseAccess: code)
            for allow in [false, true] {
                let reverse = try reachable(router, from: point(0.046), to: point(0.045), cap: 150, allow: allow)
                #expect((reverse["pump"] != nil) == (code == 1 && allow))
                let forward = try reachable(router, from: point(0.045), to: point(0.046), cap: 150, allow: allow)
                #expect(forward["pump"] != nil)
            }
            #expect(try reachable(router, from: point(0.046), to: point(0.045), cap: 150,
                profile: .cleanest, allow: true).isEmpty)
        }
    }

    private func point(_ lon: Double) -> CLLocationCoordinate2D { .init(latitude: 0, longitude: lon) }
    private func reachable(_ router: OnDeviceRouter, from: CLLocationCoordinate2D,
                           to: CLLocationCoordinate2D, cap: Double,
                           profile: RouteProfile = .balanced, allow: Bool = false) throws -> [String: Double] {
        let pump = POIFeature(id: "pump", category: "fuel", latitude: to.latitude, longitude: to.longitude,
            name: "Interior pump", address: nil, brand: nil, openingHours: nil, phone: nil, website: nil)
        return try router.reachableGraphMeters(from: from, toward: to, pumps: [pump],
            maxMeters: cap, profile: profile, allowUnknown: allow)
    }
    private func fixture(oneWay: Bool, reverseAccess: UInt8? = nil) throws -> OnDeviceRouter {
        let name = "initial-same-edge" + (oneWay ? "-oneway" : "")
        func url(_ suffix: String) -> URL {
            let file = name + suffix
            let bundle = Bundle(for: InitialSameEdgeGuidanceBundle.self)
            return bundle.url(forResource: file, withExtension: nil)
                ?? bundle.url(forResource: file, withExtension: nil, subdirectory: "Fixtures")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + file)
        }
        var graph = try Data(contentsOf: url(".graph.v4.bin"))
        if let reverseAccess {
            let offset = (0..<4).reduce(0) { $0 | (Int(graph[112 + $1]) << ($1 * 8)) }
            graph[offset + 1] = reverseAccess
        }
        let pack = try GraphV2Pack(data: graph)
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: url(".geometry.v1.bin")))
        #expect(pack.undirectedEdgeCount == 1)
        return try fixtureRouter(pack: pack)
    }
}
private final class InitialSameEdgeGuidanceBundle: NSObject {}
