import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct ConnectedCleanStageTests {
    private func fixture() throws -> (ConnectedPackStageView, GraphV2Pack, Int, Int, Int) {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety")
        var bytes = try Data(contentsOf: URL(fileURLWithPath: base.path + ".graph.v4.bin"))
        let geometry = try Data(contentsOf: URL(fileURLWithPath: base.path + ".geometry.v1.bin"))
        func u32(_ offset: Int) -> Int { bytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) } }
        func put<T: FixedWidthInteger>(_ value: T, at: Int, into data: inout Data) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { data.replaceSubrange(at..<at + $0.count, with: $0) }
        }
        let metersAt = u32(40), attrsAt = u32(36), surfaceAt = u32(72), secondsAt = u32(100), accessAt = u32(112)
        // Test-only source variants: 10km shared start, cheap 185km ferry prefix
        // vs dearer 80+80km paved prefix; 20km tail in the second region.
        // Uses unchanged native Clean pricing; no injected cost callback.
        for (edge, meters) in [10_000,20_000,185_000,80_000,80_000,40_000].enumerated() {
            put(UInt32(meters),at: metersAt + edge * 4,into: &bytes)
            let attr = bytes.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: attrsAt + edge * 2,as: UInt16.self)) }
            put(attr & ~UInt16(7),at: attrsAt + edge * 2,into: &bytes)
            bytes[surfaceAt + edge] = 1
        }
        let ferryAttr = bytes.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: attrsAt + 4,as: UInt16.self)) }
        put((ferryAttr & ~(UInt16(7) << 6)) | (UInt16(4) << 6),at: attrsAt + 4,into: &bytes)
        put(UInt32(60),at: secondsAt + 8,into: &bytes)
        var aBytes = bytes, bBytes = bytes
        for edge in 0..<6 {
            for direction in 0..<2 {
                aBytes[accessAt + edge * 2 + direction] = (edge == 1 || edge == 5) ? 2 : 0
                bBytes[accessAt + edge * 2 + direction] = edge == 1 ? 0 : 2
            }
        }
        let a = try GraphV2Pack(data: aBytes), b = try GraphV2Pack(data: bBytes)
        a.regionId = "a"; b.regionId = "b"
        a.geometry = try GeometryV1Pack(data: geometry); b.geometry = try GeometryV1Pack(data: geometry)
        let start = try #require(a.osmNodeIds.firstIndex(of: 1))
        let seam = try #require(a.osmNodeIds.firstIndex(of: 3))
        let finish = try #require(a.osmNodeIds.firstIndex(of: 4))
        let first = Int(try #require(a.edgeFrom?[2])), last = Int(try #require(a.edgeTo?[2]))
        let id = "\(a.osmWayIds[2]):\(a.osmNodeIds[first]):\(a.osmNodeIds[last])"
        let anchor = GraphV2Pack.CrossPackSeamAnchor(neighborRegionId: "b",
            longitude: Double(a.nodeCoords[seam*2]),latitude: Double(a.nodeCoords[seam*2+1]),
            osmWayId: String(a.osmWayIds[2]),localEdgeId: id,remoteEdgeId: id,gapMeters: 0,osmNodeId: a.osmNodeIds[seam])
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined() }
        let view = try ConnectedPackStageView(sources: [
            .init(region: "a",pack: a,graphSHA256: hash(aBytes),validate: {}),
            .init(region: "b",pack: b,graphSHA256: hash(bBytes),validate: {})],
            boundaries: [.init(first: 0,second: 1,forward: [anchor],reverse: [anchor])],requiredRegions: ["a","b"])
        return (view,a,start,seam,finish)
    }
    @Test func globalBudgetKeepsDearerShortPrefixWhereSerialWinnerCannotFitTail() throws {
        let (view,pack,start,seam,end) = try fixture()
        var context = HopSearchContext.forProfile(.cleanest,seed: 17)
        context.pavedOnly = true
        let result = try ConnectedCleanStage.calculate(view: view,
            origin: .init(pack: 0,node: start,matchedEdge: 0),
            destination: .init(pack: 1,node: end,matchedEdge: 1),
            profile: .cleanest,maxMeters: 207_000,context: context)
        #expect(result.limitation == nil)
        // Reciprocal storage portals cannot generate new road histories forever.
        #expect(result.acceptedLabels < 64)
        #expect(result.meters == 190_000)
        #expect(result.roads.map { $0.road.edge } == [0,3,4,1])
        #expect(result.roads.map { $0.road.pack } == [0,0,0,1])
        #expect(!result.coordinates.isEmpty)
        var serial = try fixtureRouter(pack: pack)
        serial.recordedStartNode = start; serial.recordedEndNode = seam
        func point(_ n: Int) -> CLLocationCoordinate2D {
            .init(latitude: Double(pack.nodeCoords[n*2+1]),longitude: Double(pack.nodeCoords[n*2]))
        }
        guard case .success(let prefix) = serial.routeDetailed(from: point(start),to: point(seam),
            profile: .cleanest,allowUnknown: false,sessionSeed: 17,maxRouteMeters: 207_000) else {
            Issue.record("Native isolated prefix did not complete"); return
        }
        #expect(prefix.distanceMeters + 20_000 > 207_000)
        #expect(result.meters <= 207_000)
    }
    @Test func unsupportedProfileAndResourceCapNeverBecomeNoPath() throws {
        let (view,_,start,_,end) = try fixture()
        var context = HopSearchContext.forProfile(.cleanest,seed: 17); context.pavedOnly = true
        #expect(throws: ConnectedCleanStage.Failure.self) {
            try ConnectedCleanStage.calculate(view: view,origin: .init(pack: 0,node: start,matchedEdge: 0),
                destination: .init(pack: 1,node: end,matchedEdge: 1),profile: .balanced,maxMeters: 207_000,context: context)
        }
        var limits = ConnectedCleanStage.Limits(); limits.maximumLabels = 1
        #expect(throws: (any Error).self) {
            try ConnectedCleanStage.calculate(view: view,origin: .init(pack: 0,node: start,matchedEdge: 0),
                destination: .init(pack: 1,node: end,matchedEdge: 1),profile: .cleanest,maxMeters: 207_000,context: context,limits: limits)
        }
    }
    @Test func unarrivedSeamOriginKeepsLocalRouteAndDisclosesUnsearchedTransfer() throws {
        let (view,_,_,seam,end) = try fixture()
        var context = HopSearchContext.forProfile(.cleanest,seed: 17); context.pavedOnly = true
        let result = try ConnectedCleanStage.calculate(view: view,
            origin: .init(pack: 1,node: seam,matchedEdge: 1),
            destination: .init(pack: 1,node: end,matchedEdge: 1),
            profile: .cleanest,maxMeters: 207_000,context: context)
        #expect(result.roads.map { $0.road.edge } == [1])
        #expect(result.meters == 20_000)
        #expect(result.limitation == "unarrivedOriginTransferUnsupported")
    }
    @Test func sameRecordedNodeReturnsExplicitZeroRoadCoordinate() throws {
        let (view,_,start,_,_) = try fixture()
        var context = HopSearchContext.forProfile(.cleanest,seed: 17); context.pavedOnly = true
        let endpoint = ConnectedCleanStage.Endpoint(pack: 0,node: start,matchedEdge: 0)
        let result = try ConnectedCleanStage.calculate(view: view,origin: endpoint,destination: endpoint,
            profile: .cleanest,maxMeters: 207_000,context: context)
        #expect(result.roads.isEmpty && result.meters == 0 && result.cost == 0)
        #expect(result.coordinates.count == 1)
    }
    @Test func displacedOneEdgeGeometryCannotClaimRecordedDestination() throws {
        let (view,_,_,seam,end) = try fixture()
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety.geometry.v1.bin")
        var geometry = try Data(contentsOf: base)
        // This fixture uses Float32 coordinates. Translate every stored longitude
        // so the single selected edge is internally coherent but misses its pins.
        let count = geometry.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12,as: UInt32.self))) }
        let firstCoordinate = 16 + (6 + 1) * 4
        for i in stride(from: 0,to: count,by: 2) {
            let offset = firstCoordinate + i * 4
            let value = geometry.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset,as: UInt32.self))) }
            var bits = (value + 1).bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &bits) { geometry.replaceSubrange(offset..<offset+4,with: $0) }
        }
        let destinationPack = try view.sourcePack(1)
        destinationPack.geometry = try GeometryV1Pack(data: geometry)
        var context = HopSearchContext.forProfile(.cleanest,seed: 17); context.pavedOnly = true
        #expect(throws: ConnectedCleanStage.Failure.self) {
            try ConnectedCleanStage.calculate(view: view,
                origin: .init(pack: 1,node: seam,matchedEdge: 1),
                destination: .init(pack: 1,node: end,matchedEdge: 1),
                profile: .cleanest,maxMeters: 207_000,context: context)
        }
    }

}
