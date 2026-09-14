import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct ConnectedPagedPolicyTests {
    private func fixture() throws -> (Data,Data,Data,GraphV2Pack.CrossPackSeamAnchor,Int,Int) {
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
        return (aBytes,bBytes,geometry,anchor,start,finish)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined() }
    private func prepared(_ bytes: Data, geometry: Data,dir: URL) throws -> (PagedV4Core,OriginalIDIndex,PagedConnectedCleanPolicyBundle) {
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        let graphURL = dir.appendingPathComponent("graph.bin"), geomURL = dir.appendingPathComponent("geometry.bin")
        let indexURL = dir.appendingPathComponent("snap.bin"), idsURL = dir.appendingPathComponent("ids.bin")
        try bytes.write(to: graphURL); try geometry.write(to: geomURL)
        let identity = try ExactSnapIndexPreparation.sourceIdentity(graphURL: graphURL,geometryURL: geomURL)
        _ = try ExactSnapIndexPreparation.prepare(graphURL: graphURL,geometryURL: geomURL,destination: indexURL,identity: identity)
        try OriginalIDIndex.prepare(graphURL: graphURL,to: idsURL,identity: .init(graphSHA256: hash(bytes),graphBytes: bytes.count))
        let ids = try OriginalIDIndex(url: idsURL,graphURL: graphURL,identity: .init(graphSHA256: hash(bytes),graphBytes: bytes.count))
        let core = try PagedV4Core(url: graphURL,identity: .init(sha256: hash(bytes),bytes: bytes.count))
        let details = try PagedEdgeDetail(url: graphURL,identity: .init(sha256: hash(bytes),bytes: bytes.count,edgeCount: core.edgeCount))
        let bundle = try PagedConnectedCleanPolicyBundle(core: core,details: details,metadata: PagedV4PolicyMetadata(core: core),
            geometryURL: geomURL,geometryIdentity: .init(sha256: hash(geometry),bytes: geometry.count),snapIndexURL: indexURL)
        return (core,ids,bundle)
    }
    @Test func connectedPagedPolicyMatchesArrayWinnerAndDoesNotRequestArrayPack() throws {
        let (aBytes,bBytes,geometry,anchor,start,end) = try fixture()
        let a = try GraphV2Pack(data: aBytes), b = try GraphV2Pack(data: bBytes)
        a.geometry = try GeometryV1Pack(data: geometry); b.geometry = try GeometryV1Pack(data: geometry)
        let boundaries: [ConnectedPackStageView.Boundary] = [.init(first: 0,second: 1,forward: [anchor],reverse: [anchor])]
        let reference = try ConnectedPackStageView(sources: [
            .init(region: "a",pack: a,graphSHA256: hash(aBytes),validate: {}),
            .init(region: "b",pack: b,graphSHA256: hash(bBytes),validate: {})],boundaries: boundaries,requiredRegions: ["a","b"])
        var context = HopSearchContext.forProfile(.cleanest,seed: 17); context.pavedOnly = true
        let origin = ConnectedCleanStage.Endpoint(pack: 0,node: start,matchedEdge: 0)
        let destination = ConnectedCleanStage.Endpoint(pack: 1,node: end,matchedEdge: 1)
        let expected = try ConnectedCleanStage.calculate(view: reference,origin: origin,destination: destination,
            profile: .cleanest,maxMeters: 207_000,context: context)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("connected-paged-policy-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ac,ai,ap) = try prepared(aBytes,geometry: geometry,dir: dir.appendingPathComponent("a"))
        let (bc,bi,bp) = try prepared(bBytes,geometry: geometry,dir: dir.appendingPathComponent("b"))
        var escaped: (any ConnectedCleanPolicySource)?
        try ac.withQuery { aq in try ac.withLegalQuery { al in
            try bc.withQuery { bq in try bc.withLegalQuery { bl in
                let view = try ConnectedPackStageView(sources: [
                    .init(region: "a",core: ac,query: aq,legal: al,index: ai),
                    .init(region: "b",core: bc,query: bq,legal: bl,index: bi)],boundaries: boundaries,requiredRegions: ["a","b"])
                #expect(throws: (any Error).self) { try view.sourcePack(0) }
                try ap.withPolicy(query: aq) { pa in try bp.withPolicy(query: bq) { pb in
                    escaped = pa
                    let actual = try ConnectedCleanStage.calculate(view: view,origin: origin,destination: destination,
                        profile: .cleanest,maxMeters: 207_000,context: context,policySources: [pa,pb])
                    #expect(actual.cost.bitPattern == expected.cost.bitPattern)
                    #expect(actual.meters.bitPattern == expected.meters.bitPattern)
                    #expect(actual.meters == 190_000)
                    #expect(actual.roads.map { $0.road.edge } == [0,3,4,1])
                    #expect(actual.roads.map { $0.road.pack } == expected.roads.map { $0.road.pack })
                    #expect(actual.limitation == expected.limitation)
                    #expect(actual.coordinates.map { $0.latitude.bitPattern } == expected.coordinates.map { $0.latitude.bitPattern })
                    #expect(actual.coordinates.map { $0.longitude.bitPattern } == expected.coordinates.map { $0.longitude.bitPattern })
                    #expect(throws: PagedV4Core.Failure.identityMismatch) {
                        try ConnectedCleanStage.calculate(view: view,origin: origin,destination: destination,
                            profile: .cleanest,maxMeters: 207_000,context: context,policySources: [pb,pa])
                    }
                    // The regional access variant must remain closed, independent of legal CSR existence.
                    #expect(try !pa.allowed(edge: 1,fromNode: Int(a.edgeFrom![1]),toNode: Int(a.edgeTo![1]),
                        startEdge: -1,endEdge: -1,from: actual.coordinates[0],to: actual.coordinates.last!,avoid: [],preferences: nil,context: context))
                } }
            } }
        } }
        #expect(throws: (any Error).self) { try #require(escaped).validate() }
    }
    @Test func changedSourceAfterLastReadCannotPublishProvisionalPolicyResult() throws {
        let (bytes,_,geometry,_,start,_) = try fixture()
        for filename in ["geometry.bin","snap.bin","graph.bin"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("connected-policy-mutation-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let (core,_,bundle) = try prepared(bytes,geometry: geometry,dir: dir)
            var readCompleted = false, published = false
            #expect(throws: (any Error).self) {
                _ = try core.withQuery { query in
                    try bundle.withPolicy(query: query) { policy in
                        let shape = try policy.geometry(edge: 0,fromNode: start)
                        #expect(shape.count >= 2)
                        readCompleted = true
                        // Change the same open inode after its final geometry read.
                        // The complete shape remains provisional until all owning
                        // scopes validate; no extra row read may be required.
                        let writer = try FileHandle(forWritingTo: dir.appendingPathComponent(filename))
                        defer { try? writer.close() }
                        try writer.seekToEnd(); try writer.write(contentsOf: Data([0]))
                        try writer.synchronize()
                        return shape
                    }
                }
                published = true
            }
            #expect(readCompleted && !published)
        }
    }

}
