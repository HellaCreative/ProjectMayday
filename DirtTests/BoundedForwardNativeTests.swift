import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Bounded forward native guidance", .serialized)
struct BoundedForwardNativeTests {
    @Test func completedRangeMatchesFullFieldForEveryUsableStation() throws {
        for name in ["initial-same-edge-oneway","legal-topology-restrictions","native-preferences-variety"] {
            for profile: RouteProfile in [.dirt,.balanced,.cleanest] {
                for range in [1.0,1000.0,100000.0] {
                    let pack = try fixture(name), points = candidates(pack)
                    // Interior origins ensure protected same-edge continuation is exercised.
                    let anchor = points[points.count-3]
                    let full = try #require(try OnDeviceRouter.fuelRoadDistances(packs: [pack],seamSnapshots: [[:]],
                        anchor: anchor,points: points,profile: profile,allowUnknown: false,reverse: false,
                        useCachedMatchesBeforeCoverage: false,useStationCoveragePreprobe: false))
                    let bounded = try #require(try OnDeviceRouter.fuelRoadDistances(packs: [pack],seamSnapshots: [[:]],
                        anchor: anchor,points: points,profile: profile,allowUnknown: false,reverse: false,
                        useCachedMatchesBeforeCoverage: false,useStationCoveragePreprobe: false,forwardRangeMeters: range))
                    var limits = BoundedForwardFuelField.Limits()
                    limits.states = 1; limits.queueEntries = 2
                    let fallback = try #require(try OnDeviceRouter.fuelRoadDistances(packs: [pack],seamSnapshots: [[:]],
                        anchor: anchor,points: points,profile: profile,allowUnknown: false,reverse: false,
                        useCachedMatchesBeforeCoverage: false,useStationCoveragePreprobe: true,
                        forwardRangeMeters: range,forwardFieldLimits: limits))
                    #expect(full.count == fallback.count)
                    #expect(full.count == bounded.count)
                    for i in full.indices {
                        #expect((full[i] <= range) == (bounded[i] <= range))
                        #expect((full[i] <= range) == (fallback[i] <= range))
                        if full[i] <= range { #expect(abs(full[i]-fallback[i]) < 0.000001) }
                        if full[i] <= range { #expect(abs(full[i]-bounded[i]) < 0.000001) }
                    }
                }
            }
        }
    }
    @Test func cancellationAndMismatchedSeamSnapshotsDoNotProduceRangeProof() throws {
        let pack = try fixture("initial-same-edge-oneway")
        #expect(throws: (any Error).self) {
            try OnDeviceRouter.fuelRoadDistances(packs: [pack],seamSnapshots: [],anchor: point(pack,0),
                points: candidates(pack),profile: .dirt,allowUnknown: false,reverse: false,forwardRangeMeters: 1000)
        }
        #expect(throws: (any Error).self) {
            try RoutingWorkContext.$deadline.withValue(0) {
                try OnDeviceRouter.fuelRoadDistances(packs: [pack],seamSnapshots: [[:]],anchor: point(pack,0),
                    points: candidates(pack),profile: .dirt,allowUnknown: false,reverse: false,forwardRangeMeters: 1000)
            }
        }
    }
    @Test func directedAccessAndUnknownPolicyKeepSameEdgeStationsHonest() throws {
        let prefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety")
        let original = try Data(contentsOf: URL(fileURLWithPath: prefix.path+".graph.v4.bin"))
        let geometry = try Data(contentsOf: URL(fileURLWithPath: prefix.path+".geometry.v1.bin"))
        let base = try GraphV2Pack(data: original)
        let a = Int(try #require(base.edgeFrom)[0]), b = Int(try #require(base.edgeTo)[0])
        #expect(base.hasDirectedArc(from: a,to: b,edge: 0))
        #expect(base.hasDirectedArc(from: b,to: a,edge: 0))
        let start = point(base,a), end = point(base,b)
        func along(_ fraction: Double) -> CLLocationCoordinate2D {
            .init(latitude: start.latitude+(end.latitude-start.latitude)*fraction,
                longitude: start.longitude+(end.longitude-start.longitude)*fraction)
        }
        let origin = along(0.5), ahead = along(0.75), behind = along(0.25)
        let expectedAhead = CLLocation(latitude: origin.latitude,longitude: origin.longitude)
            .distance(from: CLLocation(latitude: ahead.latitude,longitude: ahead.longitude))
        let accessAt = Int(original.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 112,as: UInt32.self).littleEndian })
        for forward: UInt8 in [0,1] {
            for denied: UInt8 in [2,5] {
                for profile: RouteProfile in [.dirt,.balanced,.cleanest] {
                    for allowUnknown in [false,true] {
                        var data = original
                        // Keep the actual bidirectional CSR; deny every other
                        // edge so neither alternate matching nor a detour can
                        // manufacture an approach to the station behind us.
                        data.replaceSubrange(accessAt..<(accessAt+base.undirectedEdgeCount*2),
                            with: [UInt8](repeating: 2,count: base.undirectedEdgeCount*2))
                        data[accessAt] = forward; data[accessAt+1] = denied
                        let pack = try GraphV2Pack(data: data)
                        pack.geometry = try GeometryV1Pack(data: geometry)
                        _ = try fixtureRouter(pack: pack)
                        let permitted = forward == 0 || (allowUnknown && profile != .cleanest)
                        for mode in 0..<3 {
                            var limits = BoundedForwardFuelField.Limits()
                            if mode == 2 { limits.states = 1;limits.queueEntries = 2 }
                            if !permitted && mode != 0 {
                                #expect(throws: (any Error).self) {
                                    try OnDeviceRouter.fuelRoadDistances(packs: [pack],seamSnapshots: [[:]],
                                        anchor: origin,points: [ahead,behind],profile: profile,allowUnknown: allowUnknown,
                                        reverse: false,useCachedMatchesBeforeCoverage: false,
                                        forwardRangeMeters: 1000,forwardFieldLimits: limits)
                                }
                                continue
                            }
                            let values = try #require(try OnDeviceRouter.fuelRoadDistances(packs: [pack],seamSnapshots: [[:]],
                                anchor: origin,points: [ahead,behind],profile: profile,allowUnknown: allowUnknown,
                                reverse: false,useCachedMatchesBeforeCoverage: false,
                                forwardRangeMeters: mode == 0 ? nil : 1000,forwardFieldLimits: limits))
                            #expect(values.count == 2)
                            #expect(values[1].isInfinite)
                            if permitted { #expect(abs(values[0]-expectedAhead) < 3) }
                            else { #expect(values[0].isInfinite) }
                        }
                    }
                }
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
