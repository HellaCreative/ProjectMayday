import Foundation
import Testing
@testable import Dirt

@Suite(.serialized)
struct PagedV4TurnPreparationDiagnosticsTests {
    /// Preparation/turn-state measurement only; no route or riding-quality claim.
    @Test(arguments: ["ns", "on"]) func currentPackTurnPreparationColdAndProofReuse(region: String) throws {
        try run(region: region,demandDriven: false)
    }
    @Test(arguments: ["ns", "on"]) func currentPackDemandTurnPreparationColdAndProofReuse(region: String) throws {
        try run(region: region,demandDriven: true)
    }
    private func run(region: String,demandDriven: Bool) throws {
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
            let measurement = RoutingMeasurement(metadata: ["workload":"paged-turn-preparation-"+region,
                "hardware":"MacBookPro17,1 Apple M1 16 GiB; iPhone17 iOS26.5 simulator",
                "execution":"PagedV4Core direct immutable bytes; PagedV4TurnTopology throwing state preparation; no GraphV2Pack, OriginalIDIndex, or route search",
                "fabricReleaseId":String(describing: manifest["fabricReleaseId"] ?? "unavailable"),
                "sourceEpoch":String(describing: manifest["sourceEpoch"] ?? "unavailable"),
                "search":"not run; all elapsed work is preparation",
                "turnPreparation":demandDriven ? "demand-rules-only" : "eager-state-closure",
                "graphSHA256":hash,"graphBytes":String(bytes),"region":region,
                "preparation":run == 0 ? "first topology proof" : "reuse in-memory hash-bound proof",
                "windowMilliseconds":"15000"])
            var outcome = "unattempted", validationNodes = 0, validationArcs = 0
            var queryNodes: UInt64 = 0, queryEdges: UInt64 = 0, peakPageBytes = 0
            var restrictionBytes = 0, reservedBytes = 0, states = 0, restrictions = 0
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
                        defer {
                            queryNodes = reader.queryStatistics.nodes; queryEdges = reader.queryStatistics.edges
                            peakPageBytes = reader.pageStatistics.peakLivePayloadBytes
                            reader.close()
                        }
                        proof = reader.proof
                        validationNodes = reader.preparation.validationNodes
                        validationArcs = reader.preparation.validationArcs
                        try reader.withQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { query in
                            try reader.withLegalQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { legal in
                                let topology = try PagedV4TurnTopology(core: reader,query: query,legal: legal,limits: .init())
                                restrictionBytes = topology.retainedRestrictionPayloadBytes
                                restrictions = topology.restrictions.count
                                let prepared = try GraphV2Pack.V4TurnStateSpace.build(topology: topology,
                                    startNode: reader.nodeCount,endNode: reader.nodeCount+1,demandDriven: demandDriven)
                                states = prepared.stateCount
                                reservedBytes = prepared.preparationReservedBytes
                                #expect(states > 0)
                                #expect(reservedBytes <= V4TurnPreparationLimits().maximumReservedBytes)
                            }
                        }
                        queryNodes = reader.queryStatistics.nodes;queryEdges = reader.queryStatistics.edges
                        peakPageBytes = reader.pageStatistics.peakLivePayloadBytes
                        #expect(peakPageBytes <= reader.pageStatistics.maximumLivePayloadBytes)
                        if run == 1 { #expect(validationNodes == 0 && validationArcs == 0) }
                        outcome = "turn-state-prepared-no-route-search"
                    } catch { outcome = "unproved:\(error)"; Issue.record("\(region) preparation run\(run): \(error)") }
                }
            }
            struct Evidence: Encodable {
                let measurement: RoutingMeasurement.Report
                let validationNodes: Int, validationArcs: Int
                let queryNodes: UInt64, queryEdges: UInt64
                let peakPageBytes: Int
                let restrictionBytes: Int, reservedBytes: Int, states: Int, restrictions: Int
            }
            let evidence = Evidence(measurement: measurement.finish(outcome: outcome),validationNodes: validationNodes,
                validationArcs: validationArcs,queryNodes: queryNodes,queryEdges: queryEdges,peakPageBytes: peakPageBytes,restrictionBytes: restrictionBytes,
                reservedBytes: reservedBytes,states: states,restrictions: restrictions)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("paged-turn-\(demandDriven ? "demand" : "eager")-\(region)-run\(run).json")
            try JSONEncoder().encode(evidence).write(to: path)
            print("[paged-turn-preparation] outcome=\(outcome) evidence=\(path.path)")
            if proof == nil { break } // No fabricated warm proof after interrupted preparation.
        }
    }
}
