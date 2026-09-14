import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct ConnectedCleanRungsTests {
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

    @Test func unknownServiceRequiresExplicitNativeUnpavedRungAndLimitsStayDistinct() throws {
        var (aBytes,bBytes,geometry,anchor,start,end) = try fixture()
        func offset(_ at: Int) -> Int { aBytes.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:at,as:UInt32.self))) } }
        // This tiny fixture has only unknown/unclassified. Replace its existing
        // class name with a same-byte-length JSON token; padding stays
        // OUTSIDE strings, preserving every binary section offset. The existing
        // service→service tier mapping is already present and stays unchanged.
        let enumRange = offset(56)..<offset(60)
        var enumText = try #require(String(data:aBytes.subdata(in:enumRange),encoding:.utf8))
        let key = try #require(enumText.range(of:"\"roadClassLeafNames\""))
        let endOfNames = try #require(enumText[key.upperBound...].firstIndex(of:"]"))
        let namesRange = key.upperBound..<endOfNames
        let names = String(enumText[namesRange]).replacingOccurrences(of:"\"unclassified\"",with:"\"service\"     ")
        enumText.replaceSubrange(namesRange,with:names)
        let replacement = Data(enumText.utf8)
        try #require(replacement.count == enumRange.count)
        aBytes.replaceSubrange(enumRange,with:replacement)
        let enums = try #require(JSONSerialization.jsonObject(with:aBytes.subdata(in:enumRange)) as? [String:Any])
        let classes = try #require(enums["roadClassLeafNames"] as? [String])
        let service = try #require(classes.firstIndex(of:"service"))
        aBytes[offset(72)+3] = 0; aBytes[offset(76)+3] = UInt8(service)
        let a = try GraphV2Pack(data:aBytes), b = try GraphV2Pack(data:bBytes)
        a.geometry = try GeometryV1Pack(data:geometry); b.geometry = try GeometryV1Pack(data:geometry)
        func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
        let view = try ConnectedPackStageView(sources:[
            .init(region:"a",pack:a,graphSHA256:hash(aBytes),validate:{}),
            .init(region:"b",pack:b,graphSHA256:hash(bBytes),validate:{})],
            boundaries:[.init(first:0,second:1,forward:[anchor],reverse:[anchor])],requiredRegions:["a","b"])
        let origin = ConnectedCleanStage.Endpoint(pack:0,node:start,matchedEdge:0)
        let destination = ConnectedCleanStage.Endpoint(pack:1,node:end,matchedEdge:1)
        var context = HopSearchContext.forProfile(.cleanest,seed:17)
        context.pavedOnly = true;context.cityWall = true;context.settlementFallback = true
        #expect(throws: (any Error).self) {
            do { _ = try ConnectedCleanStage.calculate(view:view,origin:origin,destination:destination,
                profile:.cleanest,maxMeters:207_000,context:context) }
            catch ConnectedCleanStage.Failure.passExhausted { throw ConnectedCleanStage.Failure.passExhausted }
            catch { Issue.record("Strict completed exhaustion misclassified: \(error)"); throw error }
        }
        context.pavedOnly = false
        let relaxed = try ConnectedCleanStage.calculate(view:view,origin:origin,destination:destination,
            profile:.cleanest,maxMeters:207_000,context:context,pass:.unpavedWall)
        #expect(relaxed.roads.map { $0.road.edge } == [0,3,4,1])
        #expect(relaxed.meters == 190_000 && relaxed.limitation == nil)
        #expect(ConnectedCleanStage.CleanPass.unpavedWall.disclosure == ["cleanUnpavedFallback=lastResort"])
        var limits = ConnectedCleanStage.Limits();limits.maximumLabels = 1
        do {
            _ = try ConnectedCleanStage.calculate(view:view,origin:origin,destination:destination,
                profile:.cleanest,maxMeters:207_000,context:context,pass:.unpavedWall,limits:limits)
            Issue.record("Bounded label failure unexpectedly succeeded")
        } catch ConnectedCleanStage.Failure.passExhausted {
            Issue.record("Resource limit cannot authorize advancing fallback")
        } catch ConnectedCleanStage.Failure.resourceLimit {
        } catch ConnectedCostLengthLabels.Failure.resourceLimit {
        } catch { Issue.record("Unexpected failure instead of resource cap: \(error)") }
    }
}
