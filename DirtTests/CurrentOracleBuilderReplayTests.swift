import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

/// Current native builder qualification of the complete six-case oracle matrix.
/// Fixture acquisition is preinstallation, not a test of the download UI.
@Suite("Current oracle through native itinerary builder", .serialized)
struct CurrentOracleBuilderReplayTests {
    private let release = "fabric-v4-20260909-02"
    private var packRoot: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["DIRT_CURRENT_PACK_ROOT"]
            ?? "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs")
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private struct Oracle: Decodable {
        struct Scenario: Decodable {
            struct Point: Decodable { let lat: Double; let lon: Double }
            let id: String; let label: String; let from: Point; let to: Point
        }
        let schemaVersion: Int; let sessionSeed: UInt64
        let tankRangeKm: Int; let reservePercent: Int
        let profiles: [String]; let scenarios: [Scenario]
    }
    @MainActor
    private final class SeededSource: RoutingSource {
        let base: PackRoutingSource
        let seed: UInt64
        var name: String { base.name }
        var supportsCombinedFuelPlanning: Bool { base.supportsCombinedFuelPlanning }
        var calls: [[String: Any]] = []
        var routeRequests: [RouteRequest] = []
        var fuelRequests: [FuelChainRequest] = []
        init(base: PackRoutingSource,seed: UInt64) { self.base=base;self.seed=seed }
        private func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        /// Preserve every encoded request field, including legal continuation,
        /// regional intent and fuel state; replace only the oracle base seed.
        private func seeded<T: Codable>(_ original: T) throws -> T {
            guard var value=try object(original) as? [String: Any] else { throw AdapterError.encoding }
            var options=value["options"] as? [String: Any] ?? [:]
            options["sessionSeed"]=seed
            value["options"]=options
            return try JSONDecoder().decode(T.self,from: JSONSerialization.data(withJSONObject: value))
        }
        func route(_ req: RouteRequest) async throws -> RouteResponse {
            let effective=try seeded(req)
            routeRequests.append(effective)
            let start=ProcessInfo.processInfo.systemUptime
            var record: [String: Any]=["operation":"route","original":try object(req),"effective":try object(effective)]
            defer { record["seconds"]=ProcessInfo.processInfo.systemUptime-start;calls.append(record) }
            do { let result=try await base.route(effective);record["response"]=try object(result);return result }
            catch { record["error"]=String(describing:error);throw error }
        }
        func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
            let effective=try seeded(req)
            fuelRequests.append(effective)
            let start=ProcessInfo.processInfo.systemUptime
            var record: [String: Any]=["operation":"fuelChain","original":try object(req),"effective":try object(effective)]
            defer { record["seconds"]=ProcessInfo.processInfo.systemUptime-start;calls.append(record) }
            do { let result=try await base.fuelChain(effective);record["response"]=try object(result);return result }
            catch { record["error"]=String(describing:error);throw error }
        }
        func verifiedInitialFuelStation(at point: RouteCoordinate,profile: RouteProfile,allowUnknown: Bool) async throws -> FuelChainStop? {
            let start=ProcessInfo.processInfo.systemUptime
            var record: [String: Any]=["operation":"verifiedInitialFuelStation","point":try object(point),"profile":profile.rawValue,"allowUnknown":allowUnknown]
            defer { record["seconds"]=ProcessInfo.processInfo.systemUptime-start;calls.append(record) }
            do { let result=try await base.verifiedInitialFuelStation(at:point,profile:profile,allowUnknown:allowUnknown);record["response"]=try result.map { try object($0) } ?? NSNull();return result }
            catch { record["error"]=String(describing:error);throw error }
        }
        func fuelStation(near point: RouteCoordinate,within meters: Double) async throws -> FuelChainStop? {
            let start=ProcessInfo.processInfo.systemUptime
            var record: [String: Any]=["operation":"fuelStation","point":try object(point),"withinMeters":meters]
            defer { record["seconds"]=ProcessInfo.processInfo.systemUptime-start;calls.append(record) }
            do { let result=try await base.fuelStation(near:point,within:meters);record["response"]=try result.map { try object($0) } ?? NSNull();return result }
            catch { record["error"]=String(describing:error);throw error }
        }
        private enum AdapterError: Error { case encoding }
    }
    @Test("All six exact cases, all oracle profiles, fuel off/on, first/repeated requests")
    @MainActor
    func allCurrentOracleBuilderWorkflows() async throws {
        _ = try await runCurrentOracleBuilderWorkflows()
    }

    @Test @MainActor
    func crossProvinceCleanFuelCurrentColdWarm() async throws {
        _ = try await runCurrentOracleBuilderWorkflows(onlyScenario: "cross-province",
            onlyProfile: "cleanest", onlyFuel: true, evidenceVariant: "exact-seams")
    }

    @Test @MainActor
    func crossProvinceBalancedFuelCurrentColdWarm() async throws {
        _ = try await runCurrentOracleBuilderWorkflows(onlyScenario: "cross-province",
            onlyProfile: "balanced", onlyFuel: true, evidenceVariant: "exact-seams")
    }

    @Test @MainActor
    func crossProvinceDirtFuelCurrentColdWarm() async throws {
        _ = try await runCurrentOracleBuilderWorkflows(onlyScenario: "cross-province",
            onlyProfile: "dirt", onlyFuel: true, evidenceVariant: "exact-seams")
    }

    @Test @MainActor
    func crossProvinceCleanFuelEnvelopeColdWarmAB() async throws {
        try await crossProvinceEnvelopeComparison(profile: "cleanest")
    }
    @Test @MainActor
    func crossProvinceBalancedFuelEnvelopeColdWarmAB() async throws {
        try await crossProvinceEnvelopeComparison(profile: "balanced")
    }
    @Test @MainActor
    func crossProvinceDirtFuelEnvelopeColdWarmAB() async throws {
        try await crossProvinceEnvelopeComparison(profile: "dirt")
    }

    @MainActor
    private func crossProvinceEnvelopeComparison(profile: String) async throws {
        let disabled = try await RoutingWorkContext.$usePackGeometryEnvelope.withValue(false) {
            try await runCurrentOracleBuilderWorkflows(onlyScenario: "cross-province",
                onlyProfile: profile, onlyFuel: true, evidenceVariant: "envelope-off")
        }
        let enabled = try await RoutingWorkContext.$usePackGeometryEnvelope.withValue(true) {
            try await runCurrentOracleBuilderWorkflows(onlyScenario: "cross-province",
                onlyProfile: profile, onlyFuel: true, evidenceVariant: "envelope-on")
        }
        try #require(disabled.count == 2 && enabled.count == 2)
        // A fixed optimization can complete a ride whose baseline timed out.
        // Failed baselines still fail their mandatory per-run qualifications;
        // only genuinely successful outputs have a meaningful shape comparison.
        let successes = (disabled + enabled).filter(\.complete)
        if let reference = successes.first {
            for result in successes.dropFirst() { #expect(result.routeDigest == reference.routeDigest) }
        }
    }

    private struct ReplayDigest {
        let complete: Bool
        let routeDigest: String
    }
    private struct StageDigest: Encodable {
        let coordinates: [RouteCoordinate]
        let meters: Double?
        let dirtPercent: Int?
        let stop: String?
        let initialFillUp: Bool
        let resetsTank: Bool
    }
    /// Called after measurement.finish; retain no full itinerary between runs.
    private func compactDigest(_ result: BuiltItinerary, legID: UUID,
        destination: RouteCoordinate) throws -> ReplayDigest {
        let stages = result.legs.map { stage in StageDigest(
            coordinates: stage.response.coordinates, meters: stage.response.distanceMeters,
            dirtPercent: stage.response.stats?.dirtPercent, stop: stage.endsAtFuelStop?.stationID,
            initialFillUp: stage.endsAtFuelStop?.isInitialFillUp == true,
            resetsTank: stage.endsAtFuelStop?.resetsTank == true) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hash = SHA256.hash(data: try encoder.encode(stages)).map { String(format: "%02x", $0) }.joined()
        return .init(complete: result.riderLegStatus[legID] == .built
            && result.legs.last?.toCoordinate == destination, routeDigest: hash)
    }

    private func verifyRoutedFuelAccounting(_ result: BuiltItinerary,
        itinerary: RiderItinerary, usableMeters: Double) throws {
        var used = 0.0
        for (index, stage) in result.legs.enumerated() {
            let meters = try #require(stage.response.distanceMeters)
            #expect(meters.isFinite && meters >= 0)
            let arrived = used + meters
            #expect(arrived <= usableMeters + 1, "Charge actual stage, including station approaches and regional tails")
            if stage.endsAtFuelStop?.isInitialFillUp == true {
                #expect(index == 0)
                // The initial mapped-station approach is not a recreational
                // stage: no minimum progress, length or repeated-road assertion.
            }
            let waypoint = itinerary.waypoints.first { $0.coordinate == stage.toCoordinate }
            let waypointRefill = waypoint.flatMap { result.waypointFuelStops[$0.id] }?.resetsTank == true
            used = stage.endsAtFuelStop?.resetsTank == true || waypointRefill ? 0 : arrived
            #expect(abs(stage.fuelUsedOnArrivalMeters - used) <= 1,
                "Only a recorded refill resets carried fuel; borders/rider pins do not")
        }
    }

    @MainActor
    private func runCurrentOracleBuilderWorkflows(onlyScenario: String? = nil,
        onlyProfile: String? = nil, onlyFuel: Bool? = nil,
        evidenceVariant: String? = nil) async throws -> [ReplayDigest] {
        var completed: [ReplayDigest] = []
        let casesURL=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/pack-fabric/bench/routing-oracle-cases.json")
        let oracleData=try Data(contentsOf: casesURL)
        let oracle=try JSONDecoder().decode(Oracle.self,from:oracleData)
        try #require(oracle.schemaVersion == 1 && oracle.scenarios.count == 6)
        try #require(oracle.sessionSeed == 3511091208 && oracle.tankRangeKm == 230 && oracle.reservePercent == 10)
        try #require(Set(oracle.scenarios.map(\.id)) == Set(["short-intra-metro","rural-pair","cross-province","one-fuel-stop","multi-fuel-stop","canso-causeway"]))
        try #require(oracle.profiles == ["cleanest","balanced","dirt"])
        let fm=FileManager.default
        let temp=fm.temporaryDirectory.appendingPathComponent("current-oracle-builder-packs-"+UUID().uuidString)
        defer { try? fm.removeItem(at:temp) }
        var identities: [String: Any]=[:]
        var diskBytes=0
        for region in ["ns","nb"] {
            let source=packRoot.appendingPathComponent(region)
            let manifestData=try Data(contentsOf:source.appendingPathComponent("pack-manifest.v2.json"))
            let manifest=try #require(JSONSerialization.jsonObject(with:manifestData) as? [String:Any])
            try #require(manifest["fabricReleaseId"] as? String == release)
            try #require(manifest["regionId"] as? String == region)
            let destination=temp.appendingPathComponent(release+"/"+region)
            try fm.createDirectory(at:destination,withIntermediateDirectories:true)
            for key in ["graph","geometry","fuel","seams"] {
                let file=try #require(manifest[key] as? [String:Any])
                let filename=try #require(file["name"] as? String)
                try #require(!filename.contains("/") && filename != "..")
                let expectedBytes=try #require(file["bytes"] as? Int)
                let url=source.appendingPathComponent(filename)
                try #require(try url.resourceValues(forKeys:[.fileSizeKey]).fileSize == expectedBytes)
                try #require(try digest(url) == file["sha256"] as? String)
                diskBytes += expectedBytes
                let copy=destination.appendingPathComponent(filename)
                try fm.copyItem(at:url,to:copy)
                try #require(try digest(copy) == file["sha256"] as? String)
            }
            try manifestData.write(to:destination.appendingPathComponent("pack-manifest.v2.json"))
            identities[region]=manifest
        }
        let store=GraphPackStore(cacheRoot:temp,refreshCatalogOnInit:false)
        let tank=Double(oracle.tankRangeKm)*1000
        let usable=tank*(1-Double(oracle.reservePercent)/100)
        var runOrdinal=0
        let scenarios = oracle.scenarios.filter { onlyScenario == nil || $0.id == onlyScenario }
        let profiles = oracle.profiles.filter { onlyProfile == nil || $0 == onlyProfile }
        let fuelModes = ([false,true] as [Bool]).filter { onlyFuel == nil || $0 == onlyFuel }
        try #require(!scenarios.isEmpty && !profiles.isEmpty && !fuelModes.isEmpty)
        for scenario in scenarios {
            let from=RouteCoordinate(longitude:scenario.from.lon,latitude:scenario.from.lat)
            let to=RouteCoordinate(longitude:scenario.to.lon,latitude:scenario.to.lat)
            for rawProfile in profiles {
                let profile=try #require(RouteProfile(rawValue:rawProfile))
                for fuel in fuelModes {
                    let adapter=SeededSource(base:PackRoutingSource(packs:store,cache:RouteResponseCache()),seed:oracle.sessionSeed)
                    let a=RiderWaypoint(id:UUID(uuidString:"A0000000-0000-0000-0000-000000000001")!,coordinate:from)
                    let b=RiderWaypoint(id:UUID(uuidString:"B0000000-0000-0000-0000-000000000002")!,coordinate:to)
                    let leg=RiderLeg(from:a.id,to:b.id,profile:profile,allowUnknown:false,avoidMotorways:profile == .cleanest)
                    let itinerary=RiderItinerary(waypoints:[a,b],legs:[leg],generation:1,impassableEdgeIDs:[])
                    let preferences=RidePreferences(preferDifferentRoads:true,wander:1,avoidCities:true,avoidHighways:profile == .cleanest)
                    for run in 0..<2 {
                        adapter.calls=[];adapter.routeRequests=[];adapter.fuelRequests=[]
                        let builder=ItineraryBuilder();builder.mapZoom=7.9
                        let began=ProcessInfo.processInfo.systemUptime
                        var fuelProgress: [[String:Any]]=[],displayProgress: [[String:Any]]=[]
                        let preparation=runOrdinal == 0 ? "first store use; files preinstalled, graph/index/cache cold" :
                            (run == 1 ? "same request repeated; shared store and response cache" : "new workload; shared store, new response cache")
                        let measurement=RoutingMeasurement(metadata:["workload":scenario.id,"packRelease":release,
                            "sourceIdentity":ProcessInfo.processInfo.environment["DIRT_SOURCE_ID"] ?? "not provided; record compiled source externally",
                            "appVersion":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                            "appBuild":Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                            "hardware":ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown",
                            "OS":ProcessInfo.processInfo.operatingSystemVersionString,"execution":"ItineraryBuilder / test seed forwarding adapter / PackRoutingSource / GraphPackStore",
                            "preparation":preparation,"packGeometryEnvelope":String(RoutingWorkContext.usePackGeometryEnvelope),
                            "seed":String(oracle.sessionSeed),"riderLegUnadaptedSeed":String(leg.routingSessionSeed),
                            "profile":profile.rawValue,"fuel":String(fuel),"tankMeters":String(tank),"reservePercent":String(oracle.reservePercent),"allowUnknown":"false"])
                        let result=await RoutingWorkContext.$measurement.withValue(measurement) {
                            await RidePreferenceContext.$current.withValue(preferences) {
                                await builder.build(itinerary,from:0,reuse:nil,
                                    fuel:.init(tankMeters:tank,usableMeters:usable,reservePercent:Double(oracle.reservePercent),automaticPlanningEnabled:fuel),
                                    source:.fixed(adapter),onFuelStatus:{ value in
                                        fuelProgress.append(["seconds":ProcessInfo.processInfo.systemUptime-began,"status":value])
                                    },onProgress:{ value in
                                        displayProgress.append(["seconds":ProcessInfo.processInfo.systemUptime-began,"legs":value.legs.count,
                                            "status":String(describing:value.riderLegStatus),"reached":value.legs.last.map { [$0.toCoordinate.longitude,$0.toCoordinate.latitude] } ?? []])
                                    })
                            }
                        }
                        let report = measurement.finish(outcome:String(describing:result.riderLegStatus))
                        if evidenceVariant != nil {
                            let rejected = report.counters["snapEnvelopeRejectedQueries"] ?? 0
                            if !RoutingWorkContext.usePackGeometryEnvelope { #expect(rejected == 0) }
                            else if run == 0 { #expect(rejected > 0, "Cold cross-pack replay must exercise the new envelope") }
                        }
                        let evidence: [String:Any]=["case":scenario.id,"label":scenario.label,"oracleSHA256":SHA256.hash(data:oracleData).map { String(format:"%02x",$0) }.joined(),
                            "packManifests":identities,"installedDiskBytes":diskBytes,"itinerary":try object(itinerary),"preferences":try object(preferences),"mapZoom":7.9,
                            "seedAdapter":"Only options.sessionSeed changed to oracle seed. All original/effective builder-to-source calls recorded; internal pack-source subsearches remain production behavior.",
                            "fuelEnabled":fuel,"tankMeters":tank,"usableMeters":usable,"reservePercent":oracle.reservePercent,
                            "measurement":try object(report),
                            "builtItinerary":try object(result),"calls":adapter.calls,"fuelProgress":fuelProgress,"displayProgress":displayProgress,"status":String(describing:result.riderLegStatus),
                            "routes":try result.legs.map { try object($0.response) },"stops":result.legs.compactMap { $0.endsAtFuelStop?.stationID },
                            "requestedDestination":[to.longitude,to.latitude],"reached":result.legs.last.map { [$0.toCoordinate.longitude,$0.toCoordinate.latitude] } ?? []]
                        let dir=fm.temporaryDirectory.appendingPathComponent(evidenceVariant.map {
                            "cross-province-envelope-replay/" + $0
                        } ?? "current-oracle-builder-replay")
                        try fm.createDirectory(at:dir,withIntermediateDirectories:true)
                        let url=dir.appendingPathComponent("\(scenario.id)-\(profile.rawValue)-fuel\(fuel)-run\(run).json")
                        try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]).write(to:url)
                        print("[current-oracle-builder] evidence=\(url.path)")
                        try Task.checkCancellation()
                        #expect(adapter.routeRequests.allSatisfy { $0.options?.sessionSeed == oracle.sessionSeed })
                        #expect(adapter.fuelRequests.allSatisfy { $0.options?.sessionSeed == oracle.sessionSeed })
                        #expect(result.legs.last?.toCoordinate == to)
                        #expect(result.riderLegStatus[leg.id] == .built)
                        if fuel { #expect(result.legs.first?.endsAtFuelStop != nil) }
                        else { #expect(result.legs.allSatisfy { $0.endsAtFuelStop == nil });#expect(adapter.fuelRequests.isEmpty) }
                        if evidenceVariant != nil {
                            if fuel { try verifyRoutedFuelAccounting(result, itinerary: itinerary, usableMeters: usable) }
                            completed.append(try compactDigest(result, legID: leg.id, destination: to))
                        }
                        runOrdinal += 1
                    }
                }
            }
        }
        #expect(runOrdinal == scenarios.count * profiles.count * fuelModes.count * 2)
        if onlyScenario == nil && onlyProfile == nil && onlyFuel == nil { #expect(runOrdinal == 72) }
        return completed
    }
}
