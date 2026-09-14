import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite(.serialized)
struct RegionalArrivalProbeTests {
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Measurement only. The full builder replay must independently qualify the
    /// legal continuation, real fuel distance, final destination and ride style.
    @MainActor @Test(arguments: [RouteProfile.dirt, .balanced]) func currentSeam6952913085PrefixAndTail(profile: RouteProfile) async throws {
        try await runCurrentSeam(profile: profile,reservePhysicalTail: false)
    }
    @MainActor @Test(arguments: [RouteProfile.dirt, .balanced]) func currentSeam6952913085PhysicalTailReservation(profile: RouteProfile) async throws {
        try await runCurrentSeam(profile: profile,reservePhysicalTail: true)
    }
    private struct CallEvidence: Encodable, Sendable {
        let purpose: String
        let from: RouteCoordinate
        let to: RouteCoordinate
        let cap: Double
        let arrival: NativeRoutingContinuation?
        let priorEdgeIDs: [String]
        let ownerPrefix: OwningRideSurfacePrefix
        let physicalObjective: Bool
        let ignoresRecreationalPreferences: Bool
        let region: String
        let startEndpointKind: String?
        let endEndpointKind: String?
        let recordedNodeID: Int64
        let response: RouteResponse?
        let failure: String?
    }
    private struct CallObservation: Sendable {
        let purpose: String
        let from: RouteCoordinate
        let to: RouteCoordinate
        let cap: Double
        let arrival: NativeRoutingContinuation?
        let priorEdgeIDs: [String]
        let ownerPrefix: OwningRideSurfacePrefix
        let physicalObjective: Bool
        let ignoresRecreationalPreferences: Bool
        let region: String
        let startEndpointKind: String?
        let endEndpointKind: String?
        let recordedNodeID: Int64
        let response: OnDeviceRouter.Result?
        let failure: String?
    }
    private struct Calculation: Sendable {
        let prefix: Swift.Result<OnDeviceRouter.Result,OnDeviceRouter.Failure>
        let tail: Swift.Result<OnDeviceRouter.Result,OnDeviceRouter.Failure>?
        let calls: [CallObservation]
        let reservationMeters: Double?
    }
    @MainActor private func runCurrentSeam(profile: RouteProfile,reservePhysicalTail: Bool) async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DIRT_CURRENT_PACK_ROOT"]
            ?? "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs")
        let fm = FileManager.default, release = "fabric-v4-20260909-02"
        let temp = fm.temporaryDirectory.appendingPathComponent("recorded-tail-"+UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        var verifiedManifestHashes: [String:String] = [:]
        var snapshots: [[String: [GraphV2Pack.CrossPackSeamAnchor]]] = [], seamData: [Data] = []
        for region in ["ns","nb"] {
            let source = root.appendingPathComponent(region), target = temp.appendingPathComponent(release+"/"+region)
            let manifestData = try Data(contentsOf: source.appendingPathComponent("pack-manifest.v2.json"))
            verifiedManifestHashes[region] = try digest(source.appendingPathComponent("pack-manifest.v2.json"))
            let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
            try #require(manifest["fabricReleaseId"] as? String == release && manifest["regionId"] as? String == region)
            try fm.createDirectory(at: target,withIntermediateDirectories: true)
            for key in ["graph","geometry","fuel","seams"] {
                let entry = try #require(manifest[key] as? [String:Any]), name = try #require(entry["name"] as? String)
                try #require(!name.contains("/") && name != "..")
                let original = source.appendingPathComponent(name)
                try #require(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize == entry["bytes"] as? Int)
                try #require(try digest(original) == entry["sha256"] as? String)
                let copy = target.appendingPathComponent(name); try fm.copyItem(at: original,to: copy)
                try #require(try digest(copy) == entry["sha256"] as? String)
                if key == "seams" { seamData.append(try Data(contentsOf: copy)) }
            }
            try manifestData.write(to: target.appendingPathComponent("pack-manifest.v2.json"))
        }
        let store = GraphPackStore(cacheRoot: temp,refreshCatalogOnInit: false)
        var packs: [GraphV2Pack] = []
        let initial = CLLocationCoordinate2D(latitude: 44.744229,longitude: -63.284939)
        let pump = CLLocationCoordinate2D(latitude: 45.870167,longitude: -64.279432)
        for (index,point) in [initial,CLLocationCoordinate2D(latitude: 46.0878,longitude: -64.7782)].enumerated() {
            await store.warmupActivePack(near: point)
            let pack = try #require(store.activePack)
            try #require(pack.regionId == ["ns","nb"][index])
            packs.append(pack);snapshots.append(try pack.decodedCrossPackSeams(data: seamData[index]))
        }
        let anchors = (snapshots[0]["nb"] ?? []).filter { $0.osmNodeId == 6952913085 }
        let reverse = (snapshots[1]["ns"] ?? []).filter { $0.osmNodeId == 6952913085 }
        let pairs = try ExactGuidanceSeams.connections(local: packs[0],remote: packs[1],anchors: anchors,reverse: reverse)
        let pair = try #require(pairs.first)
        try #require(pairs.allSatisfy { $0 == pair })
        let seam = CLLocationCoordinate2D(latitude: Double(packs[0].nodeCoords[pair.localNode*2+1]),
            longitude: Double(packs[0].nodeCoords[pair.localNode*2]))
        let arrival = NativeRoutingContinuation(version: 1,sourceEpoch: "geofabrik-capture-20260907T123015Z",
            incoming: .init(wayID: 792623056,fromNodeID: 7411741620,toNodeID: 7411741589),
            location: .edge(fraction: 0.5343070706667112),restrictionContext: [],activeRestrictions: [])
        let owner = OwningRideSurfacePrefix(riderLegID: UUID(uuidString: "0B0AFAE9-831F-509B-BB1A-3916A3FFDFE3")!)
        let preferences = RidePreferences(preferDifferentRoads: true,wander: 1,avoidCities: true,avoidHighways: false)
        let prepared = packs
        let measurement = RoutingMeasurement(metadata: ["case":"seam6952913085-initial-to-NB-pump", "release":release,"profile":"\(profile)","qualification":"diagnostic-only","reservation": reservePhysicalTail ? "native-physical-tail" : "none"])
        var prefixResponse: RouteResponse?,tailResponse: RouteResponse?
        var outcome = "unattempted"
        var calls: [CallEvidence] = []
        var reservationMeters: Double?
        try await RoutingWorkContext.$measurement.withValue(measurement) {
            let results = await RoutingWorkContext.detachedSearch {
                RoutingWorkContext.$deadline.withValue(RoutingWorkContext.limitedDeadline(milliseconds: 20_000)) {
                    var router = OnDeviceRouter(pack: prepared[0])
                    router.ridePreferences = preferences
                    router.mapZoom = 7.9;router.recordedEndNode = pair.localNode
                    router.owningRideSurfacePrefix = owner
                    router.startEndpointKind = "customers"
                    var calls: [CallObservation] = []
                    func record(_ purpose: String,_ value: Swift.Result<OnDeviceRouter.Result,OnDeviceRouter.Failure>,
                        from: CLLocationCoordinate2D,to: CLLocationCoordinate2D,cap: Double,
                        token: NativeRoutingContinuation?,history: Set<String>,prefix: OwningRideSurfacePrefix,
                        physical: Bool) {
                        let response: OnDeviceRouter.Result?,failure: String?
                        switch value {
                        case .success(let route): response = route;failure = nil
                        case .failure(let reason): response = nil;failure = String(describing: reason)
                        }
                        calls.append(.init(purpose: purpose,
                            from: .init(longitude: from.longitude,latitude: from.latitude),
                            to: .init(longitude: to.longitude,latitude: to.latitude),cap: cap,arrival: token,
                            priorEdgeIDs: history.sorted(),ownerPrefix: prefix,physicalObjective: physical,ignoresRecreationalPreferences: physical,
                            region: purpose.hasSuffix("prefix") ? "ns" : "nb",
                            startEndpointKind: purpose.hasSuffix("prefix") ? "customers" : nil,
                            endEndpointKind: purpose.hasSuffix("prefix") ? nil : "customers",
                            recordedNodeID: 6952913085,response: response,failure: failure))
                    }
                    func prefixRoute(cap: Double,purpose: String) -> Swift.Result<OnDeviceRouter.Result,OnDeviceRouter.Failure> {
                        let value = router.routeDetailed(from: initial,to: seam,profile: profile,allowUnknown: false,
                            arrivalEdgeId: "w792623056:135070:135061",arrivalContinuation: arrival,
                            sessionSeed: 3511091208,maxRouteMeters: cap,avoidMotorways: false)
                        record(purpose,value,from: initial,to: seam,cap: cap,token: arrival,history: [],prefix: owner,physical: false)
                        return value
                    }
                    func tailRoute(prefix route: OnDeviceRouter.Result,cap: Double,physical: Bool,
                        purpose: String) -> Swift.Result<OnDeviceRouter.Result,OnDeviceRouter.Failure> {
                        guard let token = route.terminalContinuation else { return .failure(.searchLimit("missingArrival")) }
                        let canonical = Set(route.edgeIds.compactMap { prepared[0].canonicalRoadID($0) })
                        let translated = prepared[1].localRoadIDs(matching: canonical)
                        let canonicalArrival = route.edgeIds.reversed().compactMap { prepared[0].canonicalRoadID($0) }.first
                        let localArrival = canonicalArrival.flatMap { prepared[1].localRoadIDs(matching: [$0]).first }
                        var tail = OnDeviceRouter(pack: prepared[1])
                        tail.ridePreferences = preferences
                        tail.mapZoom = 7.9;tail.recordedStartNode = pair.remoteNode;tail.endEndpointKind = "customers"
                        tail.owningRideSurfacePrefix = owner.appending(route.localSurfaceContribution)
                        // Diagnostic reservation proof only; never a returned ride leg.
                        // Existing physical-distance mode preserves legal arrival/access,
                        // but omits recreational walls/preferences. Its result is
                        // only a trial reservation; final prefix/tail use normal style.
                        tail.initialFuelApproach = physical
                        let value = tail.routeDetailed(from: seam,to: pump,profile: profile,allowUnknown: false,
                            priorEdgeIds: translated,arrivalEdgeId: localArrival,arrivalContinuation: token,
                            sessionSeed: 3511091208,maxRouteMeters: cap,avoidMotorways: false)
                        record(purpose,value,from: seam,to: pump,cap: cap,token: token,history: translated,
                            prefix: owner.appending(route.localSurfaceContribution),physical: physical)
                        return value
                    }
                    let first = prefixRoute(cap: 207_000,purpose: "initial-selected-prefix")
                    guard case .success(let original) = first, original.terminalContinuation != nil else {
                        return Calculation(prefix: first,tail: nil,calls: calls,reservationMeters: nil)
                    }
                    var selected = original
                    var reservation: Double?
                    if reservePhysicalTail {
                        let proof = tailRoute(prefix: original,cap: 207_000,physical: true,purpose: "uncommitted-physical-tail-reservation")
                        guard case .success(let physical) = proof,
                              !physical.searchMeta.timedOut, physical.distanceMeters.isFinite,
                              physical.distanceMeters > 0,physical.distanceMeters < 207_000 else {
                            return Calculation(prefix: first,tail: .failure(.searchLimit("physicalReservationUnproved")),
                                calls: calls,reservationMeters: nil)
                        }
                        reservation = physical.distanceMeters
                        let rerouted = prefixRoute(cap: 207_000-physical.distanceMeters,purpose: "reserved-selected-prefix")
                        guard case .success(let replacement) = rerouted,replacement.terminalContinuation != nil else {
                            return Calculation(prefix: rerouted,tail: nil,calls: calls,reservationMeters: reservation)
                        }
                        selected = replacement
                    }
                    // Always prove selected-style continuation from NEW actual
                    // arrival and actual remaining distance; never reuse the probe.
                    let tail = tailRoute(prefix: selected,cap: max(0,207_000-selected.distanceMeters),
                        physical: false,purpose: "actual-selected-tail")
                    return Calculation(prefix: .success(selected),tail: tail,calls: calls,reservationMeters: reservation)
                }
            }
            calls = results.calls.map { call in
                CallEvidence(purpose: call.purpose,from: call.from,to: call.to,cap: call.cap,
                    arrival: call.arrival,priorEdgeIDs: call.priorEdgeIDs,ownerPrefix: call.ownerPrefix,
                    physicalObjective: call.physicalObjective,ignoresRecreationalPreferences: call.ignoresRecreationalPreferences,
                    region: call.region,startEndpointKind: call.startEndpointKind,endEndpointKind: call.endEndpointKind,
                    recordedNodeID: call.recordedNodeID,response: call.response.map { RouteResponse(onDevice: $0,priorEdgeIDs: Set(call.priorEdgeIDs)) },
                    failure: call.failure)
            }
            reservationMeters = results.reservationMeters
            if case .success(let prefix) = results.prefix {
                prefixResponse = RouteResponse(onDevice: prefix,priorEdgeIDs: [])
                #expect(prefix.distanceMeters <= 207_001)
                if let tail = results.tail {
                    switch tail {
                    case .success(let route):
                        tailResponse = RouteResponse(onDevice: route,priorEdgeIDs: [])
                        #expect(prefix.distanceMeters+route.distanceMeters <= 207_001)
                        outcome = prefix.searchMeta.timedOut || route.searchMeta.timedOut
                            ? "legal-stage-complete-style-search-incomplete" : "complete-native-stage"
                    case .failure(let failure):outcome = "tail-unproved:\(failure)"
                    }
                } else { outcome = "prefix-missing-legal-token" }
            } else if case .failure(let failure) = results.prefix { outcome = "prefix-unproved:\(failure)" }
        }
        let snapshot = measurement.finish(outcome: outcome)
        struct Evidence: Encodable {
            let manifestSHA256: [String:String]
            let preferences: RidePreferences
            let initialArrival: NativeRoutingContinuation
            let seed: UInt64
            let usableMeters: Double
            let outcome: String
            let reservationMeters: Double?
            let calls: [CallEvidence]
            let mapZoom: Double
            let allowUnknown: Bool
            let diagnosticWindowMilliseconds: Int
            let prefix: RouteResponse?
            let tail: RouteResponse?
        }
        let artifact = fm.temporaryDirectory.appendingPathComponent("regional-arrival-6952913085-\(profile)-\(reservePhysicalTail ? "reserved" : "baseline").json")
        try JSONEncoder().encode(Evidence(manifestSHA256: verifiedManifestHashes,preferences: preferences,initialArrival: arrival,seed: 3511091208,usableMeters: 207_000,outcome: outcome,reservationMeters: reservationMeters,calls: calls,mapZoom: 7.9,allowUnknown: false,diagnosticWindowMilliseconds: 20_000,prefix: prefixResponse,tail: tailResponse)).write(to: artifact)
        try JSONEncoder().encode(snapshot).write(to: artifact.deletingPathExtension().appendingPathExtension("measurement.json"))
        print("[regional-arrival-probe] profile=\(profile) outcome=\(outcome) evidence=\(artifact.path)")
    }
}
