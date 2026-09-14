import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct ExactSnapEnvelopeTests {
    private let identity = ExactSnapIndex.Identity(graphSHA256: "graph", graphBytes: 1,
        geometrySHA256: "geometry", geometryBytes: 2)
    private func build(_ row: ExactSnapIndexBuilder.Edge?, count: Int = 1) throws -> (URL, ExactSnapIndex) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("index")
        do {
            try ExactSnapIndexBuilder.build(to: url, identity: identity, edgeCount: count) { _ in row }
            return (dir, try ExactSnapIndex(url: url, identity: identity))
        } catch { try? FileManager.default.removeItem(at: dir); throw error }
    }
    @Test func aggregateIncludesWholeGeometryRatherThanOnlyEndpoints() throws {
        let (dir,index) = try build(.init(aLon: 0, aLat: 0, bLon: 0.01, bLat: 0.01,
            minLon: -1, maxLon: 1, minLat: -2, maxLat: 2))
        defer { try? FileManager.default.removeItem(at: dir) }
        try index.withBoundsQuery { query in
            let intersects21 = try query.mayContainMatch(latitude: 1.9, longitude: 0.9, meters: 0)
            #expect(intersects21)
            let intersects22 = try !query.mayContainMatch(latitude: 40, longitude: -65, meters: 550)
            #expect(intersects22)
            for point in [(2.0,1.0),(2.001,1.0),(2.01,1.0),(0.0,1.01)] {
                for radius in [0.0,550,12_000] {
                    let individual = try query.mayIntersect(edge: 0,
                        latitude: point.0, longitude: point.1, meters: radius)
                    let aggregate = try query.mayContainMatch(latitude: point.0,
                        longitude: point.1, meters: radius)
                    #expect(individual == aggregate)
                }
            }
        }
    }
    @Test func unknownRowsDisablePruningAndPolarDatelinePaddingRemainsConservative() throws {
        let (dir,unknown) = try build(nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        try unknown.withBoundsQuery { query in
            let intersects38 = try query.mayContainMatch(latitude: 40, longitude: -65, meters: 550)
            #expect(intersects38)
        }
        let (polarDir,wide) = try build(.init(aLon: 0, aLat: 89, bLon: 0.01, bLat: 89,
            minLon: -179, maxLon: 179, minLat: 88, maxLat: 90))
        defer { try? FileManager.default.removeItem(at: polarDir) }
        try wide.withBoundsQuery { query in
            for longitude in [-180.0,-179,0,179,180] {
                let intersects45 = try query.mayContainMatch(latitude: 89, longitude: longitude, meters: 550)
                #expect(intersects45)
            }
        }
    }
    @Test func boundsSummaryCrossesBulkHashBlocksWithoutAdditionalRowReads() throws {
        let (dir,index) = try build(.init(aLon: 0, aLat: 0, bLon: 0.001, bLat: 0.001,
            minLon: -1, maxLon: 1, minLat: -1, maxLat: 1), count: 2_000)
        defer { try? FileManager.default.removeItem(at: dir) }
        try index.withBoundsQuery { query in
            let intersects54 = try query.mayContainMatch(latitude: 0, longitude: 0, meters: 550)
            #expect(intersects54)
            let intersects55 = try !query.mayContainMatch(latitude: 45, longitude: -63, meters: 12_000)
            #expect(intersects55)
        }
        #expect(index.statistics.leaseCount == 0)
        #expect(index.statistics.peakLivePayloadBytes <= index.statistics.maximumLivePayloadBytes)
    }
    @Test func earlyRejectionStillRequiresCurrentSourceAndCancellationValidation() throws {
        let (dir,index) = try build(.init(aLon: 0, aLat: 0, bLon: 0.01, bLat: 0.01,
            minLon: 0, maxLon: 0.01, minLat: 0, maxLat: 0.01))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            try index.withBoundsQuery(cancelled: { true }) {
                _ = try $0.mayContainMatch(latitude: 45, longitude: -63, meters: 550)
            }
        }
        #expect(throws: (any Error).self) {
            try index.withBoundsQuery { query in
                let intersects71 = try !query.mayContainMatch(latitude: 45, longitude: -63, meters: 550)
                #expect(intersects71)
                let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("index"))
                try handle.truncate(atOffset: 0); try handle.close()
            }
        }
    }
}
