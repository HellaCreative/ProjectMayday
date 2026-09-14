import Foundation
import CryptoKit
import Testing
@testable import Dirt

struct OriginalIDIndexTests {
    private func bytes() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety.graph.v4.bin"))
    }
    private func identity(_ bytes: Data) -> OriginalIDIndex.Identity {
        .init(graphSHA256: SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined(),graphBytes: bytes.count)
    }
    private func u32(_ bytes: Data,_ at: Int) -> Int {
        bytes.withUnsafeBytes { Int(UInt32.routingDecode($0,at: at)) }
    }
    private func put(_ value: Int64,_ at: Int,_ data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(at..<at+8,with: $0) }
    }
    private func files(_ body: (URL,URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("original-index-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("graph.bin"),dir.appendingPathComponent("ids.bin"))
    }
    @Test func multipleRunsSignedNodeOrderingAndAllDuplicateWays() throws {
        try files { graph,index in
            var data = try bytes()
            let nodes = u32(data,8),edges = u32(data,12),nodeAt = u32(data,104),wayAt = u32(data,108)
            try #require(nodes >= 4 && edges >= 4)
            let extremes: [Int64] = [Int64.max,Int64.min,0,-1]
            let expectedNodes = (0..<nodes).map { $0 < 4 ? extremes[$0] : Int64($0) }
            let expectedWays = (0..<edges).map { $0%2 == 0 ? Int64(77) : Int64(-5) }
            for i in 0..<nodes { put(expectedNodes[i],nodeAt+i*8,&data) }
            for i in 0..<edges { put(expectedWays[i],wayAt+i*8,&data) }
            try data.write(to: graph)
            var limits = OriginalIDIndex.Limits();limits.rowsPerRun = 2
            try OriginalIDIndex.prepare(graphURL: graph,to: index,identity: identity(data),limits: limits)
            let lookup = try OriginalIDIndex(url: index,graphURL: graph,identity: identity(data))
            for i in 0..<nodes { #expect(try lookup.node(expectedNodes[i]) == i) }
            #expect(try lookup.node(999999) == nil)
            for id in [Int64(77),-5,999] {
                var matches: [Int] = []
                try lookup.way(id) { matches.append($0) }
                #expect(matches == expectedWays.indices.filter { expectedWays[$0] == id })
            }
        }
    }
    @Test func ambiguousNodeRejectedRatherThanFirstIndex() throws {
        try files { graph,index in
            var data = try bytes();let nodeAt = u32(data,104)
            put(44,nodeAt,&data);put(44,nodeAt+8,&data);try data.write(to: graph)
            try OriginalIDIndex.prepare(graphURL: graph,to: index,identity: identity(data))
            let lookup = try OriginalIDIndex(url: index,graphURL: graph,identity: identity(data))
            #expect(throws: OriginalIDIndex.Failure.ambiguousNode) { try lookup.node(44) }
        }
    }
    @Test func cancelAndSourceMutationCannotPublishOverPriorIndex() throws {
        try files { graph,index in
            let data = try bytes(),prior = Data("prior-checkpoint".utf8)
            try data.write(to: graph);try prior.write(to: index)
            #expect(throws: (any Error).self) {
                try OriginalIDIndex.prepare(graphURL: graph,to: index,identity: identity(data),cancelled: { true })
            }
            #expect(try Data(contentsOf: index) == prior)
            #expect(throws: (any Error).self) {
                try OriginalIDIndex.prepare(graphURL: graph,to: index,identity: identity(data),beforePublish: {
                    var changed = data;changed[changed.count-1] ^= 1;try changed.write(to: graph)
                })
            }
            #expect(try Data(contentsOf: index) == prior)
        }
    }
    @Test func budgetAndWarmSourceValidationFailClosed() throws {
        try files { graph,index in
            let data = try bytes();try data.write(to: graph)
            var limits = OriginalIDIndex.Limits();limits.maximumWrittenBytes = 1
            #expect(throws: OriginalIDIndex.Failure.preparationLimit) {
                try OriginalIDIndex.prepare(graphURL: graph,to: index,identity: identity(data),limits: limits)
            }
            #expect(!FileManager.default.fileExists(atPath: index.path))
            try OriginalIDIndex.prepare(graphURL: graph,to: index,identity: identity(data))
            let lookup = try OriginalIDIndex(url: index,graphURL: graph,identity: identity(data))
            #expect(throws: (any Error).self) { try lookup.node(0,cancelled: { true }) }
            var changed = data;changed[changed.count-1] ^= 1;try changed.write(to: graph)
            #expect(throws: (any Error).self) { try lookup.node(0) }
        }
    }
}
