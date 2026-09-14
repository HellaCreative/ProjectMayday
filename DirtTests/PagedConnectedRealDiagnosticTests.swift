import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite(.serialized)
struct PagedConnectedRealDiagnosticTests {
    /// Recorded-node first-Clean diagnostic only. No rider-pin matching,
    /// fractional initial-station arrival, onward NB stage or fuel qualification.
    @Test func currentNSRecordedParentEndToBorderColdAndWarm() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DIRT_CURRENT_PACK_ROOT"]
            ?? "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs")
        let directory = root.appendingPathComponent("ns")
        let scratch = fm.temporaryDirectory.appendingPathComponent("paged-connected-ns-"+UUID().uuidString)
        try fm.createDirectory(at: scratch,withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        var core: PagedV4Core?, ids: OriginalIDIndex?, bundle: PagedConnectedCleanPolicyBundle?
        defer { core?.close() }
        var identityRecord: [String:Any] = [:]
        let preferences = RidePreferences(preferDifferentRoads: true,wander: 1,avoidCities: true,avoidHighways: true)
        for run in 0..<2 {
            let measurement = RoutingMeasurement(metadata: [
                "workload":"current-ns-recorded-node-paged-connected-clean",
                "hardware":"MacBookPro17,1 Apple M1 16 GiB; iPhone17 iOS26.5 simulator",
                "qualification":"recorded-node diagnostic only; no GraphV2Pack, matching, fractional arrival, or fuel proof",
                "preparation":run == 0 ? "cold private indexes and file readers" : "reuse readers and source-bound private indexes; validate source stamps",
                "originOSMNode":"7411741589","destinationOSMNode":"6952913085",
                "originParent":"792623056:7411741620:7411741589",
                "destinationParent":"149676172:1626240693:6952913085",
                "seed":"3511091208","profile":"cleanest","maxMeters":"207000",
                "preferDifferentRoads":"true","wander":"1","avoidCities":"true","avoidHighways":"true","allowUnknown":"false",
                "preparationWindowMilliseconds":"15000","calculationWindowMilliseconds":"18000",
                "limits":"existing ConnectedCleanStage defaults; no increase"])
            let started = ProcessInfo.processInfo.systemUptime
            var elapsed: [String:Double] = [:], outcome = "unattempted", result: ConnectedCleanStage.Result?
            var queryRows: [String:UInt64] = [:], pages: [String:Int] = [:]
            func timed<T>(_ name: String,_ body: () throws -> T) rethrows -> T {
                let start = ProcessInfo.processInfo.systemUptime
                defer { elapsed[name,default:0] += ProcessInfo.processInfo.systemUptime-start; measurement.sampleIfDue() }
                return try body()
            }
            func cancelled() -> Bool { measurement.sampleIfDue(); return RoutingWorkContext.stopReason != nil }
            RoutingWorkContext.$measurement.withValue(measurement) {
                do {
                    try timed("preparationTotal") {
                        // Exactly one preparation deadline covers manifest verification,
                        // both derivative builds/opens, topology proof and policy readers.
                        try RoutingWorkContext.$deadline.withValue(RoutingWorkContext.limitedDeadline(milliseconds:15_000)) {
                            if run == 0 {
                                let manifestData = try Data(contentsOf: directory.appendingPathComponent("pack-manifest.v2.json"))
                                let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String:Any])
                                try #require(manifest["fabricReleaseId"] as? String == "fabric-v4-20260909-02")
                                try #require(manifest["regionId"] as? String == "ns")
                                func file(_ key: String) throws -> (URL,String,Int) {
                                    let row = try #require(manifest[key] as? [String:Any]), name = try #require(row["name"] as? String)
                                    try #require(!name.contains("/") && name != "..")
                                    return (directory.appendingPathComponent(name),try #require(row["sha256"] as? String),try #require(row["bytes"] as? Int))
                                }
                                let (graphURL,graphHash,graphBytes) = try file("graph")
                                let (geometryURL,geometryHash,geometryBytes) = try file("geometry")
                                let (seamsURL,seamsHash,seamsBytes) = try file("seams")
                                identityRecord = ["manifest":manifest,"manifestSHA256":SHA256.hash(data:manifestData).map { String(format:"%02x",$0) }.joined(),
                                    "graphURL":graphURL.path,"geometryURL":geometryURL.path,
                                    "consumedFiles":"graph, geometry, seams; individually hash-verified by source-bound readers/preparation",
                                    "fuelFile":"not read; diagnostic has no fuel planning"]
                                try timed("verifySeamIdentity") {
                                    let source = try RoutingFilePages(url:seamsURL,limits:ExactSnapIndex.pageLimits)
                                    defer { source.close() }
                                    try #require(source.fileBytes == seamsBytes)
                                    let actualSeamHash = try ExactSnapIndex.digest(source,cancelled:cancelled)
                                    try #require(actualSeamHash == seamsHash)
                                    let data = try Data(contentsOf:seamsURL)
                                    let object = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
                                    let neighbors = try #require(object["neighbors"] as? [String:[[String:Any]]])
                                    try #require(neighbors["nb"]?.contains { $0["localEdgeId"] as? String == "149676172:1626240693:6952913085" } == true)
                                    try source.validate(cancelled:cancelled)
                                }
                                let idsURL = scratch.appendingPathComponent("original-ids.bin"), snapURL = scratch.appendingPathComponent("snap.bin")
                                let id = OriginalIDIndex.Identity(graphSHA256:graphHash,graphBytes:graphBytes)
                                try timed("originalIDPreparation") { try OriginalIDIndex.prepare(graphURL:graphURL,to:idsURL,identity:id,cancelled:cancelled) }
                                ids = try timed("originalIDOpenValidation") { try OriginalIDIndex(url:idsURL,graphURL:graphURL,identity:id,cancelled:cancelled) }
                                _ = try timed("exactSnapPreparation") {
                                    try ExactSnapIndexPreparation.prepare(graphURL:graphURL,geometryURL:geometryURL,destination:snapURL,
                                        identity:.init(graphSHA256:graphHash,graphBytes:graphBytes,geometrySHA256:geometryHash,geometryBytes:geometryBytes),cancelled:cancelled)
                                }
                                core = try timed("coreTopologyProof") { try PagedV4Core(url:graphURL,identity:.init(sha256:graphHash,bytes:graphBytes),cancelled:cancelled) }
                                let reader = try #require(core)
                                bundle = try timed("policyReadersAndIndexValidation") {
                                    let detail = try PagedEdgeDetail(url:graphURL,identity:.init(sha256:graphHash,bytes:graphBytes,edgeCount:reader.edgeCount),cancelled:cancelled)
                                    return try PagedConnectedCleanPolicyBundle(core:reader,details:detail,metadata:PagedV4PolicyMetadata(core:reader),
                                        geometryURL:geometryURL,geometryIdentity:.init(sha256:geometryHash,bytes:geometryBytes),snapIndexURL:snapURL)
                                }
                            } else {
                                let reader = try #require(core), index = try #require(ids), policy = try #require(bundle)
                                try index.validateSource(cancelled:cancelled)
                                try reader.withQuery(cancelled:cancelled) { query in try policy.withPolicy(query:query) { try $0.validate() } }
                            }
                        }
                    }
                    let reader = try #require(core), index = try #require(ids), policy = try #require(bundle)
                    // This is a separately reported recorded-node calculation window,
                    // not a hidden restart of the inclusive diagnostic/preparation clock.
                    try timed("calculationAndClosingValidation") {
                        try RoutingWorkContext.$deadline.withValue(RoutingWorkContext.limitedDeadline(milliseconds:18_000)) {
                            try reader.withQuery(cancelled:cancelled) { query in try reader.withLegalQuery(cancelled:cancelled) { legal in
                                let view = try ConnectedPackStageView(sources:[.init(region:"ns",core:reader,query:query,legal:legal,index:index)],
                                    boundaries:[],requiredRegions:["ns"])
                                let startMatch = try index.node(7411741589,cancelled:cancelled)
                                let endMatch = try index.node(6952913085,cancelled:cancelled)
                                let start = try #require(startMatch), end = try #require(endMatch)
                                func edge(way:Int64,from:Int64,to:Int64) throws -> Int {
                                    var found: [Int] = []
                                    try index.way(way,cancelled:cancelled) { value in
                                        let row = try query.edge(value)
                                        if try query.node(row.from).osmID == from && query.node(row.to).osmID == to { found.append(value) }
                                    }
                                    try #require(found.count == 1); return found[0]
                                }
                                let initial = try edge(way:792623056,from:7411741620,to:7411741589)
                                let destinationEdge = try edge(way:149676172,from:1626240693,to:6952913085)
                                var context = HopSearchContext.forProfile(.cleanest,seed:3511091208)
                                context.pavedOnly = true; context.avoidMotorways = true
                                try policy.withPolicy(query:query) { source in
                                    result = try ConnectedCleanStage.calculate(view:view,origin:.init(pack:0,node:start,matchedEdge:initial),
                                        destination:.init(pack:0,node:end,matchedEdge:destinationEdge),profile:.cleanest,maxMeters:207_000,
                                        context:context,ridePreferences:preferences,policySources:[source])
                                }
                            } }
                        }
                    }
                    outcome = result?.limitation.map { "legal-incumbent-limited:\($0)" } ?? "complete-first-clean-recorded-stage"
                } catch { result = nil; outcome = "unproved:\(error)" }
            }
            elapsed["inclusiveTotal"] = ProcessInfo.processInfo.systemUptime-started
            if let core {
                let q = core.queryStatistics,p = core.pageStatistics
                queryRows = ["nodes":q.nodes,"edges":q.edges,"arcs":q.arcs,"scalars":q.scalars,"borrows":q.borrowedPages]
                pages = ["peakLivePayloadBytes":p.peakLivePayloadBytes,"maximumLivePayloadBytes":p.maximumLivePayloadBytes]
            }
            let report = measurement.finish(outcome:outcome)
            var evidence: [String:Any] = ["measurement":try JSONSerialization.jsonObject(with:JSONEncoder().encode(report)),
                "identities":identityRecord,"elapsedSeconds":elapsed,"outcome":outcome,"run":run,
                "coreQueryCountersCumulativeSinceOpen":queryRows,"corePagePayload":pages]
            if let result {
                evidence["route"] = ["meters":result.meters,"cost":result.cost,"limitation":result.limitation as Any? ?? NSNull(),
                    "acceptedLabels":result.acceptedLabels,"poppedLabels":result.poppedLabels,"accountedPeakPayloadBytes":result.accountedPeakPayloadBytes,
                    "roads":result.roads.map { ["edge":$0.road.edge,"from":$0.from,"to":$0.to] },
                    "coordinates":result.coordinates.map { [$0.longitude,$0.latitude] }]
            }
            let output = fm.temporaryDirectory.appendingPathComponent("paged-connected-current-ns-run\(run).json")
            try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]).write(to:output)
            print("[paged-connected-current-ns] outcome=\(outcome) evidence=\(output.path)")
            if let result {
                #expect(result.meters <= 207_000)
                #expect(!result.roads.isEmpty && result.coordinates.count >= 2)
            } else { Issue.record("Recorded-node stage was not completed: \(outcome)") }
            // Retain failed preparation evidence rather than fabricate warm reuse.
            if bundle == nil { break }
        }
    }
}
