import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite("Reachable field exact cached matches", .serialized)
struct ReachableCacheFirstTests {
    private func fixture(fileGeometry: Bool = false) throws -> (GraphV2Pack, URL?) {
        let prefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety")
        let pack = try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path + ".graph.v4.bin")))
        let geometry = try Data(contentsOf: URL(fileURLWithPath: prefix.path + ".geometry.v1.bin"))
        var file: URL?
        if fileGeometry {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".geometry")
            try geometry.write(to: url)
            file = url
            pack.geometry = try GeometryV1Pack(url: url,
                identity: .init(sha256: SHA256.hash(data: geometry).map { String(format: "%02x", $0) }.joined(), bytes: geometry.count),
                expectedEdgeCount: pack.undirectedEdgeCount)
        } else { pack.geometry = try GeometryV1Pack(data: geometry) }
        _ = try fixtureRouter(pack: pack)
        return (pack, file)
    }
    private func point(_ pack: GraphV2Pack, _ node: Int) -> CLLocationCoordinate2D {
        .init(latitude: Double(pack.nodeCoords[node * 2 + 1]), longitude: Double(pack.nodeCoords[node * 2]))
    }
    @Test func cacheFirstRetainsEachNewBoundedFieldResult() throws {
        let (pack, _) = try fixture()
        let from = point(pack, 0), toward = point(pack, pack.nodeCount - 1)
        let points = (0..<pack.nodeCount).map { point(pack, $0) } + [
            CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude + 0.00001),
            CLLocationCoordinate2D(latitude: 80, longitude: 80)
        ]
        let pumps = points.enumerated().map { index, point in
            POIFeature(id: "pump-\(index)",category: "fuel",latitude: point.latitude,longitude: point.longitude,
                name: nil,address: nil,brand: nil,openingHours: nil,phone: nil,website: nil)
        }
        for profile: RouteProfile in [.dirt,.balanced,.cleanest] {
            for unknown in [false,true] {
                for range in [1.0, 1_000.0, 100_000.0] {
                    var reference = try fixtureRouter(pack: pack)
                    reference.useReachableCachedMatchesBeforeCoverage = false
                    let expected = try reference.reachableGraphMeters(from: from,toward: toward,pumps: pumps,
                        maxMeters: range,profile: profile,allowUnknown: unknown)
                    let current = try fixtureRouter(pack: pack)
                    let measurement = RoutingMeasurement(metadata: ["case": "reachable-cache-first"])
                    let actual = try RoutingWorkContext.$measurement.withValue(measurement) {
                        try current.reachableGraphMeters(from: from,toward: toward,pumps: pumps,
                            maxMeters: range,profile: profile,allowUnknown: unknown)
                    }
                    #expect(expected.mapValues(\.bitPattern) == actual.mapValues(\.bitPattern))
                    #expect((measurement.finish(outcome: "complete").counters["rangeSnapCoverageBypasses"] ?? 0) > 0)
                }
            }
        }
    }
}
