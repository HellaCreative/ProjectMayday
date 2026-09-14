import Foundation
import CryptoKit
import Testing
@testable import Dirt

@Suite("Geometry cached-page borrowing")
struct GeometryBorrowTests {
    @Test("Both scalar formats preserve pairs straddling physical pages without copying whole windows",arguments: [false,true])
    func physicalBoundaries(doubles: Bool) throws {
        let offsets=doubles ? [0,20004] : [0,20000,20004]
        let edges=offsets.count-1,width=doubles ? 8:4
        var coordsAt=16+offsets.count*4
        if doubles,coordsAt%8 != 0 { coordsAt += 8-coordsAt%8 }
        var bytes=Data(count: coordsAt+offsets.last!*width)
        func put<T: FixedWidthInteger>(_ value: T,_ at: Int) {
            var le=value.littleEndian
            withUnsafeBytes(of: &le) { bytes.replaceSubrange(at..<(at+$0.count),with: $0) }
        }
        put(GeometryV1Pack.magic,0);put(UInt16(1),4);put(UInt16(doubles ? 1:0),6)
        put(UInt32(edges),8);put(UInt32(offsets.last!),12)
        for (i,v) in offsets.enumerated() { put(Int32(v),16+i*4) }
        for scalar in 0..<offsets.last! {
            let value=Double(scalar%997)/10000
            if doubles { put(value.bitPattern,coordsAt+scalar*width) }
            else { put(Float(value).bitPattern,coordsAt+scalar*width) }
        }
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url);defer { try? FileManager.default.removeItem(at: url) }
        let memory=try GeometryV1Pack(data: bytes)
        let file=try GeometryV1Pack(url: url,identity: .init(sha256: SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined(),bytes: bytes.count),expectedEdgeCount: edges)
        let measurement=RoutingMeasurement(metadata: ["fixture":"geometry-page-borrow"])
        try RoutingWorkContext.$measurement.withValue(measurement) {
            for edge in 0..<edges {
                let expected=try memory.polyline(edgeIndex: edge)
                let actual=try file.polyline(edgeIndex: edge)
                #expect(actual.map(\.latitude) == expected.map(\.latitude))
                #expect(actual.map(\.longitude) == expected.map(\.longitude))
                let reverse=try file.polyline(edgeIndex: edge,forward: false)
                #expect(reverse.map(\.latitude) == expected.reversed().map(\.latitude))
            }
        }
        let report=measurement.finish(outcome: "complete")
        #expect((report.counters["fileBytesAccessed"] ?? 0) <= 256)
        #expect((report.counters["filePageBorrowAcquisitions"] ?? 0) > 0)
        let stats=try #require(file.pageStatistics)
        #expect(stats.borrowedPageCount <= 2)
        #expect(stats.peakLivePayloadBytes <= stats.maximumLivePayloadBytes)
    }
}
