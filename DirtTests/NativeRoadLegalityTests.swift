import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct NativeRoadLegalityTests {
    private enum Failure: Error { case unavailable }
    @Test func directedCodeScopeLawMatchesNativeForAllCodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-forecourt.graph.v4.bin")
        let original = try Data(contentsOf: url)
        let at = original.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 112)) }
        let codes: [UInt8] = [0,1,2,3,4,5,255]
        for code in codes {
            var bytes = original; bytes[at] = code; bytes[at+1] = code
            let pack = try GraphV2Pack(data: bytes)
            let a = Int(try #require(pack.edgeFrom?[0])), b = Int(try #require(pack.edgeTo?[0]))
            let kinds: [String?] = [nil,"customers","ordinary"]
            for (from,to) in [(a,b),(b,a)] {
                for start in [-1,0] { for end in [-1,0] {
                    for startKind in kinds { for endKind in kinds {
                        for unknown in [false,true] { for group in [false,true] {
                            let customerEdges: Set<Int> = group ? [0] : []
                            let old = pack.v4AccessAllowed(ei: 0,from: from,to: to,startEi: start,endEi: end,
                                allowUnknown: unknown,startEndpointKind: startKind,endEndpointKind: endKind,
                                customerStartEdges: customerEdges,customerEndEdges: customerEdges)
                            let new = pack.v4AccessAllowed(ei: 0,from: from,to: to,startEi: start,endEi: end,
                                allowUnknown: unknown,startEndpointKind: startKind,endEndpointKind: endKind,
                                customerStartEdges: customerEdges,customerEndEdges: customerEdges,useSharedPolicy: true)
                            #expect(old == new)
                            if code == 2 || code == 5 { #expect(!new) }
                        } }
                    } }
                } }
            }
        }
    }
    @Test func exactBoundsGeometryAndErrorsPreserveUrbanPolicy() throws {
        let owner = NSObject()
        let start = CLLocationCoordinate2D(latitude: 0,longitude: -2)
        let end = CLLocationCoordinate2D(latitude: 0,longitude: 2)
        let box = UrbanCore.Box(minLat: -0.5,maxLat: 0.5,minLon: -0.5,maxLon: 0.5,name: "fixture")
        var ctx = HopSearchContext.forProfile(.cleanest,seed: 17)
        ctx.cityWall = true; ctx.settlementWall = false; ctx.hardCorridor = false
        var reads: [String] = []
        func run(couldCross: Bool = true,failure: String? = nil,shape: [CLLocationCoordinate2D]? = nil) throws -> Bool {
            try NativeRoadBlockPolicy.blocked(end,edgeFrom: start,edgeIndex: 0,edgeShape: shape,
                from: start,to: end,ctx: ctx,sourceIdentity: owner,hasGeometry: true,
                urbanCores: { [box] },settlements: { [] },boundsMayIntersect: { _,_ in
                    reads.append("bounds"); if failure == "bounds" { throw Failure.unavailable }; return couldCross
                },geometryForEdge: { _ in
                    reads.append("geometry"); if failure == "geometry" { throw Failure.unavailable }; return [start,end]
                })
        }
        #expect(try run())
        #expect(reads == ["bounds","geometry"])
        reads = []; #expect(try !run(couldCross: false)); #expect(reads == ["bounds"])
        reads = []; #expect(throws: Failure.self) { try run(failure: "bounds") }; #expect(reads == ["bounds"])
        reads = []; #expect(throws: Failure.self) { try run(failure: "geometry") }; #expect(reads == ["bounds","geometry"])
        reads = []; #expect(try run(shape: [start,end])); #expect(reads == ["bounds"])
        ctx.urbanEdgeMemo = UrbanEdgeMemo(owner: owner,from: start,to: end,boxes: [box])
        reads = []; #expect(try run()); #expect(try run()); #expect(reads == ["bounds","geometry"])
        // Partial supplied shapes do not borrow a full-edge memo result.
        reads = []; _ = try run(shape: [end]); #expect(reads == ["bounds"])
    }
    @Test func settlementAndCorridorGatesRemainIndependentOfUrbanGeometry() throws {
        let start = CLLocationCoordinate2D(latitude: 0,longitude: -2)
        let end = CLLocationCoordinate2D(latitude: 0,longitude: 2)
        let point = CLLocationCoordinate2D(latitude: 1,longitude: 0)
        let box = UrbanCore.Box(minLat: 0.5,maxLat: 1.5,minLon: -0.5,maxLon: 0.5,name: "town")
        var ctx = HopSearchContext.forProfile(.cleanest,seed: 17)
        ctx.cityWall = false; ctx.settlementWall = true
        func blocked() throws -> Bool {
            try NativeRoadBlockPolicy.blocked(point,from: start,to: end,ctx: ctx,
                sourceIdentity: NSObject(),hasGeometry: false,urbanCores: { [] },settlements: { [box] },
                boundsMayIntersect: nil,geometryForEdge: { _ in throw Failure.unavailable })
        }
        #expect(try blocked())
        ctx.settlementWall = false; ctx.hardCorridor = true; ctx.corridorMeters = 100
        #expect(try blocked())
        ctx.hardCorridor = false; #expect(try !blocked())
    }
}
