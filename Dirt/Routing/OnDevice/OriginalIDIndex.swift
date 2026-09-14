import Foundation
import CryptoKit
import Darwin

/// Private exact identity derivative. No topology, access or turn decisions.
/// Uses the existing snap builder's bounded12-byte run/merge representation;
/// its spatial sections are deliberately not reused for original identities.
nonisolated final class OriginalIDIndex {
    struct Identity: Codable, Equatable { let graphSHA256: String; let graphBytes: Int }
    struct Limits {
        var rowsPerRun = 8_192
        var maximumWrittenBytes = 1_024 * 1_024 * 1_024
    }
    enum Failure: Error, Equatable { case invalidFormat, identityMismatch, corrupt, ambiguousNode, preparationLimit }
    private struct Header: Codable {
        let version: Int
        let identity: Identity
        let nodes: Int
        let ways: Int
        let bodySHA256: String
    }
    private struct Row: Comparable {
        let key: UInt64
        let index: UInt32
        static func < (a: Self,b: Self) -> Bool { a.key == b.key ? a.index < b.index : a.key < b.key }
    }
    private static let headerBytes = 4096
    private let graph: RoutingFilePages
    private let index: RoutingFilePages
    private let header: Header
    var verifiedIdentity: Identity { header.identity }
    func validateSource(cancelled: () -> Bool = { false }) throws {
        try graph.validate(cancelled: cancelled);try index.validate(cancelled: cancelled)
    }
    private static func key(_ id: Int64) -> UInt64 { UInt64(bitPattern: id) ^ (1 << 63) }
    private static func append<T: FixedWidthInteger>(_ value: T,to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private static func append(_ row: Row,to data: inout Data) {
        append(row.key,to: &data);append(row.index,to: &data)
    }
    private static func decode(_ bytes: UnsafeRawBufferPointer,at: Int) -> Row {
        .init(key: bytes.loadUnaligned(fromByteOffset: at,as: UInt64.self).littleEndian,
            index: UInt32.routingDecode(bytes,at: at+8))
    }
    init(url: URL,graphURL: URL,identity: Identity,cancelled: () -> Bool = { false }) throws {
        graph = try RoutingFilePages(url: graphURL,limits: ExactSnapIndex.pageLimits)
        index = try RoutingFilePages(url: url,limits: ExactSnapIndex.pageLimits)
        guard graph.fileBytes == identity.graphBytes,
              try ExactSnapIndex.digest(graph,cancelled: cancelled) == identity.graphSHA256 else { throw Failure.identityMismatch }
        let raw = try index.read(at: 0,count: Self.headerBytes,cancelled: cancelled)
        header = try raw.withUnsafeBytes { bytes in
            guard Array(bytes[0..<4]) == [68,79,73,49] else { throw Failure.invalidFormat }
            let count = Int(UInt32.routingDecode(bytes,at: 4))
            guard count > 0,count <= Self.headerBytes-72 else { throw Failure.invalidFormat }
            let json = Data(bytes[72..<72+count])
            let hash = SHA256.hash(data: json).map { String(format: "%02x",$0) }.joined()
            guard hash == String(decoding: bytes[8..<72],as: UTF8.self) else { throw Failure.corrupt }
            return try JSONDecoder().decode(Header.self,from: json)
        }
        guard header.version == 1,header.identity == identity else { throw Failure.identityMismatch }
        guard header.nodes >= 0,header.ways >= 0,
              header.nodes <= (index.fileBytes-Self.headerBytes)/12,
              header.ways == (index.fileBytes-Self.headerBytes)/12-header.nodes,
              (index.fileBytes-Self.headerBytes)%12 == 0,
              try ExactSnapIndex.digest(index,offset: Self.headerBytes,cancelled: cancelled) == header.bodySHA256 else { throw Failure.corrupt }
        try graph.validate(cancelled: cancelled)
    }
    func node(_ id: Int64,cancelled: () -> Bool = { false }) throws -> Int? {
        var found: Int?
        try enumerate(id,first: 0,count: header.nodes,cancelled: cancelled) { index in
            guard found == nil else { throw Failure.ambiguousNode };found = index
        }
        return found
    }
    func way(_ id: Int64,cancelled: () -> Bool = { false },visit: (Int) throws -> Void) throws {
        try enumerate(id,first: header.nodes,count: header.ways,cancelled: cancelled,visit: visit)
    }
    private func enumerate(_ id: Int64,first: Int,count: Int,cancelled: () -> Bool,
        visit: (Int) throws -> Void) throws {
        try graph.validate(cancelled: cancelled);try index.validate(cancelled: cancelled)
        func row(_ at: Int) throws -> Row {
            let bytes = try index.read(at: Self.headerBytes+(first+at)*12,count: 12,cancelled: cancelled)
            return bytes.withUnsafeBytes { Self.decode($0,at: 0) }
        }
        let key = Self.key(id)
        var low = 0,high = count
        while low < high {
            let mid = low+(high-low)/2
            if try row(mid).key < key { low = mid+1 } else { high = mid }
        }
        while low < count {
            let value = try row(low)
            if value.key != key { break }
            guard value.index < count else { throw Failure.corrupt }
            try visit(Int(value.index));low += 1
        }
        try index.validate(cancelled: cancelled);try graph.validate(cancelled: cancelled)
    }
    /// Graph is read as paged scalar columns only. Every source byte is verified
    /// before and after sorting; atomic publication cannot expose partial runs.
    static func prepare(graphURL: URL,to destination: URL,identity: Identity,
        limits: Limits = Limits(),cancelled: () -> Bool = { false },
        beforePublish: () throws -> Void = {}) throws {
        guard limits.rowsPerRun > 0,limits.rowsPerRun <= 8_192,limits.maximumWrittenBytes > 0 else { throw Failure.preparationLimit }
        let source = try RoutingFilePages(url: graphURL,limits: ExactSnapIndex.pageLimits)
        defer { source.close() }
        guard source.fileBytes == identity.graphBytes,
              try ExactSnapIndex.digest(source,cancelled: cancelled) == identity.graphSHA256 else { throw Failure.identityMismatch }
        let bytes = try source.read(at: 0,count: 140,cancelled: cancelled)
        let fields = bytes.withUnsafeBytes { b in (0..<35).map { Int(UInt32.routingDecode(b,at: $0*4)) } }
        guard fields[0] == Int(GraphV2Pack.magicV4),fields[1]&65535 == 4,
              fields[2] >= 0,fields[3] >= 0,fields[26] >= 140,fields[27] >= 140 else { throw Failure.invalidFormat }
        let nodeColumn = try RoutingPagedColumn<Int64>(source: source,byteOffset: fields[26],count: fields[2])
        let wayColumn = try RoutingPagedColumn<Int64>(source: source,byteOffset: fields[27],count: fields[3])
        let fm = FileManager.default
        let scratch = destination.deletingLastPathComponent().appendingPathComponent(".original-ids-"+UUID().uuidString)
        try fm.createDirectory(at: scratch,withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let writer = Writer(limit: limits.maximumWrittenBytes)
        func check() throws { if cancelled() { throw RoutingPageError.cancelled } }
        func sorted(_ name: String,column: RoutingPagedColumn<Int64>,count: Int) throws -> URL {
            func url(_ pass: Int,_ run: Int) -> URL { scratch.appendingPathComponent("\(name)-\(pass)-\(run)") }
            var runs = 0
            for first in stride(from: 0,to: count,by: limits.rowsPerRun) {
                try check()
                let end = min(count,first+limits.rowsPerRun)
                let block = try column.lease(first..<end,cancelled: cancelled)
                var rows: [Row] = [];rows.reserveCapacity(end-first)
                // Bound allocation by configured run capacity, not region size.
                guard rows.capacity <= limits.rowsPerRun*2 else { throw Failure.preparationLimit }
                for i in first..<end { rows.append(.init(key: key(block[i]),index: UInt32(i))) }
                rows.sort();try check()
                let out = try output(url(0,runs));defer { try? out.close() }
                var data = Data();data.reserveCapacity(65_532)
                for row in rows {
                    append(row,to: &data)
                    if data.count >= 65_532 { try check();try writer.write(data,to: out);data.removeAll(keepingCapacity: true) }
                }
                try writer.write(data,to: out);runs += 1
            }
            if runs == 0 { let out = try output(url(0,0));try out.close();return url(0,0) }
            var pass = 0
            while runs > 1 {
                var next = 0
                for first in stride(from: 0,to: runs,by: 2) {
                    try check()
                    let aURL = url(pass,first),target = url(pass+1,next)
                    if first+1 == runs { try fm.moveItem(at: aURL,to: target) }
                    else {
                        let a = try Cursor(aURL),b = try Cursor(url(pass,first+1)),out = try output(target)
                        defer { try? out.close() }
                        var block = Data();block.reserveCapacity(65_532)
                        while a.current != nil || b.current != nil {
                            try check()
                            if let row = a.current,b.current == nil || row < b.current! { append(row,to: &block);try a.advance() }
                            else if let row = b.current { append(row,to: &block);try b.advance() }
                            if block.count >= 65_532 { try writer.write(block,to: out);block.removeAll(keepingCapacity: true) }
                        }
                        try writer.write(block,to: out)
                        try fm.removeItem(at: aURL);try fm.removeItem(at: url(pass,first+1))
                    }
                    next += 1
                }
                pass += 1;runs = next
            }
            return url(pass,0)
        }
        let nodes = try sorted("nodes",column: nodeColumn,count: fields[2])
        let ways = try sorted("ways",column: wayColumn,count: fields[3])
        let candidate = scratch.appendingPathComponent("candidate"),out = try output(candidate)
        defer { try? out.close() }
        try writer.write(Data(count: headerBytes),to: out)
        for file in [nodes,ways] {
            let input = try FileHandle(forReadingFrom: file);defer { try? input.close() }
            while true {
                try check();let block = try input.read(upToCount: 65_536) ?? Data()
                if block.isEmpty { break };try writer.write(block,to: out)
            }
        }
        try out.synchronize();try out.close()
        let pages = try RoutingFilePages(url: candidate,limits: ExactSnapIndex.pageLimits)
        let body = try ExactSnapIndex.digest(pages,offset: headerBytes,cancelled: cancelled);pages.close()
        let json = try JSONEncoder().encode(Header(version: 1,identity: identity,nodes: fields[2],ways: fields[3],bodySHA256: body))
        guard json.count <= headerBytes-72 else { throw Failure.invalidFormat }
        var header = Data([68,79,73,49]);append(UInt32(json.count),to: &header)
        header.append(contentsOf: SHA256.hash(data: json).map { String(format: "%02x",$0) }.joined().utf8)
        header.append(json);header.append(Data(count: headerBytes-header.count))
        let update = try FileHandle(forWritingTo: candidate);defer { try? update.close() }
        try writer.write(header,to: update);try update.synchronize();try update.close()
        try beforePublish();try check()
        guard try ExactSnapIndex.digest(source,cancelled: cancelled) == identity.graphSHA256 else { throw Failure.identityMismatch }
        try source.validate(cancelled: cancelled);try check()
        let result = candidate.withUnsafeFileSystemRepresentation { src in destination.withUnsafeFileSystemRepresentation { dst in rename(src!,dst!) } }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private static func output(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path,contents: nil) else { throw Failure.preparationLimit }
        return try FileHandle(forWritingTo: url)
    }
    private final class Writer {
        let limit: Int
        var written = 0
        init(limit: Int) { self.limit = limit }
        func write(_ data: Data,to out: FileHandle) throws {
            guard data.count <= limit-written else { throw Failure.preparationLimit }
            try out.write(contentsOf: data);written += data.count
        }
    }
    private final class Cursor {
        let file: FileHandle
        var data = Data(),at = 0
        var current: Row?
        init(_ url: URL) throws { file = try FileHandle(forReadingFrom: url);try advance() }
        deinit { try? file.close() }
        func advance() throws {
            if at == data.count {
                data = Data();at = 0
                while data.count < 65_532 {
                    let next = try file.read(upToCount: 65_532-data.count) ?? Data()
                    if next.isEmpty { break };data.append(next)
                }
                guard data.count%12 == 0 else { throw Failure.corrupt }
                if data.isEmpty { current = nil;return }
            }
            current = data.withUnsafeBytes { OriginalIDIndex.decode($0,at: at) };at += 12
        }
    }
}
