import Foundation
import Testing
@testable import Dirt

struct ExactSnapIndexHintSamplingTests {
    private func fixture() throws -> (ExactSnapIndex,URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hint-sample-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let identity = ExactSnapIndex.Identity(graphSHA256: "fixture",graphBytes: 1,geometrySHA256: "fixture",geometryBytes: 1)
        let file = directory.appendingPathComponent("index")
        try ExactSnapIndexBuilder.build(to: file,identity: identity,edgeCount: 1_000) { id in
            // All share one coarse cell; only the late-ID road is within 550m.
            let coordinate = id == 999 ? 0.01 : 0.045
            return .init(aLon: coordinate,aLat: coordinate,bLon: coordinate+0.0001,bLat: coordinate,
                minLon: coordinate,maxLon: coordinate+0.0001,minLat: coordinate,maxLat: coordinate)
        }
        return (try ExactSnapIndex(url: file,identity: identity),directory)
    }
    @Test func spatialStrataFindLateRelevantRoadWithoutScanningDistantLowIDs() throws {
        let (index,directory) = try fixture();defer { try? FileManager.default.removeItem(at: directory) }
        var first: [Int] = [],second: [Int] = []
        let visits = try index.sampleHintEdges(latitude: 0.01,longitude: 0.01,meters: 550) { first.append($0) }
        try index.sampleHintEdges(latitude: 0.01,longitude: 0.01,meters: 550) { second.append($0) }
        #expect(visits == 64)
        #expect(first == [999])
        #expect(first == second)
        let unknown = try index.sampleHintEdges(latitude: 80,longitude: 100,meters: 550) { _ in Issue.record("Unexpected spatial record") }
        #expect(unknown == 0) // Ordering unknown; no station eligibility result is emitted.
    }
    @Test func sampleAllocationIsProportionalAcrossIntersectingCells() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hint-strata-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = ExactSnapIndex.Identity(graphSHA256: "fixture",graphBytes: 1,geometrySHA256: "fixture",geometryBytes: 1)
        let file = directory.appendingPathComponent("index")
        try ExactSnapIndexBuilder.build(to: file,identity: identity,edgeCount: 16) { id in
            let x = id < 4 ? 0.049 : 0.051
            return .init(aLon: x,aLat: 0.01,bLon: x+0.0001,bLat: 0.01,
                minLon: x,maxLon: x+0.0001,minLat: 0.01,maxLat: 0.01)
        }
        let index = try ExactSnapIndex(url: file,identity: identity)
        var sampled: [Int] = []
        let visited = try index.sampleHintEdges(latitude: 0.01,longitude: 0.05,meters: 550,maximumRecords: 8) { sampled.append($0) }
        #expect(visited == 8)
        #expect(sampled == [0,2,4,6,8,10,12,15])
        #expect(sampled.filter { $0 < 4 }.count == 2)
    }
    @Test func cancellationAndSourceMutationCannotPublishSamples() throws {
        let (index,directory) = try fixture();defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) {
            try index.sampleHintEdges(latitude: 0.01,longitude: 0.01,meters: 550,cancelled: { true }) { _ in }
        }
        #expect(throws: (any Error).self) {
            try index.sampleHintEdges(latitude: 0.01,longitude: 0.01,meters: 550) { _ in
                let writer = try FileHandle(forWritingTo: directory.appendingPathComponent("index"))
                try writer.truncate(atOffset: 1);try writer.close()
            }
        }
    }
}
