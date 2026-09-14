import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite("Cached exact fuel matching before optional field probe", .serialized)
struct RangeSnapCacheFirstTests {
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
    @Test func sameDistancesWithWarmMatchesAcrossDirectionsAndPolicies() throws {
        let (pack, _) = try fixture()
        let anchor = point(pack, 0)
        let points = (0..<pack.nodeCount).map { point(pack, $0) } + [
            CLLocationCoordinate2D(latitude: 80, longitude: 80),
            CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude + 0.00001)
        ]
        for profile: RouteProfile in [.dirt, .balanced, .cleanest] {
            for unknown in [false, true] {
                for reverse in [false, true] {
                    let old = try #require(try OnDeviceRouter.fuelRoadDistances(packs: [pack], anchor: anchor,
                        points: points, profile: profile, allowUnknown: unknown, reverse: reverse,
                        useCachedMatchesBeforeCoverage: false))
                    let measurement = RoutingMeasurement(metadata: ["case": "cache-first-fixture"])
                    let current = try RoutingWorkContext.$measurement.withValue(measurement) {
                        try #require(try OnDeviceRouter.fuelRoadDistances(packs: [pack], anchor: anchor,
                            points: points, profile: profile, allowUnknown: unknown, reverse: reverse))
                    }
                    #expect(old.map(\.bitPattern) == current.map(\.bitPattern))
                    #expect((measurement.finish(outcome: "complete").counters["rangeSnapCoverageBypasses"] ?? 0) > 0)
                }
            }
        }
    }
    @Test func warmMatchCannotHideTruncatedGeometryOrCancellation() throws {
        let (pack, file) = try fixture(fileGeometry: true)
        let url = try #require(file)
        defer { try? FileManager.default.removeItem(at: url) }
        let anchor = point(pack, 0)
        _ = try OnDeviceRouter.fuelRoadDistances(packs: [pack], anchor: anchor, points: [anchor],
            profile: .dirt, allowUnknown: false, reverse: true)
        #expect(throws: (any Error).self) {
            try RoutingWorkContext.$deadline.withValue(ProcessInfo.processInfo.systemUptime - 1) {
                try OnDeviceRouter.fuelRoadDistances(packs: [pack], anchor: anchor, points: [anchor],
                    profile: .dirt, allowUnknown: false, reverse: true)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0); try handle.close()
        #expect(throws: (any Error).self) {
            try OnDeviceRouter.fuelRoadDistances(packs: [pack], anchor: anchor, points: [anchor],
                profile: .dirt, allowUnknown: false, reverse: true)
        }
    }
}
