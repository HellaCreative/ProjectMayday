import Foundation
import Testing
@testable import Dirt

@Suite("Snap row cached-page borrowing")
struct SnapRowBorrowTests {
    @Test("Physical bounds/directory page crossings preserve exact rows and candidate order")
    func rowBoundaries() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url=dir.appendingPathComponent("index")
        let identity=ExactSnapIndex.Identity(graphSHA256: "snap-row-fixture",graphBytes: 1,geometrySHA256: "geom",geometryBytes: 1)
        try ExactSnapIndexBuilder.build(to: url,identity: identity,edgeCount: 5400) { edge in
            let x=Double(edge/60)*0.05+0.01,y=Double(edge%60)*0.05+0.01
            return .init(aLon: x,aLat: y,bLon: x,bLat: y,minLon: x,maxLon: x,minLat: y,maxLat: y)
        }
        let index=try ExactSnapIndex(url: url,identity: identity)
        let edgeIDs=[1535,1536,3174,4812]
        let expected=try edgeIDs.map { edge in
            try index.mayIntersect(edge: edge,latitude: Double(edge%60)*0.05+0.01,longitude: Double(edge/60)*0.05+0.01,meters: 1)
        }
        var expectedCandidates: [Int]=[]
        for ring in 0...2 { try index.forEachEdge(nearLat: 1.51,lon: 2.26,radiusCells: ring) { expectedCandidates.append($0) } }
        let measurement=RoutingMeasurement(metadata: ["fixture":"snap-row-borrow"])
        try RoutingWorkContext.$measurement.withValue(measurement) {
            try index.withBoundsQuery { query in
                for (i,edge) in edgeIDs.enumerated() {
                    #expect(try query.mayIntersect(edge: edge,latitude: Double(edge%60)*0.05+0.01,longitude: Double(edge/60)*0.05+0.01,meters: 1) == expected[i])
                }
                var actual: [Int]=[]
                for ring in 0...2 { try index.forEachEdge(nearLat: 1.51,lon: 2.26,radiusCells: ring,query: query) { actual.append($0) } }
                #expect(actual == expectedCandidates)
            }
        }
        let report=measurement.finish(outcome: "complete")
        #expect((report.counters["fileBytesAccessed"] ?? 0) < 4096)
        #expect((report.counters["filePageBorrowAcquisitions"] ?? 0) > 0)
        #expect(index.statistics.borrowedPageCount == 0)
        #expect(index.statistics.leaseCount == 0)
        #expect(index.statistics.peakLivePayloadBytes <= index.statistics.maximumLivePayloadBytes)
    }
}
