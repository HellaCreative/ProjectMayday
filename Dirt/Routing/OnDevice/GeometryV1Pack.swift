import CoreLocation
import Foundation

/// geometry.v1 source with a small fixture adapter and bounded production file
/// pages. File-backed instances retain neither a whole-file Data nor an offset
/// array. Returned route geometry is caller-owned and measured separately.
nonisolated final class GeometryV1Pack: @unchecked Sendable {
    static let magic: UInt32 = 0x4D4F_4547
    struct Identity: Sendable {
        let sha256: String
        let bytes: Int
    }
    struct Limits: Sendable {
        var maximumPolylinePoints = 262_144 // 4MiB coordinate payload per result
        var pages = RoutingFilePages.Limits(pageBytes: 65_536,maximumCachedBytes: 1_048_576,
            maximumReadBytes: 65_536,maximumLivePayloadBytes: 1_179_648,maximumLeases: 8)
    }
    enum PackError: Error, Equatable {
        case truncated, badMagic, invalidEdge, invalidOffsets, invalidCoordinate, identityMismatch, geometryMemoryLimit
    }
    private enum Source {
        case memory(Data)
        case file(RoutingFilePages)
    }
    private let lock = NSLock()
    private var offsetWindow: (key: Int, lease: RoutingByteLease?) = (-1,nil)
    private var coordinateWindow: (key: Int, lease: RoutingByteLease?) = (-1,nil)
    private var offsetPage: RoutingPageBorrow?
    private var coordinatePage: RoutingPageBorrow?
    private let source: Source
    let edgeCount: Int
    private let coordinateCount: Int
    private let coordsAt: Int
    private let useFloat64: Bool
    private let limits: Limits
    var pageStatistics: RoutingFilePages.Statistics? {
        if case .file(let pages) = source { return pages.statistics }
        return nil
    }
    private struct Header {
        let edges: Int, coordinates: Int, coordinatesAt: Int
        let doubles: Bool
        init(_ raw: UnsafeRawBufferPointer,fileBytes: Int) throws {
            guard raw.count >= 16,fileBytes >= 16 else { throw PackError.truncated }
            guard UInt32.routingDecode(raw,at: 0) == GeometryV1Pack.magic else { throw PackError.badMagic }
            edges = Int(UInt32.routingDecode(raw,at: 8)); coordinates = Int(UInt32.routingDecode(raw,at: 12))
            doubles = UInt16.routingDecode(raw,at: 6)&1 != 0
            guard edges < (fileBytes-16)/4 else { throw PackError.truncated }
            var offset = 16+(edges+1)*4
            if doubles,offset%8 != 0 { offset += 8-offset%8 }
            let width = doubles ? 8:4
            guard offset <= fileBytes,coordinates <= (fileBytes-offset)/width else { throw PackError.truncated }
            coordinatesAt = offset
        }
    }
    init(data: Data,limits: Limits = Limits()) throws {
        let header = try data.withUnsafeBytes { try Header($0,fileBytes: data.count) }
        guard limits.maximumPolylinePoints > 0,limits.pages.maximumReadBytes >= 65_536 else { throw PackError.geometryMemoryLimit }
        source = .memory(data); self.limits = limits
        edgeCount = header.edges;coordinateCount = header.coordinates
        coordsAt = header.coordinatesAt;useFloat64 = header.doubles
    }
    init(url: URL,identity: Identity,expectedEdgeCount: Int,limits: Limits = Limits(),
        cancelled: () -> Bool = { RoutingWorkContext.stopReason != nil }) throws {
        guard limits.maximumPolylinePoints > 0,limits.pages.maximumReadBytes >= 65_536 else { throw PackError.geometryMemoryLimit }
        let pages = try RoutingFilePages(url: url,limits: limits.pages)
        guard pages.fileBytes == identity.bytes,
              try ExactSnapIndex.digest(pages,cancelled: cancelled) == identity.sha256 else { throw PackError.identityMismatch }
        let bytes = try pages.read(at: 0,count: 16,cancelled: cancelled)
        let header = try bytes.withUnsafeBytes { try Header($0,fileBytes: pages.fileBytes) }
        guard header.edges == expectedEdgeCount else { throw PackError.identityMismatch }
        source = .file(pages);self.limits = limits
        edgeCount = header.edges;coordinateCount = header.coordinates
        coordsAt = header.coordinatesAt;useFloat64 = header.doubles
    }
    /// Validate a cached match without rereading its entire polyline.
    func validateSource(cancelled: () -> Bool = { false }) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled() { throw RoutingPageError.cancelled }
        if case .file(let pages) = source { try pages.validate(cancelled: cancelled) }
    }

    private func read(at offset: Int,count: Int,cancelled: () -> Bool) throws -> RoutingByteLease {
        switch source {
        case .file(let pages): return try pages.read(at: offset,count: count,cancelled: cancelled)
        case .memory(let data):
            guard !cancelled() else { throw RoutingPageError.cancelled }
            guard offset >= 0,count >= 0,offset <= data.count,count <= data.count-offset else { throw PackError.truncated }
            return RoutingByteLease(data: data.subdata(in: offset..<(offset+count)))
        }
    }
    /// One offset and one coordinate window are retained (at most 128KiB),
    /// charged to the file source budget. Whole-call locking protects shared
    /// leases; cached hits allocate no Data or filesystem checks per point.
    /// The complete result is published only after source validation succeeds.
    /// Empty valid source geometry is distinct from corrupt/unavailable data.
    func polyline(edgeIndex edge: Int,forward: Bool = true,
        cancelled: () -> Bool = { RoutingWorkContext.stopReason != nil }) throws -> [CLLocationCoordinate2D] {
        lock.lock();defer { lock.unlock() }
        guard edge >= 0,edge < edgeCount else { throw PackError.invalidEdge }
        if case .file(let pages) = source {
            return try filePolyline(pages: pages,edge: edge,forward: forward,cancelled: cancelled)
        }
        func offset(_ index: Int) throws -> Int {
            let key = index/16_384
            if offsetWindow.key != key {
                offsetWindow = (-1,nil)
                let first = key*16_384
                offsetWindow = (key,try read(at: 16+first*4,count: min(16_384,edgeCount+1-first)*4,cancelled: cancelled))
            }
            return offsetWindow.lease!.withUnsafeBytes { Int(Int32.routingDecode($0,at: (index%16_384)*4)) }
        }
        let start = try offset(edge),end = try offset(edge+1)
        guard start >= 0,end >= start,end <= coordinateCount,start%2 == 0,end%2 == 0 else { throw PackError.invalidOffsets }
        let points = (end-start)/2
        guard points <= limits.maximumPolylinePoints else { throw PackError.geometryMemoryLimit }
        var output: [CLLocationCoordinate2D] = [];output.reserveCapacity(points)
        let width = useFloat64 ? 8:4
        var cursor = start
        while cursor < end {
            guard !cancelled() else { throw RoutingPageError.cancelled }
            let blockCount = 65_536/width,key = cursor/blockCount
            if coordinateWindow.key != key {
                coordinateWindow = (-1,nil)
                let first = key*blockCount
                coordinateWindow = (key,try read(at: coordsAt+first*width,
                    count: min(blockCount,coordinateCount-first)*width,cancelled: cancelled))
            }
            let within = cursor%blockCount,count = min(end-cursor,blockCount-within)
            try coordinateWindow.lease!.withUnsafeBytes { raw in
                for i in stride(from: 0,to: count,by: 2) {
                    let lon = useFloat64 ? Double.routingDecode(raw,at: (within+i)*width) : Double(Float.routingDecode(raw,at: (within+i)*width))
                    let lat = useFloat64 ? Double.routingDecode(raw,at: (within+i+1)*width) : Double(Float.routingDecode(raw,at: (within+i+1)*width))
                    guard lon.isFinite,lat.isFinite else { throw PackError.invalidCoordinate }
                    output.append(.init(latitude: lat,longitude: lon))
                }
            }
            cursor += count
        }
        guard !cancelled() else { throw RoutingPageError.cancelled }
        if case .file(let pages) = source { try pages.validate(cancelled: cancelled) }
        if !forward { output.reverse() }
        return output
    }
    /// Production path borrows existing cached page storage. Two counted page
    /// references remain pinned under the unchanged shared payload limit.
    private func filePolyline(pages: RoutingFilePages,edge: Int,forward: Bool,
        cancelled: () -> Bool) throws -> [CLLocationCoordinate2D] {
        try pages.validate(cancelled: cancelled)
        func offset(_ row: Int) throws -> Int {
            let position=16+row*4
            if offsetPage == nil || position < offsetPage!.fileOffset
                || position-offsetPage!.fileOffset >= offsetPage!.count {
                offsetPage=nil
                offsetPage=try pages.borrowPage(containing: position,cancelled: cancelled)
            }
            let page=offsetPage!,within=position-page.fileOffset
            if page.count-within < 4 {
                let value=try pages.read(at: position,count: 4,cancelled: cancelled)
                return value.withUnsafeBytes { Int(Int32.routingDecode($0,at: 0)) }
            }
            return page.withUnsafeBytes { Int(Int32.routingDecode($0,at: within)) }
        }
        let start=try offset(edge),end=try offset(edge+1)
        guard start >= 0,end >= start,end <= coordinateCount,start%2 == 0,end%2 == 0 else { throw PackError.invalidOffsets }
        let points=(end-start)/2
        guard points <= limits.maximumPolylinePoints else { throw PackError.geometryMemoryLimit }
        var result: [CLLocationCoordinate2D]=[];result.reserveCapacity(points)
        let width=useFloat64 ? 8:4
        func appendPair(_ raw: UnsafeRawBufferPointer,_ at: Int) throws {
            let lon=useFloat64 ? Double.routingDecode(raw,at: at) : Double(Float.routingDecode(raw,at: at))
            let lat=useFloat64 ? Double.routingDecode(raw,at: at+width) : Double(Float.routingDecode(raw,at: at+width))
            guard lon.isFinite,lat.isFinite else { throw PackError.invalidCoordinate }
            result.append(.init(latitude: lat,longitude: lon))
        }
        var cursor=start
        while cursor < end {
            guard !cancelled() else { throw RoutingPageError.cancelled }
            let position=coordsAt+cursor*width
            if coordinatePage == nil || position < coordinatePage!.fileOffset
                || position-coordinatePage!.fileOffset >= coordinatePage!.count {
                coordinatePage=nil
                coordinatePage=try pages.borrowPage(containing: position,cancelled: cancelled)
            }
            let page=coordinatePage!,within=position-page.fileOffset
            let pairs=min(512,min((end-cursor)/2,(page.count-within)/(width*2)))
            if pairs == 0 {
                // Column alignment may leave one scalar on either side of a
                // physical page boundary. Copy only that complete lon/lat pair.
                let pair=try pages.read(at: position,count: width*2,cancelled: cancelled)
                try pair.withUnsafeBytes { try appendPair($0,0) }
                cursor += 2
            } else {
                try page.withUnsafeBytes { raw in
                    for pair in 0..<pairs { try appendPair(raw,within+pair*width*2) }
                }
                cursor += pairs*2
            }
        }
        guard !cancelled() else { throw RoutingPageError.cancelled }
        try pages.validate(cancelled: cancelled)
        if !forward { result.reverse() }
        return result
    }

}
