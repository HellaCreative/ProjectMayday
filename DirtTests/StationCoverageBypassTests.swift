import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Optional station coverage preprobe qualification", .serialized)
struct StationCoverageBypassTests {
    @Test func exactFuelDistancesKeepSameEdgeRestrictedAndUnmatchedResults() throws {
        for name in ["initial-same-edge-oneway", "legal-topology-restrictions", "native-preferences-variety"] {
            for profile: RouteProfile in [.dirt,.balanced,.cleanest] {
                for reverse in [false,true] {
                    let a = try fixture(name), b = try fixture(name)
                    let anchor = point(a,0), points = candidates(a)
                    let expected = try OnDeviceRouter.fuelRoadDistances(packs: [a],anchor: anchor,
                        points: points,profile: profile,allowUnknown: false,reverse: reverse,
                        useCachedMatchesBeforeCoverage: false,useStationCoveragePreprobe: true)
                    let measurement = RoutingMeasurement(metadata: ["fixture": name,"preprobe": "off"])
                    let actual = try RoutingWorkContext.$measurement.withValue(measurement) {
                        try OnDeviceRouter.fuelRoadDistances(packs: [b],anchor: anchor,
                            points: points,profile: profile,allowUnknown: false,reverse: reverse,
                            useCachedMatchesBeforeCoverage: false,useStationCoveragePreprobe: false)
                    }
                    #expect(expected?.map(\.bitPattern) == actual?.map(\.bitPattern))
                    #expect(actual?.last?.isInfinite == true)
                    let report = measurement.finish(outcome: "compared")
                    #expect((report.counters["stationMatchesSkipped"] ?? 0) == 0)
                    #expect((report.counters["stationCoverageEdgesScanned"] ?? 0) == 0)
                    print("[coverage-bypass] fixture=\(name) profile=\(profile.rawValue) reverse=\(reverse) seconds=\(report.totalSeconds)")
                }
            }
        }
    }

    @Test func reachableRangeFieldRetainsEveryExactStationResult() throws {
        for name in ["initial-same-edge-oneway", "legal-topology-restrictions"] {
            for range in [1.0,1000.0,100000.0] {
                let a = try fixture(name), b = try fixture(name)
                let points = candidates(a)
                let pumps = points.enumerated().map { i,p in
                    POIFeature(id: "p\(i)",category: "fuel",latitude: p.latitude,longitude: p.longitude,
                        name: nil,address: nil,brand: nil,openingHours: nil,phone: nil,website: nil)
                }
                var reference = try fixtureRouter(pack: a), bypass = try fixtureRouter(pack: b)
                reference.useReachableCachedMatchesBeforeCoverage = false
                bypass.useReachableCachedMatchesBeforeCoverage = false
                bypass.useStationCoveragePreprobe = false
                let expected = try reference.reachableGraphMeters(from: point(a,0),toward: point(a,a.nodeCount-1),
                    pumps: pumps,maxMeters: range,profile: .dirt,allowUnknown: false)
                let actual = try bypass.reachableGraphMeters(from: point(b,0),toward: point(b,b.nodeCount-1),
                    pumps: pumps,maxMeters: range,profile: .dirt,allowUnknown: false)
                #expect(expected.mapValues(\.bitPattern) == actual.mapValues(\.bitPattern))
                #expect(actual["p\(points.count-1)"] == nil)
            }
        }
    }

    @Test func bypassDoesNotTurnCancellationIntoDisconnectedField() throws {
        let pack = try fixture("initial-same-edge-oneway")
        #expect(throws: (any Error).self) {
            try RoutingWorkContext.$deadline.withValue(0) {
                _ = try OnDeviceRouter.fuelRoadDistances(packs: [pack],anchor: point(pack,0),
                    points: candidates(pack),profile: .dirt,allowUnknown: false,reverse: false,
                    useStationCoveragePreprobe: false)
            }
        }
    }

    private func fixture(_ name: String) throws -> GraphV2Pack {
        let prefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/"+name)
        let pack = try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path+".graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path+".geometry.v1.bin")))
        _ = try fixtureRouter(pack: pack)
        return pack
    }
    private func point(_ pack: GraphV2Pack,_ node: Int) -> CLLocationCoordinate2D {
        .init(latitude: Double(pack.nodeCoords[node*2+1]),longitude: Double(pack.nodeCoords[node*2]))
    }
    private func candidates(_ pack: GraphV2Pack) -> [CLLocationCoordinate2D] {
        let a = point(pack,Int(pack.edgeFrom![0])), b = point(pack,Int(pack.edgeTo![0]))
        return (0..<pack.nodeCount).map { point(pack,$0) } + [
            .init(latitude: a.latitude+(b.latitude-a.latitude)*0.25,longitude: a.longitude+(b.longitude-a.longitude)*0.25),
            .init(latitude: a.latitude+(b.latitude-a.latitude)*0.75,longitude: a.longitude+(b.longitude-a.longitude)*0.75),
            .init(latitude: 80,longitude: 80)]
    }
}
