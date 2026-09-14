import Foundation
import Testing
@testable import Dirt

@Suite("Exact private snap index")
struct ExactSnapIndexTests {
    private var identity: ExactSnapIndex.Identity { .init(graphSHA256: "fixture-graph", graphBytes: 1, geometrySHA256: "fixture-geometry", geometryBytes: 2) }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func row(_ id: Int) -> ExactSnapIndexBuilder.Edge? {
        if id == 9 { return nil }
        let x = Double(id%4-2)*0.05 + 0.01, y = Double(id%3-1)*0.05 + 0.01
        return .init(aLon: x,aLat: y,bLon: x+0.07,bLat: y+0.02,
            minLon: x-0.02,maxLon: x+0.09,minLat: y-0.01,maxLat: y+0.03)
    }
    @Test("External merge preserves exact rings, duplicates and ascending bucket order")
    func orderAndBounds() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index")
        var limits = ExactSnapIndexBuilder.Limits(); limits.maximumPairsInMemory = 3
        try ExactSnapIndexBuilder.build(to: url, identity: identity, edgeCount: 25, limits: limits, edge: row)
        let index = try ExactSnapIndex(url: url, identity: identity)
        for radius in 0...3 {
            var actual: [Int] = []
            try index.forEachEdge(nearLat: 0.01, lon: 0.01, radiusCells: radius) { actual.append($0) }
            var expected: [Int] = []
            for x in (-radius)...radius { for y in (-radius)...radius {
                if radius > 0, x > -radius, x < radius, y > -radius, y < radius { continue }
                for id in 0..<25 {
                    guard let edge = row(id) else { continue }
                    let x0 = Int(floor(min(edge.aLon,edge.bLon)/0.05)), x1 = Int(floor(max(edge.aLon,edge.bLon)/0.05))
                    let y0 = Int(floor(min(edge.aLat,edge.bLat)/0.05)), y1 = Int(floor(max(edge.aLat,edge.bLat)/0.05))
                    if x >= x0, x <= x1, y >= y0, y <= y1 { expected.append(id) }
                }
            } }
            #expect(actual == expected)
        }
        #expect(try index.mayIntersect(edge: 9, latitude: 80, longitude: 100, meters: 0))
        #expect(try !index.mayIntersect(edge: 0, latitude: 80, longitude: 100, meters: 0))
        #expect(index.statistics.peakLivePayloadBytes <= index.statistics.maximumLivePayloadBytes)
    }
    @Test("Identity mismatch, body corruption and truncation throw rather than empty candidates")
    func badData() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index")
        try ExactSnapIndexBuilder.build(to: url, identity: identity, edgeCount: 25, edge: row)
        let different = ExactSnapIndex.Identity(graphSHA256: "other",graphBytes: 1,geometrySHA256: "fixture-geometry",geometryBytes: 2)
        #expect(throws: (any Error).self) { _ = try ExactSnapIndex(url: url, identity: different) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(ExactSnapIndex.headerBytes+10)); try handle.write(contentsOf: Data([255])); try handle.close()
        #expect(throws: (any Error).self) { _ = try ExactSnapIndex(url: url, identity: identity) }
        let truncate = try FileHandle(forWritingTo: url); try truncate.truncate(atOffset: 100); try truncate.close()
        #expect(throws: (any Error).self) { _ = try ExactSnapIndex(url: url, identity: identity) }
    }
    @Test("Cancelled or capped preparation preserves existing completed derivative")
    func failureKeepsPriorFile() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index"), old = Data("existing".utf8)
        try old.write(to: url)
        #expect(throws: (any Error).self) {
            try ExactSnapIndexBuilder.build(to: url, identity: identity, edgeCount: 25, cancelled: { true }, edge: row)
        }
        var limits = ExactSnapIndexBuilder.Limits(); limits.maximumWrittenBytes = 20
        #expect(throws: (any Error).self) {
            try ExactSnapIndexBuilder.build(to: url, identity: identity, edgeCount: 25, limits: limits, edge: row)
        }
        #expect(try Data(contentsOf: url) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["index"])
    }
    @Test("Read cancellation and source mutation propagate from a previously opened index")
    func runtimeFailure() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index")
        try ExactSnapIndexBuilder.build(to: url, identity: identity, edgeCount: 25, edge: row)
        let index = try ExactSnapIndex(url: url, identity: identity)
        #expect(throws: (any Error).self) { try index.forEachEdge(nearLat: 0,lon: 0,radiusCells: 1,cancelled: { true }) { _ in } }
        #expect(index.isReusable)
        let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: 1); try handle.close()
        #expect(throws: (any Error).self) { try index.forEachEdge(nearLat: 0,lon: 0,radiusCells: 1) { _ in } }
        #expect(!index.isReusable)
    }
    @Test("Source verification failure cannot publish a derivative")
    func prepublicationFailure() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index")
        #expect(throws: (any Error).self) {
            try ExactSnapIndexBuilder.build(to: url, identity: identity, edgeCount: 2, beforePublish: { throw ExactSnapIndex.Failure.identityMismatch }, edge: row)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test("Raw immutable source preparation and reuse preserve identical index bytes")
    func sourcePreparationAndReuse() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int, into bytes: inout Data) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { bytes.replaceSubrange(offset..<(offset+$0.count), with: $0) }
        }
        // Minimal column fixture: preparation never constructs GraphV2Pack or
        // any full-region index. Full routing legality remains tested separately.
        var graph = Data(count: 164)
        put(GraphV2Pack.magicV4,at: 0,into: &graph); put(UInt16(4),at: 4,into: &graph)
        put(UInt16(9),at: 6,into: &graph); put(UInt32(2),at: 8,into: &graph)
        put(UInt32(1),at: 12,into: &graph); put(UInt32(2),at: 16,into: &graph)
        put(UInt32(140),at: 20,into: &graph); put(UInt32(148),at: 44,into: &graph)
        put(UInt32(140),at: 64,into: &graph); put(UInt32(144),at: 68,into: &graph)
        put(Int32(0),at: 140,into: &graph); put(Int32(1),at: 144,into: &graph)
        for (i,value) in [Float(0.01),0.01,0.09,0.01].enumerated() { put(value.bitPattern,at: 148+i*4,into: &graph) }
        var geometry = Data(count: 56)
        put(GeometryV1Pack.magic,at: 0,into: &geometry); put(UInt16(1),at: 4,into: &geometry)
        put(UInt16(1),at: 6,into: &geometry); put(UInt32(1),at: 8,into: &geometry)
        put(UInt32(4),at: 12,into: &geometry); put(Int32(0),at: 16,into: &geometry); put(Int32(4),at: 20,into: &geometry)
        for (i,value) in [0.01,0.01,0.09,0.01].enumerated() { put(value.bitPattern,at: 24+i*8,into: &geometry) }
        let graphURL = dir.appendingPathComponent("graph"), geometryURL = dir.appendingPathComponent("geometry"), indexURL = dir.appendingPathComponent("index")
        try graph.write(to: graphURL); try geometry.write(to: geometryURL)
        let sourceID = try ExactSnapIndexPreparation.sourceIdentity(graphURL: graphURL,geometryURL: geometryURL)
        let index = try ExactSnapIndexPreparation.prepare(graphURL: graphURL,geometryURL: geometryURL,destination: indexURL,identity: sourceID)
        var candidates: [Int] = []
        try index.forEachEdge(nearLat: 0.01,lon: 0.01,radiusCells: 0) { candidates.append($0) }
        #expect(candidates == [0])
        let before = try Data(contentsOf: indexURL)
        _ = try ExactSnapIndexPreparation.prepare(graphURL: graphURL,geometryURL: geometryURL,destination: indexURL,identity: sourceID)
        #expect(try Data(contentsOf: indexURL) == before)
        // Source identity changed while the old private index remains: no reuse.
        graph[150] ^= 1; try graph.write(to: graphURL)
        #expect(throws: ExactSnapIndex.Failure.identityMismatch) {
            _ = try ExactSnapIndexPreparation.prepare(graphURL: graphURL,geometryURL: geometryURL,destination: indexURL,identity: sourceID)
        }
    }

}
