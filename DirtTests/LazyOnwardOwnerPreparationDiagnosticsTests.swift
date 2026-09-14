import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite(.serialized)
struct LazyOnwardOwnerPreparationDiagnosticsTests {
    /// Exact first-owner post-initial-refill window, not a new route or initial
    /// closest-station qualification. Existing GraphV2Pack core is still decoded.
    @Test func firstOwnerPostRefillColdWarmAndOneRefinement() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DIRT_CURRENT_PACK_ROOT"]
            ?? "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs")
            .appendingPathComponent("ns")
        let manifestBytes = try Data(contentsOf: root.appendingPathComponent("pack-manifest.v2.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestBytes) as? [String:Any])
        func file(_ key: String) throws -> (name: String,sha: String,bytes: Int) {
            let row = try #require(manifest[key] as? [String:Any])
            let name = try #require(row["name"] as? String)
            try #require(!name.contains("/") && name != "..")
            return (name,try #require(row["sha256"] as? String),try #require(row["bytes"] as? Int))
        }
        let graph = try file("graph"),geometry = try file("geometry"),fuel = try file("fuel")
        let identity = ExactSnapIndex.Identity(graphSHA256: graph.sha,graphBytes: graph.bytes,
            geometrySHA256: geometry.sha,geometryBytes: geometry.bytes)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lazy-owner-index-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var router: OnDeviceRouter?,stations: [CLLocationCoordinate2D] = []
        // Origin is the accepted initial station in the measured owner itinerary.
        let from = CLLocationCoordinate2D(latitude: 44.744229,longitude: -63.284939)
        let to = CLLocationCoordinate2D(latitude: 46.95522997783574,longitude: -60.45932167843518)
        for run in 0..<2 {
            let measurement = RoutingMeasurement(metadata: [
                "workload":"owner20AB-post-initial-refill-lazy-preparation",
                "sourceIdentity":ProcessInfo.processInfo.environment["DIRT_SOURCE_ID"] ?? "record compiled source externally",
                "packRelease":"fabric-v4-20260909-02","graphSHA256":graph.sha,"graphBytes":String(graph.bytes),
                "geometrySHA256":geometry.sha,"geometryBytes":String(geometry.bytes),"fuelSHA256":fuel.sha,
                "manifestSHA256":SHA256.hash(data: manifestBytes).map { String(format:"%02x",$0) }.joined(),
                "hardware":ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown",
                "OS":ProcessInfo.processInfo.operatingSystemVersionString,
                "execution":"single-source GraphV2Pack core + completed field hints; NOT selective core or full route",
                "preparation":run == 0 ? "cold decoded graph/index" : "warm same graph/index",
                "origin":"44.744229,-63.284939","destination":"46.95522997783574,-60.45932167843518",
                "ownerOriginalOrigin":"44.764804567541226,-63.34024797349485",
                "profile":"dirt","allowUnknown":"false","seed":"5934816597329416","mapZoom":"10.2",
                "tankMeters":"200000","reservePercent":"10","usableMeters":"180000","windowMilliseconds":"20000"])
            var prepared: LazyOnwardStationPreparation.Prepared?,selected: Int?,matches: Int?
            var outcome = "unattempted"
            RoutingWorkContext.$measurement.withValue(measurement) {
                RoutingWorkContext.$deadline.withValue(RoutingWorkContext.limitedDeadline(milliseconds: 20_000)) {
                    do {
                        if router == nil {
                            let phase = measurement.begin(.decode)
                            defer { measurement.end(phase) }
                            let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(graph.name))
                            let header: Data
                            do { header = try handle.read(upToCount: 16) ?? Data(); try handle.close() }
                            catch { try? handle.close(); throw error }
                            guard header.count == 16 else { throw LazyOnwardStationPreparation.Failure.invalidInput }
                            let edges = header.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 12)) }
                            let pack = try GraphV2Pack(url: root.appendingPathComponent(graph.name),
                                identity: .init(sha256: graph.sha,bytes: graph.bytes,edgeCount: edges),
                                cancelled: { measurement.sampleIfDue(); return RoutingWorkContext.stopReason != nil })
                            pack.geometry = try GeometryV1Pack(url: root.appendingPathComponent(geometry.name),
                                identity: .init(sha256: geometry.sha,bytes: geometry.bytes),expectedEdgeCount: edges,
                                cancelled: { measurement.sampleIfDue(); return RoutingWorkContext.stopReason != nil })
                            pack.regionId = "ns"
                            pack.exactSnapIndex = try ExactSnapIndexPreparation.prepare(graphURL: root.appendingPathComponent(graph.name),
                                geometryURL: root.appendingPathComponent(geometry.name),destination: temporary.appendingPathComponent("snap.bin"),
                                identity: identity,cancelled: { measurement.sampleIfDue(); return RoutingWorkContext.stopReason != nil })
                            let fuelBytes = try Data(contentsOf: root.appendingPathComponent(fuel.name))
                            guard fuelBytes.count == fuel.bytes,
                                  SHA256.hash(data: fuelBytes).map({ String(format:"%02x",$0) }).joined() == fuel.sha else {
                                throw LazyOnwardStationPreparation.Failure.incompatibleSource
                            }
                            stations = PackedFuel.decode(fuelBytes).map { .init(latitude: $0.latitude,longitude: $0.longitude) }
                            try RoutingWorkContext.check()
                            router = OnDeviceRouter(pack: pack)
                        }
                        guard let router else { throw LazyOnwardStationPreparation.Failure.invalidInput }
                        switch try router.prepareLazyOnwardStationHints(from: from,to: to,stations: stations,
                            profile: .dirt,allowUnknown: false,usableMeters: 180_000) {
                        case .requiresExactPreparation(let reason):
                            outcome = "requires-exact-preparation:"+reason
                            Issue.record("\(outcome)")
                        case .prepared(let value):
                            prepared = value
                            #expect(value.hints.count == stations.count)
                            #expect(value.statistics.stationProjectionQueries == 0)
                            selected = value.orderedStationIndices.first
                            if let selected {
                                matches = try router.refineLazyOnwardStationHint(value,stationIndex: selected)
                                outcome = "prepared-one-refinement-"+(matches == 0 ? "unmatched" : "matched")
                            } else { outcome = "prepared-no-stations"; Issue.record("\(outcome)") }
                        }
                    } catch {
                        outcome = "incomplete:"+String(describing:error)
                        Issue.record("\(outcome)")
                    }
                }
            }
            struct Evidence: Encodable {
                let measurement: RoutingMeasurement.Report
                let prepared: LazyOnwardStationPreparation.Prepared?
                let refinedStationIndex: Int?, exactMatches: Int?
            }
            let evidence = Evidence(measurement: measurement.finish(outcome: outcome),prepared: prepared,
                refinedStationIndex: selected,exactMatches: matches)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("lazy-owner-preparation-run\(run).json")
            try JSONEncoder().encode(evidence).write(to: url)
            print("[lazy-owner-preparation] outcome=\(outcome) evidence=\(url.path)")
            if router == nil { break }
        }
    }
}
