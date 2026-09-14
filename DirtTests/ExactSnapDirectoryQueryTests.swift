import Foundation
import Testing
@testable import Dirt

@Suite("Bounded snap directory queries")
struct ExactSnapDirectoryQueryTests {
    @Test("Directory row boundaries preserve candidate order and reuse two leases")
    func boundaryAndReuse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = ExactSnapIndex.Identity(graphSHA256: "directory-fixture",graphBytes: 1,
            geometrySHA256: "geometry-fixture",geometryBytes: 1)
        let url = directory.appendingPathComponent("index")
        try ExactSnapIndexBuilder.build(to: url,identity: identity,edgeCount: 5400) { edge in
            let x = Double(edge / 60)*0.05+0.01, y = Double(edge % 60)*0.05+0.01
            return .init(aLon: x,aLat: y,bLon: x,bLat: y,
                minLon: x,maxLon: x,minLat: y,maxLat: y)
        }
        let index = try ExactSnapIndex(url: url,identity: identity)
        var expected: [Int] = []
        for radius in 0...2 {
            try index.forEachEdge(nearLat: 1.51,lon: 2.26,radiusCells: radius) { expected.append($0) }
        }
        var escaped: ExactSnapIndex.BoundsQuery?
        try index.withBoundsQuery { query in
            escaped = query
            for _ in 0..<10 {
                var actual: [Int] = []
                for radius in 0...2 {
                    try index.forEachEdge(nearLat: 1.51,lon: 2.26,radiusCells: radius,query: query) { edge in
                        actual.append(edge)
                        _ = try query.mayIntersect(edge: edge,latitude: 1.51,longitude: 2.26,meters: 550)
                    }
                }
                #expect(actual == expected)
            }
            #expect(query.directoryBlockLoads == 2)
            #expect(index.statistics.leaseCount <= 6)
            #expect(index.statistics.peakLivePayloadBytes <= index.statistics.maximumLivePayloadBytes)
        }
        #expect(index.statistics.leaseCount == 0)
        #expect(throws: RoutingPageError.closed) {
            try index.forEachEdge(nearLat: 1.51,lon: 2.26,radiusCells: 0,query: escaped) { _ in }
        }
        let another = try ExactSnapIndex(url: url,identity: identity)
        #expect(throws: ExactSnapIndex.Failure.identityMismatch) {
            try index.withBoundsQuery { query in
                try another.forEachEdge(nearLat: 1.51,lon: 2.26,radiusCells: 0,query: query) { _ in }
            }
        }
    }
}
