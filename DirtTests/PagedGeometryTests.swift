import Foundation
import Testing
@testable import Dirt

@Suite("Demand-loaded geometry")
struct PagedGeometryTests {
    private func fixture(doubles: Bool) -> Data {
        let offsets = [0,4,20_000,20_004],width = doubles ? 8:4
        var bytes = Data(count: 32+offsets.last!*width)
        func put<T: FixedWidthInteger>(_ value: T,_ offset: Int) {
            var value=value.littleEndian
            withUnsafeBytes(of: &value) { bytes.replaceSubrange(offset..<(offset+$0.count),with: $0) }
        }
        put(GeometryV1Pack.magic,0);put(UInt16(1),4);put(UInt16(doubles ? 1:0),6)
        put(UInt32(3),8);put(UInt32(offsets.last!),12)
        for (i,value) in offsets.enumerated() { put(Int32(value),16+i*4) }
        for i in 0..<offsets.last! {
            let value=Double(i%101)/10000
            if doubles { put(value.bitPattern,32+i*width) }
            else { put(Float(value).bitPattern,32+i*width) }
        }
        return bytes
    }
    private func withFile(_ bytes: Data,_ body: (URL,GeometryV1Pack.Identity) throws -> Void) throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url);defer { try? FileManager.default.removeItem(at: url) }
        let pages=try RoutingFilePages(url: url,limits: ExactSnapIndex.pageLimits)
        let identity=try GeometryV1Pack.Identity(sha256: ExactSnapIndex.digest(pages,cancelled: { false }),bytes: bytes.count)
        pages.close();try body(url,identity)
    }
    @Test("File and fixture adapters preserve all coordinates and direction",arguments: [false,true])
    func exactGeometry(doubles: Bool) throws {
        let bytes=fixture(doubles: doubles),memory=try GeometryV1Pack(data: bytes)
        try withFile(bytes) { url,identity in
            let file=try GeometryV1Pack(url: url,identity: identity,expectedEdgeCount: 3)
            for edge in [0,1,2,0] {
                for forward in [true,false] {
                    let a=try memory.polyline(edgeIndex: edge,forward: forward)
                    let b=try file.polyline(edgeIndex: edge,forward: forward)
                    #expect(a.map(\.latitude) == b.map(\.latitude))
                    #expect(a.map(\.longitude) == b.map(\.longitude))
                }
            }
            let stats=try #require(file.pageStatistics)
            #expect(stats.leasedPayloadBytes <= 131_072)
            #expect(stats.peakLivePayloadBytes <= stats.maximumLivePayloadBytes)
        }
    }
    @Test("Repeated edge extraction does not allocate another file range")
    func warmRead() throws {
        try withFile(fixture(doubles: true)) { url,identity in
            let file=try GeometryV1Pack(url: url,identity: identity,expectedEdgeCount: 3)
            _ = try file.polyline(edgeIndex: 0)
            let before=try #require(file.pageStatistics)
            _ = try file.polyline(edgeIndex: 0)
            let after=try #require(file.pageStatistics)
            #expect(after.cacheHits == before.cacheHits)
            #expect(after.cacheMisses == before.cacheMisses)
            #expect(after.leasedPayloadBytes == before.leasedPayloadBytes)
        }
    }
    @Test("Cancellation, changed file and incorrect identity never return empty geometry")
    func failures() throws {
        try withFile(fixture(doubles: true)) { url,identity in
            let file=try GeometryV1Pack(url: url,identity: identity,expectedEdgeCount: 3)
            #expect(throws: RoutingPageError.cancelled) { _ = try file.polyline(edgeIndex: 0,cancelled: { true }) }
            #expect(throws: GeometryV1Pack.PackError.invalidEdge) { _ = try file.polyline(edgeIndex: -1) }
            #expect(throws: GeometryV1Pack.PackError.identityMismatch) {
                _ = try GeometryV1Pack(url: url,identity: identity,expectedEdgeCount: 4)
            }
            _ = try file.polyline(edgeIndex: 0)
            let writer=try FileHandle(forWritingTo: url);try writer.truncate(atOffset: 1);try writer.close()
            #expect(throws: (any Error).self) { _ = try file.polyline(edgeIndex: 0) }
        }
    }
    @Test("Output limit reports resource exhaustion without shortening an edge")
    func outputLimit() throws {
        var limits=GeometryV1Pack.Limits();limits.maximumPolylinePoints=3
        let memory=try GeometryV1Pack(data: fixture(doubles: false),limits: limits)
        #expect(try memory.polyline(edgeIndex: 0).count == 2)
        #expect(throws: GeometryV1Pack.PackError.geometryMemoryLimit) { _ = try memory.polyline(edgeIndex: 1) }
    }
}
