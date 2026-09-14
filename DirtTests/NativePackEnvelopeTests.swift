import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite(.serialized)
struct NativePackEnvelopeTests {
    @Test func envelopeBypassPreservesExactMatchingAndMissingResult() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/initial-same-edge-oneway")
        func make(_ enabled: Bool) throws -> OnDeviceRouter {
            let pack = try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: base.path + ".graph.v4.bin")))
            pack.geometry = try GeometryV1Pack(data: Data(contentsOf: URL(fileURLWithPath: base.path + ".geometry.v1.bin")))
            var router = try fixtureRouter(pack: pack); router.usePackGeometryEnvelope = enabled
            return router
        }
        let enabled = try make(true), disabled = try make(false)
        for profile: RouteProfile in [.dirt,.balanced,.cleanest] {
            for point in [CLLocationCoordinate2D(latitude: 0, longitude: 0),
                          .init(latitude: 45, longitude: -63)] {
                let a = try enabled.nearestRoadCoordinate(to: point, allowUnknown: false, profile: profile, maxMeters: 550)
                let b = try disabled.nearestRoadCoordinate(to: point, allowUnknown: false, profile: profile, maxMeters: 550)
                #expect(a?.latitude == b?.latitude && a?.longitude == b?.longitude)
            }
        }
        let measurement = RoutingMeasurement(metadata: ["case": "remote-pack-envelope"])
        let point = try RoutingWorkContext.$measurement.withValue(measurement) {
            try enabled.nearestRoadCoordinate(to: .init(latitude: 45, longitude: -63),
                allowUnknown: false, profile: .dirt, maxMeters: 550)
        }
        #expect(point == nil)
        #expect(measurement.finish(outcome: "unmatched").counters["snapEnvelopeRejectedQueries"] == 1)
    }
}
