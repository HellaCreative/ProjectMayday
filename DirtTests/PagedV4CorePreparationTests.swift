import Foundation
import Testing
@testable import Dirt

@Suite(.serialized)
struct PagedV4CorePreparationTests {
    /// Preparation/access measurement only; no route or riding-quality claim.
    @Test(arguments: ["ns", "on"]) func currentPackColdAndProofReuse(region: String) throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DIRT_CURRENT_PACK_ROOT"]
            ?? "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs")
        let directory = root.appendingPathComponent(region)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("pack-manifest.v2.json"))) as? [String:Any])
        let graph = try #require(manifest["graph"] as? [String:Any])
        let name = try #require(graph["name"] as? String)
        try #require(!name.contains("/") && name != "..")
        let hash = try #require(graph["sha256"] as? String), bytes = try #require(graph["bytes"] as? Int)
        let identity = PagedV4Core.Identity(sha256: hash,bytes: bytes)
        var proof: PagedV4Core.TopologyProof?
        for run in 0..<2 {
            let measurement = RoutingMeasurement(metadata: ["workload":"paged-core-preparation-"+region,
                "hardware":"MacBookPro17,1 Apple M1 16 GiB; iPhone17 iOS26.5 simulator",
                "execution":"PagedV4Core direct immutable bytes; no GraphV2Pack or route calculation",
                "graphSHA256":hash,"graphBytes":String(bytes),"region":region,
                "preparation":run == 0 ? "first topology proof" : "reuse in-memory hash-bound proof",
                "windowMilliseconds":"15000"])
            var outcome = "unattempted", validationNodes = 0, validationArcs = 0
            var queryNodes: UInt64 = 0, queryEdges: UInt64 = 0, peakPageBytes = 0
            RoutingWorkContext.$measurement.withValue(measurement) {
                RoutingWorkContext.$deadline.withValue(RoutingWorkContext.limitedDeadline(milliseconds: 15_000)) {
                    let phase = measurement.begin(.decode)
                    defer { measurement.end(phase) }
                    do {
                        let reader = try PagedV4Core(url: directory.appendingPathComponent(name),identity: identity,
                            proof: proof,cancelled: {
                                measurement.sampleIfDue()
                                return RoutingWorkContext.stopReason != nil
                            })
                        defer { reader.close() }
                        proof = reader.proof
                        validationNodes = reader.preparation.validationNodes
                        validationArcs = reader.preparation.validationArcs
                        try reader.withQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { query in
                            for node in [0,reader.nodeCount/2,reader.nodeCount-1] where node >= 0 {
                                _ = try query.node(node)
                                try query.outgoing(node) { _ in }
                            }
                            for edge in [0,reader.edgeCount/2,reader.edgeCount-1] where edge >= 0 {
                                _ = try query.edge(edge)
                            }
                        }
                        queryNodes = reader.queryStatistics.nodes;queryEdges = reader.queryStatistics.edges
                        peakPageBytes = reader.pageStatistics.peakLivePayloadBytes
                        #expect(queryNodes == 3 && queryEdges == 3)
                        #expect(peakPageBytes <= reader.pageStatistics.maximumLivePayloadBytes)
                        if run == 1 { #expect(validationNodes == 0 && validationArcs == 0) }
                        outcome = "prepared-and-read"
                    } catch { outcome = "unproved:\(error)"; Issue.record("\(region) preparation run\(run): \(error)") }
                }
            }
            struct Evidence: Encodable {
                let measurement: RoutingMeasurement.Report
                let validationNodes: Int, validationArcs: Int
                let queryNodes: UInt64, queryEdges: UInt64
                let peakPageBytes: Int
            }
            let evidence = Evidence(measurement: measurement.finish(outcome: outcome),validationNodes: validationNodes,
                validationArcs: validationArcs,queryNodes: queryNodes,queryEdges: queryEdges,peakPageBytes: peakPageBytes)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("paged-core-\(region)-run\(run).json")
            try JSONEncoder().encode(evidence).write(to: path)
            print("[paged-core-preparation] outcome=\(outcome) evidence=\(path.path)")
            if proof == nil { break } // No fabricated warm proof after interrupted preparation.
        }
    }
}
