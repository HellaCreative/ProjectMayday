import Foundation
import CoreLocation
import Testing
@testable import Dirt

struct ArrivalFuelFieldTests {
    private func fixture() throws -> GraphV2Pack {
        let bundle = Bundle(for: ArrivalFuelFieldBundle.self)
        let url = try #require(bundle.url(forResource: "legal-topology-restrictions.graph.v4", withExtension: "bin", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "legal-topology-restrictions.graph.v4", withExtension: "bin"))
        let pack = try GraphV2Pack(data: Data(contentsOf: url))
        let geometryURL = try #require(bundle.url(forResource: "legal-topology-restrictions.geometry.v1", withExtension: "bin", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "legal-topology-restrictions.geometry.v1", withExtension: "bin"))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: geometryURL))
        return pack
    }
    private func coordinate(_ pack: GraphV2Pack, _ node: Int) -> CLLocationCoordinate2D {
        .init(latitude: Double(pack.nodeCoords[node * 2 + 1]), longitude: Double(pack.nodeCoords[node * 2]))
    }
    @Test func fractionalZeroRangeProtectsParentAndSeedsBothEndsWithoutGeometryAssumptions() throws {
        let pack = try fixture()
        let a = try #require(pack.osmNodeIds.firstIndex(of: 1))
        let b = try #require(pack.osmNodeIds.firstIndex(of: 2))
        let start = coordinate(pack, a), end = coordinate(pack, b)
        let midpoint = CLLocationCoordinate2D(latitude: (start.latitude + end.latitude) / 2,
                                              longitude: (start.longitude + end.longitude) / 2)
        var router = try fixtureRouter(pack: pack)
        router.matchLimitMeters = 1
        guard case .success(let approach) = router.routeDetailed(from: start, to: midpoint,
            profile: .cleanest, allowUnknown: false) else { Issue.record("Fixture approach failed"); return }
        let arrival = try #require(approach.terminalContinuation)
        let field = try #require(try router.relaxedArrivalFuelField(arrival: arrival, remainingMeters: 0))
        #expect(field.reachedNodes == [a, b])
        #expect(!field.protectedEdges.isEmpty)
        #expect(!field.reachesRecordedBorder)
    }
    @Test func indexSupersetProtectsSameEdgeAndSnapOffsetsButRejectsRemoteRoads() throws {
        let pack = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = ExactSnapIndex.Identity(graphSHA256: "arrival-fixture", graphBytes: 1,
            geometrySHA256: "arrival-geometry", geometryBytes: 1)
        let url = directory.appendingPathComponent("snap.bin")
        try ExactSnapIndexBuilder.build(to: url, identity: identity, edgeCount: pack.undirectedEdgeCount) { edge in
            let a = coordinate(pack, Int(pack.edgeFrom![edge])), b = coordinate(pack, Int(pack.edgeTo![edge]))
            return .init(aLon: a.longitude, aLat: a.latitude, bLon: b.longitude, bLat: b.latitude,
                minLon: min(a.longitude, b.longitude), maxLon: max(a.longitude, b.longitude),
                minLat: min(a.latitude, b.latitude), maxLat: max(a.latitude, b.latitude))
        }
        pack.exactSnapIndex = try ExactSnapIndex(url: url, identity: identity)
        let a = try #require(pack.osmNodeIds.firstIndex(of: 1)), b = try #require(pack.osmNodeIds.firstIndex(of: 2))
        let start = coordinate(pack, a), end = coordinate(pack, b)
        let midpoint = CLLocationCoordinate2D(latitude: (start.latitude + end.latitude) / 2,
            longitude: (start.longitude + end.longitude) / 2)
        var router = try fixtureRouter(pack: pack)
        router.matchLimitMeters = 1
        guard case .success(let approach) = router.routeDetailed(from: start, to: midpoint,
            profile: .cleanest, allowUnknown: false) else { Issue.record("Fixture approach failed"); return }
        let arrival = try #require(approach.terminalContinuation)
        let field = try #require(try router.relaxedArrivalFuelField(arrival: arrival, remainingMeters: 0))
        #expect(try !router.stationOutsideRelaxedArrivalField(midpoint, field: field, maxMeters: 80))
        let offset = CLLocationCoordinate2D(latitude: midpoint.latitude + 0.0002, longitude: midpoint.longitude)
        #expect(try !router.stationOutsideRelaxedArrivalField(offset, field: field, maxMeters: 80))
        let remote = CLLocationCoordinate2D(latitude: 70, longitude: 100)
        #expect(try router.stationOutsideRelaxedArrivalField(remote, field: field, maxMeters: 80))
        let openBorder = OnDeviceRouter.RelaxedArrivalFuelField(reachedNodes: field.reachedNodes,
            protectedEdges: field.protectedEdges, reachesRecordedBorder: true)
        #expect(try !router.stationOutsideRelaxedArrivalField(remote, field: openBorder, maxMeters: 80))
    }

    @Test func optimizationLimitsDiscardPartialFieldsWithoutChangingCompletedSmallField() throws {
        let pack = try fixture()
        let a = try #require(pack.osmNodeIds.firstIndex(of: 1)), b = try #require(pack.osmNodeIds.firstIndex(of: 2))
        let start = coordinate(pack, a), end = coordinate(pack, b)
        let midpoint = CLLocationCoordinate2D(latitude: (start.latitude + end.latitude) / 2,
            longitude: (start.longitude + end.longitude) / 2)
        var router = try fixtureRouter(pack: pack)
        router.matchLimitMeters = 1
        guard case .success(let approach) = router.routeDetailed(from: start, to: midpoint,
            profile: .cleanest, allowUnknown: false) else { Issue.record("Fixture approach failed"); return }
        let arrival = try #require(approach.terminalContinuation)
        #expect(try router.relaxedArrivalFuelField(arrival: arrival, remainingMeters: 0,
            limits: .init(maximumStates: 1, maximumQueueEntries: 8)) == nil)
        #expect(try router.relaxedArrivalFuelField(arrival: arrival, remainingMeters: 0,
            limits: .init(maximumStates: 8, maximumQueueEntries: 1)) == nil)
        let complete = try #require(try router.relaxedArrivalFuelField(arrival: arrival, remainingMeters: 0,
            limits: .init(maximumStates: 2, maximumQueueEntries: 2)))
        #expect(complete.reachedNodes == [a, b])
        #expect(try router.relaxedArrivalFuelField(arrival: arrival, remainingMeters: 100_000,
            limits: .init(maximumStates: 2, maximumQueueEntries: 8)) == nil,
            "Discovering another road must discard the incomplete proof when state capacity is exhausted")
        #expect(try !router.stationOutsideRelaxedArrivalField(midpoint, field: complete, maxMeters: 1))
        router.recordedStartNode = a; router.recordedEndNode = b
        guard case .success(let nodeApproach) = router.routeDetailed(from: start, to: end,
            profile: .cleanest, allowUnknown: false) else { Issue.record("Node approach failed"); return }
        let nodeArrival = try #require(nodeApproach.terminalContinuation)
        #expect(try router.relaxedArrivalFuelField(arrival: nodeArrival, remainingMeters: 100_000,
            limits: .init(maximumStates: 32, maximumQueueEntries: 1)) == nil,
            "A branching frontier cannot grow past the queue limit or publish partial reachability")
    }

    @Test func expiredFieldCannotBeUsedAsCompletedNegativeProof() throws {
        let pack = try fixture()
        let a = try #require(pack.osmNodeIds.firstIndex(of: 1)), b = try #require(pack.osmNodeIds.firstIndex(of: 2))
        var router = try fixtureRouter(pack: pack)
        router.recordedStartNode = a; router.recordedEndNode = b
        guard case .success(let approach) = router.routeDetailed(from: coordinate(pack, a), to: coordinate(pack, b),
            profile: .cleanest, allowUnknown: false) else { Issue.record("Fixture approach failed"); return }
        let arrival = try #require(approach.terminalContinuation)
        #expect(throws: (any Error).self) {
            try RoutingWorkContext.$deadline.withValue(ProcessInfo.processInfo.systemUptime - 1) {
                _ = try router.relaxedArrivalFuelField(arrival: arrival, remainingMeters: 617)
            }
        }
    }
}
private final class ArrivalFuelFieldBundle: NSObject {}
