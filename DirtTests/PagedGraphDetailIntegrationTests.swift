import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite("Paged graph detail integration", .serialized)
struct PagedGraphDetailIntegrationTests {
    private func fixture() throws -> (Data,Data) {
        let prefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety")
        return (try Data(contentsOf: URL(fileURLWithPath: prefix.path+".graph.v4.bin")),
            try Data(contentsOf: URL(fileURLWithPath: prefix.path+".geometry.v1.bin")))
    }
    private func identity(_ data: Data) -> PagedEdgeDetail.Identity {
        .init(sha256: SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined(),bytes: data.count,
            edgeCount: data.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 12)) })
    }
    @Test func allLeavesAndRoutesMatchWithoutResidentLeafArrays() throws {
        let (graph,geometry) = try fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paged-graph-"+UUID().uuidString)
        try graph.write(to: url);defer { try? FileManager.default.removeItem(at: url) }
        let dense = try GraphV2Pack(data: graph), paged = try GraphV2Pack(url: url,identity: identity(graph))
        dense.geometry = try GeometryV1Pack(data: geometry);paged.geometry = try GeometryV1Pack(data: geometry)
        #expect(dense.residentEdgeDetailArrayBytes > 0)
        #expect(paged.residentEdgeDetailArrayBytes == 0)
        #expect(paged.nonresidentEdgeDetailBytes == dense.residentEdgeDetailArrayBytes)
        #expect(paged.edgeSurfaceLeaf == nil && paged.edgeCrossingSeconds == nil)
        #expect(paged.osmNodeIds == dense.osmNodeIds && paged.osmWayIds == dense.osmWayIds)
        #expect(paged.edgeAccess == dense.edgeAccess)
        let reader = try #require(paged.edgeDetailReader)
        try reader.withQuery { query in
            for edge in 0..<dense.undirectedEdgeCount {
                let actualedgeLeaves = try paged.edgeLeaves(edge,query: query), expectededgeLeaves = try dense.edgeLeaves(edge)
                #expect(actualedgeLeaves == expectededgeLeaves)
                let actualcrossingSeconds = try paged.crossingSeconds(edge,query: query), expectedcrossingSeconds = try dense.crossingSeconds(edge)
                #expect(actualcrossingSeconds == expectedcrossingSeconds)
                let actualsurfaceFamily = try paged.surfaceFamily(edge,query: query), expectedsurfaceFamily = try dense.surfaceFamily(edge)
                #expect(actualsurfaceFamily == expectedsurfaceFamily)
                let actualroadTier = try paged.roadTier(edge,query: query), expectedroadTier = try dense.roadTier(edge)
                #expect(actualroadTier == expectedroadTier)
            }
            #expect(query.statistics.allocatedRowPayloadBytes <= 16_384)
            print("[paged-detail] removedArrayBytes=\(paged.nonresidentEdgeDetailBytes) retainedArrayBytes=\(paged.residentEdgeDetailArrayBytes) queryRowBytes=\(query.statistics.allocatedRowPayloadBytes)")
        }
        for profile: RouteProfile in [.cleanest,.balanced,.dirt] {
            for seed: UInt64 in [0,17] {
                let a = try route(dense,profile: profile,seed: seed),b = try route(paged,profile: profile,seed: seed)
                #expect(a.edgeIds == b.edgeIds)
                #expect(a.coordinates.map(\.longitude) == b.coordinates.map(\.longitude))
                #expect(a.coordinates.map(\.latitude) == b.coordinates.map(\.latitude))
                #expect(a.distanceMeters == b.distanceMeters)
                #expect(a.reportedDirtPercent == b.reportedDirtPercent)
                #expect(a.reportedPavedPercent == b.reportedPavedPercent)
                #expect(a.unknownSurfacePercent == b.unknownSurfacePercent)
                #expect(a.backtrackMeters == b.backtrackMeters)
                #expect(a.terminalContinuation == b.terminalContinuation)
                #expect(a.searchMeta.resourceSelectionCost == b.searchMeta.resourceSelectionCost)
            }
        }
        #expect((reader.pageStatistics?.leaseCount ?? Int.max) <= 8)
        #expect((reader.pageStatistics?.peakLivePayloadBytes ?? Int.max) <= 1_179_648)
    }
    private func route(_ pack: GraphV2Pack,profile: RouteProfile,seed: UInt64) throws -> OnDeviceRouter.Result {
        let start = try #require(pack.osmNodeIds.firstIndex(of: 1)),end = try #require(pack.osmNodeIds.firstIndex(of: 4))
        var router = try fixtureRouter(pack: pack)
        router.recordedStartNode = start;router.recordedEndNode = end;router.matchLimitMeters = 30
        func point(_ n: Int) -> CLLocationCoordinate2D { .init(latitude: Double(pack.nodeCoords[2*n+1]),longitude: Double(pack.nodeCoords[2*n])) }
        let result = router.routeDetailed(from: point(start),to: point(end),profile: profile,allowUnknown: false,sessionSeed: seed)
        guard case .success(let route) = result else { throw Failure.route(String(describing: result)) }
        return route
    }
    @Test func bothDistinctSourceHashPassesAreCounted() throws {
        let (graph,_) = try fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paged-hash-"+UUID().uuidString)
        try graph.write(to: url);defer { try? FileManager.default.removeItem(at: url) }
        let measurement = RoutingMeasurement(metadata: ["workload":"paged-detail-distinct-source-hashes"])
        _ = try RoutingWorkContext.$measurement.withValue(measurement) {
            try GraphV2Pack(url: url,identity: identity(graph))
        }
        let report = measurement.finish(outcome: "verified")
        #expect(report.counters["fileBytesHashed"] == UInt64(graph.count)*2)
    }
    @Test func sourceFailureIsNotUnknownLeafOrNoPath() throws {
        let (graph,geometry) = try fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paged-error-"+UUID().uuidString)
        try graph.write(to: url);defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: RoutingPageError.cancelled) {
            try GraphV2Pack(url: url,identity: identity(graph),cancelled: { true })
        }
        let pack = try GraphV2Pack(url: url,identity: identity(graph))
        pack.geometry = try GeometryV1Pack(data: geometry)
        var router = try fixtureRouter(pack: pack);router.matchLimitMeters = 30
        let handle = try FileHandle(forWritingTo: url);defer { try? handle.close() }
        try handle.truncate(atOffset: 140)
        #expect(throws: RoutingPageError.sourceChanged) { try pack.surfaceLeaf(0) }
        let result = router.routeDetailed(from: .init(latitude: 44,longitude: -63),
            to: .init(latitude: 44.01,longitude: -63),profile: .cleanest,allowUnknown: false)
        if case .failure(.searchLimit(let reason)) = result { #expect(reason == "routingDataUnavailable") }
        else { Issue.record("Unavailable detail was reported as a route or noPath") }
    }
    private enum Failure: Error { case route(String) }
}
