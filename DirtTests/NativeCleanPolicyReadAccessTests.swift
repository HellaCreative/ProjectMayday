import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct NativeCleanPolicyReadAccessTests {
    private final class Spy: NativeCleanPolicyReadAccess {
        enum Failure: Error { case unavailable }
        var reads: [String] = []; var fail: String?
        func mark(_ name: String) throws { reads.append(name); if fail == name { throw Failure.unavailable } }
        func crossingSeconds(_ edge: Int) throws -> UInt32 { try mark("crossing"); return 60 }
        func roadTier(_ edge: Int) throws -> RoadTier { try mark("tier"); return .localPaved }
        func surfaceFamily(_ edge: Int) throws -> SurfaceFamily { try mark("family"); return .paved }
        func roadClassName(_ edge: Int) throws -> String { try mark("class"); return "unclassified" }
    }
    private let from = CLLocationCoordinate2D(latitude: 45,longitude: -64)
    private let to = CLLocationCoordinate2D(latitude: 45.2,longitude: -64)
    private func cost<R: NativeCleanPolicyReadAccess>(_ read: R,edge: Int = 0,attr: UInt16 = 0,
                                                    preferences: RidePreferences? = nil) throws -> Double {
        var ctx = HopSearchContext.forProfile(.cleanest,seed: 17)
        ctx.avoidMotorways = true; ctx.preferBackRoads = true
        return try NativeCleanProfileStep.cost(read: read,edge: edge,attributes: attr,meters: 1000,ctx: ctx,
            toLL: to,endLL: to,projectedOrigin: from,startOnMajorHighway: false,endOnMajorHighway: false,
            activePreferences: preferences)
    }
    @Test func lazyReadOrderAndFailurePropagationMatchNative() throws {
        let read = Spy()
        _ = try cost(read)
        #expect(read.reads == ["tier","family"])
        read.reads = []
        var preferences = RidePreferences(); preferences.avoidHighways = true
        _ = try cost(read,preferences: preferences)
        #expect(read.reads == ["tier","family","class"])
        read.reads = []
        _ = try cost(read,attr: 4 << 6,preferences: preferences)
        #expect(read.reads == ["crossing","class"])
        read.reads = []; read.fail = "tier"
        #expect(throws: Spy.Failure.self) { try cost(read,preferences: preferences) }
        #expect(read.reads == ["tier"])
    }
    @Test func pagedLeafReadsGiveBitIdenticalBaseCostWithoutGraphConstruction() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety.graph.v4.bin")
        let bytes = try Data(contentsOf: source)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined()
        let core = try PagedV4Core(url: source,identity: .init(sha256: hash,bytes: bytes.count))
        defer { core.close() }
        let details = try PagedEdgeDetail(url: source,identity: .init(sha256: hash,bytes: bytes.count,edgeCount: core.edgeCount))
        let metadata = try PagedCleanPolicyReadAccess.Metadata(core: core)
        let oracle = try GraphV2Pack(data: bytes) // Comparison only; paged path owns none.
        let array = ArrayCleanPolicyReadAccess(pack: oracle,query: nil)
        var prefs = RidePreferences(); prefs.wander = 0.5; prefs.avoidHighways = true
        try details.withQuery { query in
            let paged = try PagedCleanPolicyReadAccess(metadata: metadata,details: details,query: query)
            for edge in 0..<core.edgeCount {
                let choices: [RidePreferences?] = [nil,prefs]
                for preferences in choices {
                    for attr in [oracle.edgeAttrs[edge],UInt16(4 << 6)] {
                        let a = try cost(array,edge: edge,attr: attr,preferences: preferences)
                        let b = try cost(paged,edge: edge,attr: attr,preferences: preferences)
                        #expect(a.bitPattern == b.bitPattern)
                    }
                }
            }
        }
    }
}
