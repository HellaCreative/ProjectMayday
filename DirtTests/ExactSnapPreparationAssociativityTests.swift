import Foundation
import Testing
@testable import Dirt

@Suite("Raw snap preparation endpoint cache")
struct ExactSnapPreparationAssociativityTests {
    @Test("Repeated equal-parity endpoint blocks retain exact bytes without reloading", arguments: [false,true])
    func exactBody(doubles: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func put<T: FixedWidthInteger>(_ value: T,_ offset: Int,_ bytes: inout Data) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { bytes.replaceSubrange(offset..<(offset+$0.count),with: $0) }
        }
        let nodes = 33000,edges = 3,coordinateOffset = 164
        var graph = Data(count: coordinateOffset+nodes*8)
        put(GraphV2Pack.magicV4,0,&graph);put(UInt16(4),4,&graph);put(UInt16(9),6,&graph)
        put(UInt32(nodes),8,&graph);put(UInt32(edges),12,&graph);put(UInt32(6),16,&graph)
        put(UInt32(140),20,&graph);put(UInt32(coordinateOffset),44,&graph)
        put(UInt32(140),64,&graph);put(UInt32(152),68,&graph)
        let starts = [0,0,0]
        let ends = [16384,16384,16384]
        for edge in 0..<edges {
            put(Int32(starts[edge]),140+4*edge,&graph);put(Int32(ends[edge]),152+4*edge,&graph)
            for node in [starts[edge],ends[edge]] {
                put(Float(0.01).bitPattern,coordinateOffset+node*8,&graph)
                put(Float(0.01).bitPattern,coordinateOffset+node*8+4,&graph)
            }
        }
        let perEdge = 20000,width = doubles ? 8:4,geometryCoordinates = 32
        var geometry = Data(count: geometryCoordinates+edges*perEdge*width)
        put(GeometryV1Pack.magic,0,&geometry);put(UInt16(1),4,&geometry);put(UInt16(doubles ? 1:0),6,&geometry)
        put(UInt32(edges),8,&geometry);put(UInt32(edges*perEdge),12,&geometry)
        for i in 0...edges { put(Int32(i*perEdge),16+4*i,&geometry) }
        for i in 0..<(edges*perEdge) {
            if doubles { put(Double(0.02).bitPattern,geometryCoordinates+i*width,&geometry) }
            else { put(Float(0.02).bitPattern,geometryCoordinates+i*width,&geometry) }
        }
        let graphURL=dir.appendingPathComponent("graph"),geometryURL=dir.appendingPathComponent("geometry")
        try graph.write(to: graphURL);try geometry.write(to: geometryURL)
        let identity=try ExactSnapIndexPreparation.sourceIdentity(graphURL: graphURL,geometryURL: geometryURL)
        let actualURL=dir.appendingPathComponent("actual"),expectedURL=dir.appendingPathComponent("expected")
        let measurement = RoutingMeasurement(metadata: ["fixture": "bounded-source-scan"])
        _ = try RoutingWorkContext.$measurement.withValue(measurement) {
            try ExactSnapIndexPreparation.prepare(graphURL: graphURL,geometryURL: geometryURL,destination: actualURL,identity: identity)
        }
        let report = measurement.finish(outcome: "complete")
        #expect(report.counters["indexSourceScalars"] == 60012)
        #expect(report.counters["indexSourceBlockLoads"] == (doubles ? 10 : 6))
        #expect((report.counters["indexSourceBufferBorrows"] ?? .max) <= 80)
        #expect((report.counters["indexScanCancellationChecks"] ?? .max) <= 100)
        let low=Double(Float(0.01)),high=doubles ? 0.02:Double(Float(0.02))
        try ExactSnapIndexBuilder.build(to: expectedURL,identity: identity,edgeCount: edges) { _ in
            .init(aLon: low,aLat: low,bLon: low,bLat: low,minLon: low,maxLon: high,minLat: low,maxLat: high)
        }
        // Header JSON key order is irrelevant; every directory, bounds and
        // membership byte must equal the independent direct-provider fixture.
        let actual=try Data(contentsOf: actualURL).dropFirst(ExactSnapIndex.headerBytes)
        let expected=try Data(contentsOf: expectedURL).dropFirst(ExactSnapIndex.headerBytes)
        #expect(actual == expected)
    }
}
