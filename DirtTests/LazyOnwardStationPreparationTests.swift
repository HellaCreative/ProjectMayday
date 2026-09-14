import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct LazyOnwardStationPreparationTests {
    private func router() throws -> (OnDeviceRouter,URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let graphURL = root.appendingPathComponent("legal-topology-forecourt.graph.v4.bin")
        let geometryURL = root.appendingPathComponent("legal-topology-forecourt.geometry.v1.bin")
        let graph = try Data(contentsOf: graphURL),geometry = try Data(contentsOf: geometryURL)
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined() }
        let identity = ExactSnapIndex.Identity(graphSHA256: hash(graph),graphBytes: graph.count,
            geometrySHA256: hash(geometry),geometryBytes: geometry.count)
        let edgeCount = graph.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 12)) }
        let pack = try GraphV2Pack(url: graphURL,identity: .init(sha256: identity.graphSHA256,bytes: identity.graphBytes,edgeCount: edgeCount))
        pack.geometry = try GeometryV1Pack(url: geometryURL,identity: .init(sha256: identity.geometrySHA256,bytes: identity.geometryBytes),expectedEdgeCount: edgeCount)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lazy-hints-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        do {
            pack.exactSnapIndex = try ExactSnapIndexPreparation.prepare(graphURL: graphURL,geometryURL: geometryURL,
                destination: directory.appendingPathComponent("snap.bin"),identity: identity)
            return (OnDeviceRouter(pack: pack),directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    @Test func nativePreparationKeepsUnknownStationsWithoutProjectingThem() throws {
        let (router,directory) = try router()
        defer { try? FileManager.default.removeItem(at: directory) }
        let from = CLLocationCoordinate2D(latitude: 45,longitude: -64.004)
        let to = CLLocationCoordinate2D(latitude: 45,longitude: -63.996)
        let points = [from,to,CLLocationCoordinate2D(latitude: 0,longitude: 0)]
        let measurement = RoutingMeasurement(metadata: ["workload":"lazy-onward-preparation-fixture"])
        let outcome = try RoutingWorkContext.$measurement.withValue(measurement) {
            try router.prepareLazyOnwardStationHints(from: from,to: to,stations: points,
                profile: .dirt,allowUnknown: false,usableMeters: 2_000)
        }
        guard case .prepared(let prepared) = outcome else { Issue.record("Supported fixture preparation should complete"); return }
        #expect(prepared.hints.count == points.count)
        #expect(Set(prepared.orderedStationIndices) == Set(points.indices))
        #expect(prepared.hints[2].forwardEstimate == nil && prepared.hints[2].remainingEstimate == nil)
        #expect(prepared.statistics.completedFields == 2)
        #expect(prepared.statistics.stationProjectionQueries == 0)
        #expect(prepared.statistics.parentMembershipVisits <= points.count * 2 * LazyOnwardStationPreparation.maximumSampledParentRecords)
        let report = measurement.finish(outcome: "ordering-only")
        // Only the two field anchors may invoke the geometry matcher.
        #expect((report.phases["matching"]?.completedCount ?? 0) <= 2)
        let matches = try router.refineLazyOnwardStationHint(prepared,stationIndex: 0)
        #expect(matches > 0)
        #expect(try router.refineLazyOnwardStationHint(prepared,stationIndex: 2) == 0)
        #expect(prepared.hints.count == 3) // Unmatched refinement does not erase pending candidates.
    }
    @Test func boundedUnsupportedPreparationRequiresExactFallback() throws {
        let (router,directory) = try router()
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = LazyOnwardStationPreparation.Limits(); limits.maximumNodes = 1
        let origin = CLLocationCoordinate2D(latitude: 45,longitude: -64.004)
        let result = try router.prepareLazyOnwardStationHints(from: origin,to: origin,stations: [origin],
            profile: .cleanest,allowUnknown: false,usableMeters: 200,limits: limits)
        guard case .requiresExactPreparation = result else { Issue.record("Limit must request fallback, not emit an empty candidate set"); return }
    }
    @Test func changedSourceCannotRefineSavedHints() throws {
        let (router,directory) = try router()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = CLLocationCoordinate2D(latitude: 45,longitude: -64.004)
        guard case .prepared(let original) = try router.prepareLazyOnwardStationHints(from: origin,to: origin,
            stations: [origin],profile: .balanced,allowUnknown: false,usableMeters: 200) else {
            Issue.record("Expected supported fixture"); return
        }
        let r = original.request
        let changed = LazyOnwardStationPreparation.Request(source: .init(graphSHA256: "changed",graphBytes: r.source.graphBytes,
            geometrySHA256: r.source.geometrySHA256,geometryBytes: r.source.geometryBytes),origin: r.origin,destination: r.destination,
            stations: r.stations,profile: r.profile,allowUnknown: r.allowUnknown,usableMeters: r.usableMeters,
            radiusMeters: r.radiusMeters,formatVersion: r.formatVersion)
        let stale = LazyOnwardStationPreparation.Prepared(request: changed,hints: original.hints,statistics: original.statistics)
        #expect(throws: LazyOnwardStationPreparation.Failure.incompatibleSource) {
            try router.refineLazyOnwardStationHint(stale,stationIndex: 0)
        }
    }
    @Test func expiredWindowDoesNotPublishHintPreparation() throws {
        let (router,directory) = try router()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = CLLocationCoordinate2D(latitude: 45,longitude: -64.004)
        #expect(throws: (any Error).self) {
            try RoutingWorkContext.$deadline.withValue(RoutingWorkContext.limitedDeadline(milliseconds: 0)) {
                try router.prepareLazyOnwardStationHints(from: origin,to: origin,stations: [origin],
                    profile: .dirt,allowUnknown: false,usableMeters: 200)
            }
        }
    }
    @Test func graphOrderingNeverTurnsUnknownOrLongEstimatesIntoExclusions() {
        let p0 = LazyOnwardStationPreparation.Point(.init(latitude: 45,longitude: -60))
        let p1 = LazyOnwardStationPreparation.Point(.init(latitude: 45,longitude: -63))
        let request = LazyOnwardStationPreparation.Request(source: .init(graphSHA256: "fixture",graphBytes: 1,
            geometrySHA256: "fixture",geometryBytes: 1),origin: p1,destination: p0,stations: [p0,p1,p1],
            profile: .dirt,allowUnknown: false,usableMeters: 180_000,radiusMeters: 550,formatVersion: 1)
        let hints = [LazyOnwardStationPreparation.Hint(stationIndex: 0,forwardEstimate: 100_000,remainingEstimate: 10_000),
            .init(stationIndex: 1,forwardEstimate: 5_000,remainingEstimate: 100_000),
            .init(stationIndex: 2,forwardEstimate: nil,remainingEstimate: nil)]
        let prepared = LazyOnwardStationPreparation.Prepared(request: request,hints: hints,
            statistics: .init(elapsedSeconds: 0,completedFields: 2,parentMembershipVisits: 0,retainedHintPayloadBytes: 0,stationProjectionQueries: 0))
        #expect(prepared.orderedStationIndices == [0,1,2])
        #expect(hints[2].confidence == .unknown)
        #expect(hints[0].confidence == .orderingOnly)
    }

    @Test func independentlyVerifiedButDifferentGeometryCannotUseIndexIdentity() throws {
        let (router,directory) = try router()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/legal-topology-forecourt.geometry.v1.bin")
        var bytes = try Data(contentsOf: fixture); bytes[bytes.count-1] ^= 1
        let changed = directory.appendingPathComponent("changed.geometry")
        try bytes.write(to: changed)
        router.pack.geometry = try GeometryV1Pack(url: changed,identity: .init(
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined(),bytes: bytes.count),
            expectedEdgeCount: router.pack.undirectedEdgeCount)
        let origin = CLLocationCoordinate2D(latitude: 45,longitude: -64.004)
        #expect(throws: LazyOnwardStationPreparation.Failure.incompatibleSource) {
            try router.prepareLazyOnwardStationHints(from: origin,to: origin,stations: [origin],
                profile: .dirt,allowUnknown: false,usableMeters: 200)
        }
    }

    @Test func independentlyReindexedWrongGeometryPairIsRejected() throws {
        let (router,directory) = try router()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let graphURL = root.appendingPathComponent("legal-topology-forecourt.graph.v4.bin")
        var bytes = try Data(contentsOf: root.appendingPathComponent("legal-topology-forecourt.geometry.v1.bin"))
        bytes[bytes.count-1] ^= 1
        let changed = directory.appendingPathComponent("reindexed.geometry")
        try bytes.write(to: changed)
        let old = try #require(router.pack.exactSnapIndex).verifiedIdentity
        let identity = ExactSnapIndex.Identity(graphSHA256: old.graphSHA256,graphBytes: old.graphBytes,
            geometrySHA256: SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined(),geometryBytes: bytes.count)
        router.pack.geometry = try GeometryV1Pack(url: changed,identity: .init(sha256: identity.geometrySHA256,bytes: bytes.count),
            expectedEdgeCount: router.pack.undirectedEdgeCount)
        router.pack.exactSnapIndex = try ExactSnapIndexPreparation.prepare(graphURL: graphURL,geometryURL: changed,
            destination: directory.appendingPathComponent("wrong-pair.snap"),identity: identity)
        #expect(router.pack.pairedGeometrySHA256 == old.geometrySHA256)
        #expect(router.pack.exactSnapIndex?.verifiedIdentity.geometrySHA256 == identity.geometrySHA256)
        let origin = CLLocationCoordinate2D(latitude: 45,longitude: -64.004)
        #expect(throws: LazyOnwardStationPreparation.Failure.incompatibleSource) {
            try router.prepareLazyOnwardStationHints(from: origin,to: origin,stations: [origin],
                profile: .dirt,allowUnknown: false,usableMeters: 200)
        }
        let request = LazyOnwardStationPreparation.Request(source: identity,origin: .init(origin),destination: .init(origin),
            stations: [.init(origin)],profile: .dirt,allowUnknown: false,usableMeters: 200,radiusMeters: 550,formatVersion: 1)
        let saved = LazyOnwardStationPreparation.Prepared(request: request,hints: [],statistics: .init(
            elapsedSeconds: 0,completedFields: 2,parentMembershipVisits: 0,retainedHintPayloadBytes: 0,stationProjectionQueries: 0))
        #expect(throws: LazyOnwardStationPreparation.Failure.incompatibleSource) {
            try router.refineLazyOnwardStationHint(saved,stationIndex: 0)
        }
    }

}
