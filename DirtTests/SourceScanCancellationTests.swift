import Foundation
import Testing
@testable import Dirt

@Suite("Bounded source-scan cancellation")
struct SourceScanCancellationTests {
    @Test("Source scan checks cancellation within 256 ordinary edges")
    func cancelsDuringScan() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination=dir.appendingPathComponent("index")
        let identity=ExactSnapIndex.Identity(graphSHA256: "fixture",graphBytes: 1,geometrySHA256: "fixture",geometryBytes: 1)
        var processed=0
        #expect(throws: ExactSnapIndex.Failure.cancelled) {
            try ExactSnapIndexBuilder.build(to: destination,identity: identity,edgeCount: 10000,
                cancelled: { processed >= 10 }) { _ in
                    processed += 1
                    return .init(aLon: 0,aLat: 0,bLon: 0,bLat: 0,minLon: 0,maxLon: 0,minLat: 0,maxLat: 0)
                }
        }
        #expect(processed >= 10)
        #expect(processed <= 256)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
