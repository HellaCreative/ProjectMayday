import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

/// Development-only replay of the accepted pack contract. This deliberately
/// calls the real production-foundation native router. Historical pack identity
/// remains explicit; this is comparison evidence, not product qualification.
@Suite("Accepted V4 on-device replay", .serialized)
struct OnDevicePackBenchmarkTests {
    private var root: URL {
        if let value = ProcessInfo.processInfo.environment["DIRT_PACK_ROOT"] {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260908-02/packs", isDirectory: true)
    }


    @discardableResult
    private func verifyPack(_ region: String, packRoot: URL? = nil, version: String = "fabric-v4-20260908-02") throws -> [String: Any] {
        let dir = (packRoot ?? root).appendingPathComponent(region)
        let manifestData = try Data(contentsOf: dir.appendingPathComponent("pack-manifest.v2.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        try #require(manifest["fabricReleaseId"] as? String == version)
        try #require(manifest["regionId"] as? String == region)
        var files: [String: Any] = [:]
        for key in ["graph", "geometry", "fuel", "seams"] {
            let file = try #require(manifest[key] as? [String: Any])
            let name = try #require(file["name"] as? String)
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try #require(data.count == file["bytes"] as? Int)
            try #require(hash == file["sha256"] as? String)
            files[key] = ["name": name, "bytes": data.count, "sha256": hash]
        }
        return ["regionId": region, "fabricReleaseId": version,
            "sourceEpoch": manifest["sourceEpoch"] ?? NSNull(),
            "schema": manifest["schema"] ?? NSNull(), "files": files,
            "manifest": ["name": "pack-manifest.v2.json", "bytes": manifestData.count,
                "sha256": SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()]]
    }

    @MainActor
    private func fixtureStore(packRoot: URL? = nil, version: String = "fabric-v4-20260908-02", regions: [String] = ["ns", "nb"]) throws -> (GraphPackStore, URL, [String: Any]) {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("recovery-packs-\(UUID())")
        var verifiedIdentities: [String: Any] = [:]
        do {
            for region in regions {
                let sourceIdentity = try verifyPack(region, packRoot: packRoot, version: version)
                let destination = temp.appendingPathComponent("\(version)/\(region)")
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for name in ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "cross-pack-seams.v2.json", "pack-manifest.v2.json"] {
                    try fm.copyItem(at: (packRoot ?? root).appendingPathComponent("\(region)/\(name)"), to: destination.appendingPathComponent(name))
                }
                // Verify the bytes the native store will actually open, not only
                // their source. Manifest identity also detects a changed copy.
                let copiedIdentity = try verifyPack(region,
                    packRoot: temp.appendingPathComponent(version), version: version)
                let sourceRecord = try JSONSerialization.data(withJSONObject: sourceIdentity, options: [.sortedKeys])
                let copiedRecord = try JSONSerialization.data(withJSONObject: copiedIdentity, options: [.sortedKeys])
                try #require(sourceRecord == copiedRecord)
                verifiedIdentities[region] = copiedIdentity
            }
            return (GraphPackStore(cacheRoot: temp, refreshCatalogOnInit: false), temp,
                ["verification": "source and copied fixture bytes SHA-256 checked before calculation",
                 "regions": verifiedIdentities])
        } catch { try? fm.removeItem(at: temp); throw error }
    }

    private func saveEvidence(_ value: [String: Any], name: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-recovery-20260913")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: dir.appendingPathComponent(name + ".json"))
        print("[accepted-replay] evidence=\(dir.path)/\(name).json")
    }

    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func loadPack(_ region: String) throws -> GraphV2Pack {
        try verifyPack(region)
        let dir = root.appendingPathComponent(region, isDirectory: true)
        let pack = try GraphV2Pack(data: Data(contentsOf: dir.appendingPathComponent("graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: dir.appendingPathComponent("geometry.v1.bin")))
        try pack.applyCrossPackSeams(data: Data(contentsOf: dir.appendingPathComponent("cross-pack-seams.v2.json")))
        let leafCount = (0..<pack.undirectedEdgeCount).reduce(into: 0) { count, edge in
            if pack.surfaceLeaf(edge) != nil { count += 1 }
        }
        print("[accepted-replay] pack region=\(region) version=\(pack.version) leaves=\(pack.hasLeaves) surfaces=\(pack.surfaceLeafNames.count) mappedFamilies=\(pack.surfaceFamilyMap.count) taggedEdges=\(leafCount) edges=\(pack.undirectedEdgeCount)")
        let ids = (0..<pack.undirectedEdgeCount).map { pack.edgeId($0) }
        #expect(ids.allSatisfy { !$0.isEmpty })
        // Whole-table digests from the accepted pack's JavaScript decoder.
        let expectedIDs = ["ns": "30c36016caf95c3179861f59b1c63b153bad35e8aba2128b209ef02901c1682e",
                           "nb": "1b2bc06fae0c84311609f4ea98afb5985a881f1a1f9466bc31c76fbaeb809256"]
        #expect(SHA256.hash(data: Data(ids.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined() == expectedIDs[region])
        return pack
    }

    private func replay(
        _ router: OnDeviceRouter,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        seed: UInt64,
        avoidMotorways: Bool = false
    ) -> Swift.Result<OnDeviceRouter.Result, OnDeviceRouter.Failure> {
        let began = ProcessInfo.processInfo.systemUptime
        let result = router.routeDetailed(from: from, to: to, profile: profile, allowUnknown: false, sessionSeed: seed, avoidMotorways: avoidMotorways)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        switch result {
        case .success(let route):
            if let last = route.legs.last, last.edgeId == "soft-stitch-end" {
                #expect(last.coordinates.last?.latitude == to.latitude)
                #expect(last.coordinates.last?.longitude == to.longitude)
                if route.legs.count > 1 {
                    let previous = route.legs[route.legs.count - 2].coordinates.last
                    #expect(previous?.latitude == last.coordinates.first?.latitude)
                    #expect(previous?.longitude == last.coordinates.first?.longitude)
                }
            }
            try? saveEvidence([
                "from": [from.longitude, from.latitude], "to": [to.longitude, to.latitude],
                "profile": profile.rawValue, "seed": seed, "avoidMotorways": avoidMotorways, "distanceMeters": route.distanceMeters,
                "dirtPercent": route.reportedDirtPercent, "repeatedMeters": route.backtrackMeters,
                "timedOut": route.searchMeta.timedOut, "pass2": route.searchMeta.pass2Outcome,
                "legs": route.legs.map { ["edgeId": $0.edgeId, "surfaceLeaf": $0.surfaceLeaf as Any? ?? NSNull(), "meters": $0.distanceMeters, "geometry": $0.coordinates.map { [$0.longitude, $0.latitude] }] as [String: Any] }
            ], name: "road-\(seed)-\(to.latitude)-\(profile.rawValue)")
            let leafSamples = route.legs.compactMap { leg in
                leg.surfaceLeaf.map { "\($0):\(router.pack.surfaceFamilyMap[$0]?.rawValue ?? "nil")" }
            }
            let sample = Array(leafSamples.prefix(8)).joined(separator: ",")
            let families = Dictionary(grouping: route.legs.compactMap { leg in
                leg.surfaceLeaf.flatMap { router.pack.surfaceFamilyMap[$0]?.rawValue }
            }, by: { $0 }).mapValues { $0.count }
            print("[accepted-replay] profile=\(profile.rawValue) seconds=\(String(format: "%.3f", elapsed)) meters=\(Int(route.distanceMeters)) dirt=\(route.reportedDirtPercent) coarseDirt=\(route.dirtPercent) repeated=\(Int(route.backtrackMeters)) pops=\(route.searchMeta.pops) timedOut=\(route.searchMeta.timedOut) pass2=\(route.searchMeta.pass2Outcome) objective=\(route.searchMeta.rideObjective ?? "-") families=\(families) leaves=\(sample) note=\(route.debugNote)")
        case .failure(let failure):
            print("[accepted-replay] profile=\(profile.rawValue) seconds=\(String(format: "%.3f", elapsed)) failure=\(failure)")
        }
        return result
    }

    @Test("Routing oracle short and rural cases replay on accepted pack")
    func routingOracleShortAndRural() throws {
        let pack = try loadPack("ns")
        let router = try fixtureRouter(pack: pack)
        let cases: [(String, CLLocationCoordinate2D, CLLocationCoordinate2D)] = [
            ("short-intra-metro", .init(latitude: 44.764919, longitude: -63.340350), .init(latitude: 44.755736, longitude: -63.301255)),
            ("rural-pair", .init(latitude: 44.911062, longitude: -62.386656), .init(latitude: 45.261359, longitude: -62.621027))
        ]
        for (name, from, to) in cases {
            for profile in [RouteProfile.cleanest, .balanced, .dirt] {
                print("[accepted-replay] oracle=\(name)")
                let result = replay(router, from: from, to: to, profile: profile, seed: 3511091208, avoidMotorways: profile == .cleanest)
                if case .failure(let failure) = result {
                    Issue.record("Accepted-pack replay failed case=\(name) profile=\(profile.rawValue): \(failure)")
                }
            }
        }
    }

    @Test("Regional reuse preserves fuel caps and unfinished-search classification")
    @MainActor
    func boundedRegionalRouteReuse() async throws {
        let (store, temp, _) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        let from = CLLocationCoordinate2D(latitude: 44.764919, longitude: -63.340350)
        let to = CLLocationCoordinate2D(latitude: 44.755736, longitude: -63.301255)
        func query(cap: Double = 20_000) async -> Result<OnDeviceRouter.Result, OnDeviceRouter.Failure> {
            await store.routeOnDeviceDetailed(from: from, to: to, profile: .balanced,
                allowUnknown: false, avoidEdgeIds: [], sessionSeed: 3511091208, maxRouteMeters: cap)
        }
        guard case .success(let first) = await query(), case .success(let second) = await query() else {
            Issue.record("Known short route must remain reachable"); return
        }
        #expect(store.regionalRouteCacheHits == 1)
        #expect(first.edgeIds == second.edgeIds)
        #expect(first.distanceMeters == second.distanceMeters)
        let smallerCap = first.distanceMeters - 1
        if case .success(let constrained) = await query(cap: smallerCap) {
            #expect(constrained.distanceMeters <= smallerCap)
        }
        #expect(store.regionalRouteCacheHits == 1, "A changed fuel cap cannot reuse the previous route")
        let expired = await RoutingWorkContext.$deadline.withValue(0) { await query() }
        if case .failure(.searchLimit) = expired {} else {
            Issue.record("An expired request must not return cached success or no-path")
        }
        #expect(store.regionalRouteCacheHits == 1)
        guard case .success = await query() else {
            Issue.record("An expired request must not poison a later valid request"); return
        }
        #expect(store.regionalRouteCacheHits == 2)
    }

    @Test("Repeated fuel discovery keeps exact reachability distances")
    func repeatedFuelDiscovery() throws {
        let router = try fixtureRouter(pack: try loadPack("ns"))
        let from = CLLocationCoordinate2D(latitude: 44.764919, longitude: -63.340350)
        let to = CLLocationCoordinate2D(latitude: 44.755736, longitude: -63.301255)
        for profile in [RouteProfile.cleanest, .balanced, .dirt] {
            let first = try router.shortestGraphMeters(from: from, to: to,
                maxMeters: 207_000, profile: profile, allowUnknown: false)
            let repeated = try router.shortestGraphMeters(from: from, to: to,
                maxMeters: 207_000, profile: profile, allowUnknown: false)
            #expect(first != nil)
            #expect(first == repeated)
            // A cached match must never cache the previous range proof.
            #expect(try router.shortestGraphMeters(from: from, to: to,
                maxMeters: 1, profile: profile, allowUnknown: false) == nil)
        }
    }

    @Test("September 13 Nova Scotia routes replay on the accepted pack")
    func september13NovaScotiaRoutes() throws {
        let pack = try loadPack("ns")
        let router = try fixtureRouter(pack: pack)
        let start = CLLocationCoordinate2D(latitude: 44.764830, longitude: -63.340243)
        let allEndpoints: [(String, CLLocationCoordinate2D)] = [
            ("short", CLLocationCoordinate2D(latitude: 45.091108, longitude: -63.057616)),
            ("cape-breton", CLLocationCoordinate2D(latitude: 46.845234, longitude: -60.408302)),
            ("yarmouth", CLLocationCoordinate2D(latitude: 43.807616, longitude: -66.016108)),
            ("south-shore", CLLocationCoordinate2D(latitude: 43.849315, longitude: -66.057385))
        ]
        let endpoints = allEndpoints
        let profiles: [RouteProfile] = [.cleanest, .balanced, .dirt]
        for (name, endpoint) in endpoints {
            print("[accepted-replay] case=\(name)")
            for profile in profiles {
                let result = replay(router, from: start, to: endpoint, profile: profile, seed: 20260913)
                if case .failure(let failure) = result {
                    Issue.record("Accepted-pack replay failed case=\(name) profile=\(profile.rawValue): \(failure)")
                }
            }
        }
    }

    @Test("Accepted NS and NB packs cross the canonical seam")
    @MainActor
    func september13NovaScotiaToNewBrunswick() async throws {
        let (store, temp, _) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        let from = CLLocationCoordinate2D(latitude: 44.764830, longitude: -63.340243)
        let to = CLLocationCoordinate2D(latitude: 47.903181, longitude: -66.074515)
        let began = ProcessInfo.processInfo.systemUptime
        let result = await store.routeOnDeviceDetailed(from: from, to: to, profile: RouteProfile.dirt, allowUnknown: false, sessionSeed: 20260913)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        switch result {
        case .success(let route):
            try saveEvidence([
                "from": [from.longitude, from.latitude], "to": [to.longitude, to.latitude],
                "profile": "dirt", "seed": 20260913, "packRelease": "fabric-v4-20260908-02",
                "distanceMeters": route.distanceMeters, "dirtPercent": route.reportedDirtPercent,
                "repeatedMeters": route.backtrackMeters, "timedOut": route.searchMeta.timedOut,
                "pass2": route.searchMeta.pass2Outcome,
                "legs": route.legs.map { leg in ["edgeId": leg.edgeId,
                    "geometry": leg.coordinates.map { [$0.longitude, $0.latitude] },
                    "meters": leg.distanceMeters] as [String: Any] }
            ], name: "road-20260913-ns-nb-dirt")
            print("[accepted-replay] case=ns-nb profile=dirt seconds=\(String(format: "%.3f", elapsed)) meters=\(Int(route.distanceMeters)) dirt=\(route.reportedDirtPercent) repeated=\(Int(route.backtrackMeters))")
            #expect(route.coordinates.count > 2)
        case .failure(let failure):
            Issue.record("Accepted NS/NB seam replay failed: \(failure)")
        }
    }

    @Test("Fresh planning acquisition downloads and verifies the current public NS pack")
    @MainActor
    func currentCatalogAcquisition() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("routing-acquisition-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let measurement = RoutingMeasurement(metadata: ["workload": "fresh NS public acquisition", "execution": "GraphPackStore URLSession verified installation"])
        let store = GraphPackStore(cacheRoot: temp, refreshCatalogOnInit: false)
        #expect(!store.isRoutingPackInstalled("ns"))
        let model = RoutePlannerModel(routing: RoutingClient(), locationService: LocationService(),
            mapState: MapState(), navigation: NavigationSession(), offline: OfflineTileManager(),
            graphPacks: store, network: NetworkPathMonitor(), requiresInstalledRoutingPacks: true)
        let origin = RiderWaypoint(coordinate: RouteCoordinate(longitude: -63.34024797349485, latitude: 44.764804567541226))
        let destination = RiderWaypoint(coordinate: RouteCoordinate(longitude: -62.233921261078635, latitude: 45.56808192814221))
        model.selectMode(.plan)
        model.apply(.replaceAll(waypoints: [origin.coordinate, destination.coordinate], profile: .dirt,
            allowUnknown: false, avoidMotorways: false, preferBackRoads: false), source: "plan")
        await model.waitForCanonicalBuildForTesting()
        let prompt = try #require(model.packConsent)
        #expect(prompt.regionIDs == ["ns"])
        #expect((prompt.downloadBytes ?? 0) > 0)
        #expect(model.activeResponses.isEmpty)
        #expect(model.itinerary.waypoints.map(\.coordinate) == [origin.coordinate, destination.coordinate])
        let phase = measurement.begin(.acquisition)
        await RoutingWorkContext.$measurement.withValue(measurement) {
            await model.acceptPackConsent()
            measurement.end(phase)
            await model.waitForCanonicalBuildForTesting()
        }
        #expect(store.packRevisionState("ns") == .current)
        #expect(model.packConsent == nil)
        #expect(model.itinerary.waypoints.map(\.coordinate) == [origin.coordinate, destination.coordinate])
        #expect(!model.activeResponses.isEmpty)
        #expect(model.built?.riderLegStatus.values.allSatisfy { $0 == .built } == true)
        #expect(model.built?.legs.last?.toCoordinate == destination.coordinate)
        #expect(model.errorMessage == nil)
        try saveEvidence(["measurement": try object(measurement.finish(outcome: "acquired")),
            "identity": store.installedPackIdentity(regionId: "ns") ?? [:]], name: "fresh-public-acquisition")
    }

    @Test("Owner phone 42 requests replay with its exact catalog and fuel settings")
    @MainActor
    func ownerPhone42Requests() async throws {
        try await runOwnerPhone42Requests(repeatFirst: false)
    }

    @Test("Exact first owner request measures first-use and repeated preparation")
    @MainActor
    func ownerPhone42ColdWarm() async throws {
        try await runOwnerPhone42Requests(repeatFirst: true)
    }

    @Test("Exact fourth owner request checks fuel continuation near the destination")
    @MainActor
    func ownerPhone42FourthFuelContinuation() async throws {
        try await runOwnerPhone42Requests(repeatFirst: false,
            onlyRequestID: "EB86574E-9CF2-5EC8-AF91-664BABDD8718")
    }

    @Test("Exact first owner fuel request compares optional station coverage with two cold stores")
    @MainActor
    func ownerPhone42CoveragePreprobeAB() async throws {
        let request = "20AB1401-6158-52C4-8FF8-572F828EC800"
        let enabled = try await runOwnerPhone42Requests(repeatFirst: false,onlyRequestID: request,
            coveragePreprobe: true,evidenceSuffix: "-coverage-on",packRegions: ["ns"],captureDigest: true)
        let disabled = try await runOwnerPhone42Requests(repeatFirst: false,onlyRequestID: request,
            coveragePreprobe: false,evidenceSuffix: "-coverage-off",packRegions: ["ns"],captureDigest: true)
        #expect(enabled.count == 1 && disabled.count == 1)
        #expect(enabled == disabled, "Canonical road/fuel/legal data must match apart from measured search timing")
    }

    @Test("Exact owner recovers a timed-out optional destination preprobe through native routing")
    @MainActor
    func ownerPhone42MissingDestinationPreprobe() async throws {
        let priorLogging = RoutingDebugLog.shared.isEnabled
        RoutingDebugLog.shared.isEnabled = true
        defer { RoutingDebugLog.shared.isEnabled = priorLogging }
        try await runOwnerPhone42Requests(repeatFirst: false,
            onlyRequestID: "20AB1401-6158-52C4-8FF8-572F828EC800",
            evidenceSuffix: "-missing-destination-preprobe", forceInitialDestinationProbeTimeout: true)
    }

    @MainActor
    private final class MissingDestinationPreprobeSource: RoutingSource {
        let base: PackRoutingSource
        var name: String { base.name }
        var supportsCombinedFuelPlanning: Bool { base.supportsCombinedFuelPlanning }
        private(set) var forcedTimeouts = 0
        private(set) var requests: [FuelChainRequest] = []
        private(set) var responses: [FuelChainResponse] = []
        init(_ base: PackRoutingSource) { self.base = base }
        func route(_ request: RouteRequest) async throws -> RouteResponse { try await base.route(request) }
        func fuelChain(_ request: FuelChainRequest) async throws -> FuelChainResponse {
            requests.append(request)
            if forcedTimeouts == 0, request.fuel.riderLegId == "destination-escape",
               request.fuel.probeFirstReachableStation == true, request.fuel.forwardFeeler == true,
               request.fuel.windowTimeBudgetMs == 2_500 {
                forcedTimeouts += 1
                throw RoutingError.fuelUnknown("Fuel planning reached its time budget. A fuel gap has not been proved.")
            }
            let response = try await base.fuelChain(request)
            responses.append(response)
            return response
        }
        func verifiedInitialFuelStation(at point: RouteCoordinate, profile: RouteProfile,
            allowUnknown: Bool) async throws -> FuelChainStop? {
            try await base.verifiedInitialFuelStation(at: point, profile: profile, allowUnknown: allowUnknown)
        }
        func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
            try await base.fuelStation(near: point, within: meters)
        }
    }

    private func canonicalOwnerResultDigest(_ result: BuiltItinerary) throws -> Data {
        let legs = try result.legs.map { leg -> [String: Any] in
            var response = try #require(try object(leg.response) as? [String: Any])
            if var debug = response["debug"] as? [String: Any] {
                debug.removeValue(forKey: "searchMs")
                if var meta = debug["searchMeta"] as? [String: Any] {
                    meta.removeValue(forKey: "elapsedMs")
                    meta.removeValue(forKey: "calculationElapsedMs")
                    debug["searchMeta"] = meta
                }
                response["debug"] = debug
            }
            return ["response": response,"from": try object(leg.fromCoordinate),
                "to": try object(leg.toCoordinate),"fuelStop": try leg.endsAtFuelStop.map { try object($0) } ?? NSNull(),
                "fuelUsedOnArrivalMeters": leg.fuelUsedOnArrivalMeters,
                "profile": leg.routeProfile?.rawValue as Any? ?? NSNull(),"fuelTargets": leg.validFuelTargets.map(\.id)]
        }
        let canonical: [String: Any] = ["legs": legs,"generation": result.generation,
            "status": try object(result.riderLegStatus)]
        return Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: canonical,options: [.sortedKeys])))
    }

    @MainActor
    @discardableResult
    private func runOwnerPhone42Requests(repeatFirst: Bool, onlyRequestID: String? = nil,
        coveragePreprobe: Bool = true, evidenceSuffix: String = "",
        packRegions: [String] = ["ns", "nb"], captureDigest: Bool = false,
        forceInitialDestinationProbeTimeout: Bool = false) async throws -> [Data] {
        let version = "fabric-v4-20260909-02"
        let candidate = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(version).appendingPathComponent("packs")
        let (store, temp, fixtureIdentity) = try fixtureStore(packRoot: candidate, version: version, regions: packRegions)
        defer { try? FileManager.default.removeItem(at: temp) }
        store.useStationCoveragePreprobe = coveragePreprobe
        var resultDigests: [Data] = []
        let cases: [(String, Double, Double, Double, UInt64)] = [
            ("20AB1401-6158-52C4-8FF8-572F828EC800", 46.95522997783574, -60.45932167843518, 10.2, 5934816597329416),
            ("B43439CF-6AD5-5307-840F-B44671702BE7", 46.907159895654424, -60.5140885784627, 11.2, 5514739685182283),
            ("531BC48C-868A-5545-AB93-1FD01CEBABFF", 46.885033126489716, -60.49502889835437, 11.2, 5797475437955788),
            ("EB86574E-9CF2-5EC8-AF91-664BABDD8718", 45.56808192814221, -62.233921261078635, 7.9, 6709655860308004)
        ]
        let selected = onlyRequestID.map { id in cases.filter { $0.0 == id } }
            ?? (repeatFirst ? [cases[0], cases[0]] : cases)
        for (runIndex, request) in selected.enumerated() {
            let (id, lat, lon, zoom, seed) = request
            let evidenceID = id + (repeatFirst ? (runIndex == 0 ? "-first-use" : "-repeated") : "") + evidenceSuffix
            let a = RiderWaypoint(coordinate: RouteCoordinate(longitude: -63.34024797349485, latitude: 44.764804567541226))
            let b = RiderWaypoint(coordinate: RouteCoordinate(longitude: lon, latitude: lat))
            let template = RiderLeg(from: a.id, to: b.id, profile: .dirt, allowUnknown: false, avoidMotorways: false)
            var raw = try #require(try object(template) as? [String: Any])
            raw["id"] = id
            let leg = try JSONDecoder().decode(RiderLeg.self, from: JSONSerialization.data(withJSONObject: raw))
            #expect(leg.routingSessionSeed == seed)
            let itinerary = RiderItinerary(waypoints: [a, b], legs: [leg], generation: 1, impassableEdgeIDs: [])
            let builder = ItineraryBuilder()
            builder.mapZoom = zoom
            let measurement = RoutingMeasurement(metadata: [
                "workload": "owner-phone42-" + id, "packRelease": version,
                "stationCoveragePreprobe": String(coveragePreprobe),
                "hardware": "MacBookPro17,1 Apple M1 16 GiB; iPhone17 iOS26.5 simulator",
                "execution": "native PackRoutingSource / ItineraryBuilder",
                "preparation": runIndex == 0 ? "first request in store" : "reused store",
                "maxLabelPayloadBytes": "134217728",
                "seed": String(seed), "profile": "dirt", "allowUnknown": "false",
                "tankMeters": "200000", "reservePercent": "10"
            ])
            let nativeSource = PackRoutingSource(packs: store, cache: RouteResponseCache())
            let probeAdapter = forceInitialDestinationProbeTimeout ? MissingDestinationPreprobeSource(nativeSource) : nil
            let replaySource: any RoutingSource
            if let probeAdapter { replaySource = probeAdapter } else { replaySource = nativeSource }
            let logMarker = "owner-preprobe-regression-" + UUID().uuidString
            if probeAdapter != nil { RoutingDebugLog.shared.event(logMarker) }
            let result = await RoutingWorkContext.$measurement.withValue(measurement) {
                await builder.build(itinerary, from: 0, reuse: nil,
                fuel: FuelRangePrefs.Snapshot(tankMeters: 200_000, usableMeters: 180_000, reservePercent: 10, automaticPlanningEnabled: true),
                source: .fixed(replaySource),
                onFuelStatus: { _ in }, onProgress: { _ in })
            }
            let report = measurement.finish(outcome: String(describing: result.riderLegStatus))
            if captureDigest { resultDigests.append(try canonicalOwnerResultDigest(result)) }
            try saveEvidence(["measurement": try object(report),
                "verifiedFixtureIdentity": fixtureIdentity,
                "catalogInstalledIdentityNS": store.installedPackIdentity(regionId: "ns") as Any? ?? NSNull()], name: "measurement-phone42-" + evidenceID)
            try saveEvidence(["pack": version, "verifiedFixtureIdentity": fixtureIdentity,
                "itinerary": try object(itinerary), "mapZoom": zoom,
                "tankMeters": 200_000, "usableMeters": 180_000,
                "routes": try result.legs.map { try object($0.response) },
                "status": String(describing: result.riderLegStatus),
                "stops": result.legs.compactMap { $0.endsAtFuelStop?.stationID }], name: "phone42-" + evidenceID)
            if let probeAdapter {
                let diagnostic = RoutingDebugLog.shared.text
                #expect(diagnostic.contains(logMarker), "This calculation's marker must remain in the diagnostic ring")
                let log = diagnostic.components(separatedBy: logMarker).last ?? ""
                try saveEvidence(["adapter": "Only the first destination-escape 2500ms preprobe throws its existing timeout; all other calls use native PackRoutingSource unchanged",
                    "forcedTimeouts": probeAdapter.forcedTimeouts,
                    "requests": try probeAdapter.requests.map { try object($0) },
                    "responses": try probeAdapter.responses.map { try object($0) },
                    "log": log], name: "adapter-phone42-" + evidenceID)
                #expect(probeAdapter.forcedTimeouts == 1)
                #expect(log.contains("destination planning reservation retry meters="))
                #expect(log.contains("arrivalVerified=false"))
                #expect(result.legs.compactMap { $0.endsAtFuelStop?.stationID } ==
                    ["osm:a366199684", "osm:a1095466802", "osm:a581652160"])
                let escape = try #require(probeAdapter.responses.last?.destinationEscapeMeters)
                let finalMeters = try #require(result.legs.last?.response.distanceMeters)
                #expect(escape.isFinite && escape > 0 && finalMeters + escape <= 180_000)
                let rideRequests = probeAdapter.requests.filter { $0.fuel.riderLegId == id }
                #expect(!rideRequests.isEmpty)
                #expect(rideRequests.allSatisfy { $0.options?.sessionSeed == seed && $0.fuel.usableRangeMeters == 180_000 })
            }
            #expect(result.legs.first?.endsAtFuelStop?.stationID != nil)
            #expect(result.legs.last?.toCoordinate == b.coordinate)
            #expect(result.riderLegStatus[leg.id] == .built)
            if result.riderLegStatus[leg.id] == .built {
                var metersSinceRefill = 0.0
                for stage in result.legs {
                    let meters = try #require(stage.response.distanceMeters)
                    #expect(meters.isFinite && meters >= 0)
                    metersSinceRefill += meters
                    #expect(metersSinceRefill <= 180_000,
                        "A completed fuel plan must charge every selected stage against the actual reserve-adjusted range")
                    if stage.endsAtFuelStop != nil { metersSinceRefill = 0 }
                }
            }
        }
        return resultDigests
    }

    @Test("Ontario private index preparation measures cold reuse and cancellation")
    @MainActor
    func ontarioIndexPreparationAndCancellation() async throws {
        let version = "fabric-v4-20260909-02"
        let dir = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(version).appendingPathComponent("packs/on")
        let manifest = try #require(JSONSerialization.jsonObject(with:
            Data(contentsOf: dir.appendingPathComponent("pack-manifest.v2.json"))) as? [String: Any])
        let graph = try #require(manifest["graph"] as? [String: Any])
        let geometry = try #require(manifest["geometry"] as? [String: Any])
        let identity = ExactSnapIndex.Identity(graphSHA256: try #require(graph["sha256"] as? String),
            graphBytes: try #require(graph["bytes"] as? Int),
            geometrySHA256: try #require(geometry["sha256"] as? String),
            geometryBytes: try #require(geometry["bytes"] as? Int))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let graphURL = dir.appendingPathComponent("graph.v4.bin")
        let geometryURL = dir.appendingPathComponent("geometry.v1.bin")
        for run in 0..<2 {
            let measurement = RoutingMeasurement(metadata: ["workload": "Ontario exact index preparation",
                "packRelease": version, "graphSHA256": identity.graphSHA256,
                "geometrySHA256": identity.geometrySHA256,
                "hardware": "MacBookPro17,1 Apple M1 16 GiB; iPhone17 iOS26.5 simulator",
                "preparation": run == 0 ? "cold private derivative" : "reuse verified derivative"])
            try await RoutingWorkContext.$measurement.withValue(measurement) {
                try await RoutingWorkContext.detachedThrowingSearch {
                    _ = try ExactSnapIndexPreparation.prepare(graphURL: graphURL, geometryURL: geometryURL,
                        destination: temporary.appendingPathComponent("index"), identity: identity,
                        cancelled: { RoutingWorkContext.stopReason != nil })
                }
            }
            let report = measurement.finish(outcome: "verified")
            try saveEvidence(["measurement": try object(report)], name: "ontario-index-preparation-\(run)")
        }
        let cancelledURL = temporary.appendingPathComponent("cancelled-index")
        let worker = Task {
            try await RoutingWorkContext.detachedThrowingSearch {
                _ = try ExactSnapIndexPreparation.prepare(graphURL: graphURL, geometryURL: geometryURL,
                    destination: cancelledURL, identity: identity,
                    cancelled: { RoutingWorkContext.stopReason != nil })
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        let began = ProcessInfo.processInfo.systemUptime
        worker.cancel()
        do { try await worker.value; Issue.record("Preparation finished before cancellation workload could be exercised") }
        catch { /* The caller's cancelled operation must not publish. */ }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        #expect(elapsed < 1)
        #expect(!FileManager.default.fileExists(atPath: cancelledURL.path))
        try saveEvidence(["cancellationResponseSeconds": elapsed, "packRelease": version,
            "graphSHA256": identity.graphSHA256], name: "ontario-index-cancellation")
    }

    @Test("Current Ontario pack completes the existing southern Ontario endpoints without fuel")
    @MainActor
    func southernOntarioFuelOffColdWarm() async throws {
        let version = "fabric-v4-20260909-02"
        let candidate = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(version).appendingPathComponent("packs")
        let (store, temp, _) = try fixtureStore(packRoot: candidate, version: version, regions: ["on"])
        defer { try? FileManager.default.removeItem(at: temp) }
        let from = CLLocationCoordinate2D(latitude: 44.632662, longitude: -75.651839)
        let to = CLLocationCoordinate2D(latitude: 44.601681, longitude: -79.308263)
        for profile in [RouteProfile.dirt, .balanced, .cleanest] {
            for repetition in 0..<2 {
                let name = "ontario-" + profile.rawValue + "-" + String(repetition)
                let measurement = RoutingMeasurement(metadata: ["workload": "device-on-kingston-to-orillia",
                    "packRelease": version, "profile": profile.rawValue, "fuel": "off",
                    "allowUnknown": "false", "seed": String(0xD1470008),
                    "preparation": repetition == 0 ? "first profile request" : "same request repeated",
                    "hardware": "MacBookPro17,1 M1 16GiB iPhone17 iOS26.5 simulator"])
                let result = await RoutingWorkContext.$measurement.withValue(measurement) {
                    await store.routeOnDeviceDetailed(from: from, to: to, profile: profile,
                        allowUnknown: false, sessionSeed: 0xD1470008)
                }
                let outcome: String
                switch result {
                case .success(let route): outcome = route.searchMeta.timedOut ? "road-complete-search-incomplete" : "complete"
                case .failure(let failure): outcome = String(describing: failure)
                }
                var output: [String: Any] = ["from": [from.longitude, from.latitude], "to": [to.longitude, to.latitude],
                    "measurement": try object(measurement.finish(outcome: outcome))]
                switch result {
                case .success(let route):
                    output["route"] = ["distanceMeters": route.distanceMeters,
                        "dirtPercent": route.reportedDirtPercent, "coarseDirtPercent": route.dirtPercent,
                        "unknownSurfacePercent": route.unknownSurfacePercent,
                        "reportedPavedPercent": route.reportedPavedPercent,
                        "timedOut": route.searchMeta.timedOut, "pops": route.searchMeta.pops,
                        "pass2Outcome": route.searchMeta.pass2Outcome, "debugNote": route.debugNote,
                        "urbanCoreFallback": route.searchMeta.urbanCoreFallbackUsed,
                        "cleanUnpavedFallback": route.searchMeta.cleanUnpavedFallbackUsed,
                        "repeatedMeters": route.backtrackMeters,
                        "geometry": route.coordinates.map { [$0.longitude, $0.latitude] },
                        "legs": route.legs.map { leg in ["edgeID": leg.edgeId, "meters": leg.distanceMeters,
                            "surface": leg.surfaceName, "access": leg.accessName,
                            "geometry": leg.coordinates.map { [$0.longitude, $0.latitude] }] as [String: Any] }]

                    #expect(route.coordinates.count > 1)
                    #expect(route.searchMeta.timedOut == false)
                case .failure(let failure): Issue.record("Ontario \(profile) did not complete: \(failure)")
                }
                try saveEvidence(output, name: name)
            }
        }
    }

    @Test("Ontario Clean pointer cache A/B preserves the exact route and search work")
    @MainActor
    func southernOntarioCleanPointerCacheAB() async throws {
        try await southernOntarioCleanLookupAB(comparison: .pointer)
    }

    @Test("Ontario Clean combined and split retrace callbacks preserve exact search")
    @MainActor
    func southernOntarioCleanRetraceCallbackAB() async throws {
        try await southernOntarioCleanLookupAB(comparison: .callback)
    }

    @Test("Ontario Clean scoped bounds preserve exact towns, roads and search work")
    @MainActor
    func southernOntarioScopedBoundsAB() async throws {
        try await southernOntarioCleanLookupAB(comparison: .bounds)
    }

    private enum LookupComparison: String { case pointer, callback, bounds }

    @MainActor
    private func southernOntarioCleanLookupAB(comparison: LookupComparison) async throws {
        let version = "fabric-v4-20260909-02"
        let candidate = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(version).appendingPathComponent("packs")
        let (store, temp, _) = try fixtureStore(packRoot: candidate, version: version, regions: ["on"])
        defer { try? FileManager.default.removeItem(at: temp) }
        let from = CLLocationCoordinate2D(latitude: 44.632662, longitude: -75.651839)
        let to = CLLocationCoordinate2D(latitude: 44.601681, longitude: -79.308263)
        // Warm the actual store preparation once, then reuse its verified pack/indexes.
        let warmup = await store.routeOnDeviceDetailed(from: from, to: to, profile: .cleanest,
            allowUnknown: false, sessionSeed: 0xD1470008)
        guard case .success(let reference) = warmup else {
            Issue.record("Ontario Clean warmup failed: \(warmup)"); return
        }
        #expect(!reference.searchMeta.timedOut)
        let pack = try #require(store.packIfInstalled("on"))
        _ = try #require(pack.exactSnapIndex, "A/B must reuse the prepared app pack")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            candidate.appendingPathComponent("on/pack-manifest.v2.json"))) as? [String: Any])
        let graph = try #require(manifest["graph"] as? [String: Any])
        let geometry = try #require(manifest["geometry"] as? [String: Any])
        // ABBA controls simple warm-order bias without concurrent calculations.
        for (ordinal, enabled) in [true, false, false, true].enumerated() {
            let pointerEnabled = comparison != .pointer || enabled
            let callbackEnabled = comparison != .callback || enabled
            let boundsEnabled = comparison != .bounds || enabled
            let measurement = RoutingMeasurement(metadata: ["workload": "Ontario Clean \(comparison.rawValue) ABBA",
                "packRelease": version, "graphSHA256": try #require(graph["sha256"] as? String),
                "geometrySHA256": try #require(geometry["sha256"] as? String),
                "pointerCache": String(pointerEnabled), "retraceCounters": "local-counted",
                "combinedCallback": String(callbackEnabled), "scopedBounds": String(boundsEnabled),
                "profile": RouteProfile.cleanest.rawValue, "fuel": "off", "allowUnknown": "false",
                "seed": String(0xD1470008), "preparation": "warm verified app pack",
                "hardware": "MacBookPro17,1 M1 16GiB iPhone17 iOS26.5 simulator"])
            let result = await RoutingWorkContext.$measurement.withValue(measurement) {
                await RoutingWorkContext.detachedSearch {
                    var router = OnDeviceRouter(pack: pack)
                    router.sessionSeed = 0xD1470008
                    router.useLabelReadPointerCache = pointerEnabled
                    router.useCombinedRetraceCallback = callbackEnabled
                    router.useScopedRoadBounds = boundsEnabled
                    return router.routeDetailed(from: from, to: to, profile: .cleanest,
                        allowUnknown: false, sessionSeed: 0xD1470008)
                }
            }
            var output: [String: Any] = ["from": [from.longitude, from.latitude],
                "to": [to.longitude, to.latitude], "pointerCache": pointerEnabled,
                "combinedCallback": callbackEnabled, "scopedBounds": boundsEnabled]
            switch result {
            case .success(let route):
                #expect(!route.searchMeta.timedOut)
                #expect(route.edgeIds == reference.edgeIds)
                #expect(route.coordinates.map(\.latitude) == reference.coordinates.map(\.latitude))
                #expect(route.coordinates.map(\.longitude) == reference.coordinates.map(\.longitude))
                #expect(route.distanceMeters == reference.distanceMeters)
                #expect(route.backtrackMeters == reference.backtrackMeters)
                #expect(route.searchMeta.pops == reference.searchMeta.pops)
                output["distanceMeters"] = route.distanceMeters
                output["pops"] = route.searchMeta.pops
                output["edgeIds"] = route.edgeIds
                output["geometry"] = route.coordinates.map { [$0.longitude, $0.latitude] }
                output["measurement"] = try object(measurement.finish(outcome:
                    route.searchMeta.timedOut ? "road-complete-search-incomplete" : "complete"))
            case .failure(let failure):
                output["measurement"] = try object(measurement.finish(outcome: String(describing: failure)))
                Issue.record("Ontario Clean pointer A/B failed: \(failure)")
            }
            try saveEvidence(output, name: "ontario-clean-\(comparison.rawValue)-ab-\(ordinal)-\(enabled)")
        }
    }

    @Test("Actual Ontario Balanced warm read-cache slots ABBA")
    @MainActor
    func southernOntarioBalancedReadCacheSlotsAB() async throws {
        let version = "fabric-v4-20260909-02"
        let candidate = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(version).appendingPathComponent("packs")
        let (store, temp, _) = try fixtureStore(packRoot: candidate, version: version, regions: ["on"])
        defer { try? FileManager.default.removeItem(at: temp) }
        let from = CLLocationCoordinate2D(latitude: 44.632662, longitude: -75.651839)
        let to = CLLocationCoordinate2D(latitude: 44.601681, longitude: -79.308263)
        // Warm the actual store preparation once, then reuse its verified pack/indexes.
        if case .failure(let failure) = await store.routeOnDeviceDetailed(from: from, to: to, profile: .cleanest,
            allowUnknown: false, sessionSeed: 0xD1470008) {
            Issue.record("Ontario verified pack preparation failed: \(failure)"); return
        }
        let pack = try #require(store.packIfInstalled("on"))
        _ = try #require(pack.exactSnapIndex, "A/B must reuse the prepared app pack")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            candidate.appendingPathComponent("on/pack-manifest.v2.json"))) as? [String: Any])
        let graph = try #require(manifest["graph"] as? [String: Any])
        let geometry = try #require(manifest["geometry"] as? [String: Any])
        // ABBA controls simple warm-order bias without concurrent calculations.
        for (ordinal, slots) in [256,4096,4096,256].enumerated() {
            let measurement = RoutingMeasurement(metadata: ["workload": "Ontario Balanced read-cache slots ABBA",
                "packRelease": version, "graphSHA256": try #require(graph["sha256"] as? String),
                "geometrySHA256": try #require(geometry["sha256"] as? String),
                "pointerCacheSlots": String(slots), "pointerCacheMetadataBytes": String(slots*16),
                "retraceCounters": "local-counted",
                "profile": RouteProfile.balanced.rawValue, "fuel": "off", "allowUnknown": "false",
                "seed": String(0xD1470008), "preparation": "warm verified app pack",
                "hardware": "MacBookPro17,1 M1 16GiB iPhone17 iOS26.5 simulator"])
            let result = await RoutingWorkContext.$measurement.withValue(measurement) {
                await RoutingWorkContext.detachedSearch {
                    var router = OnDeviceRouter(pack: pack)
                    router.sessionSeed = 0xD1470008
                    router.balancedLabelReadCacheSlots = slots
                    return router.routeDetailed(from: from, to: to, profile: .balanced,
                        allowUnknown: false, sessionSeed: 0xD1470008)
                }
            }
            let outcome: String
            switch result {
            case .success(let route): outcome = route.searchMeta.timedOut ? "road-complete-search-incomplete" : "complete"
            case .failure(let failure): outcome = String(describing: failure)
            }
            let report = measurement.finish(outcome: outcome)
            var output: [String: Any] = ["from": [from.longitude, from.latitude],
                "to": [to.longitude, to.latitude], "pointerCacheSlots": slots]
            switch result {
            case .success(let route):
                #expect(route.searchMeta.rideObjective == "surface-balance")
                #expect(route.coordinates.last?.latitude == to.latitude)
                #expect(route.coordinates.last?.longitude == to.longitude)
                #expect(route.unknownAccessPercent == 0)
                #expect(route.backtrackMeters == 0)
                #expect((45...55).contains(route.dirtPercent))
                #expect(route.terminalContinuation != nil)
                if route.searchMeta.pass2Outcome == "timeCap" || route.searchMeta.pass2Outcome == "popCap"
                    || route.searchMeta.pass2Outcome == "labelMemoryCap" {
                    #expect(route.searchMeta.timedOut)
                }
                output["searchDebug"] = try object(route.searchMeta.responseDebug)
                output["dirtPercent"] = route.dirtPercent
                output["unknownAccessPercent"] = route.unknownAccessPercent
                output["repeatedMeters"] = route.backtrackMeters
                output["terminalContinuation"] = try route.terminalContinuation.map { try object($0) } ?? NSNull()
                output["legs"] = route.legs.map { leg in
                    ["edgeID": leg.edgeId,"meters": leg.distanceMeters,"surface": leg.surfaceName,
                     "access": leg.accessName,"geometry": leg.coordinates.map { [$0.longitude,$0.latitude] }] as [String: Any]
                }
                output["distanceMeters"] = route.distanceMeters
                output["pops"] = route.searchMeta.pops
                output["edgeIds"] = route.edgeIds
                output["geometry"] = route.coordinates.map { [$0.longitude, $0.latitude] }
                output["measurement"] = try object(report)
            case .failure(let failure):
                output["measurement"] = try object(report)
                Issue.record("Ontario Balanced slot A/B lost legal road completion: \(failure)")
            }
            try saveEvidence(output, name: "ontario-balanced-cache-slots-ab-\(ordinal)-\(slots)")
        }
    }

    @Test("Short fuel-enabled itinerary begins with the required initial refill")
    @MainActor
    func shortItineraryStartsWithRefill() async throws {
        let (store, temp, _) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = PackRoutingSource(packs: store, cache: RouteResponseCache())
        let a = RiderWaypoint(coordinate: RouteCoordinate(longitude: -63.340243, latitude: 44.764830))
        let b = RiderWaypoint(coordinate: RouteCoordinate(longitude: -63.057616, latitude: 45.091108))
        let itinerary = RiderItinerary(waypoints: [a, b], legs: [RiderLeg(from: a.id, to: b.id, profile: .dirt, allowUnknown: false, avoidMotorways: false)], generation: 1, impassableEdgeIDs: [])
        let result = await ItineraryBuilder().build(
            itinerary, from: 0, reuse: nil,
            fuel: FuelRangePrefs.Snapshot(tankMeters: 200_000, usableMeters: 180_000, reservePercent: 10, automaticPlanningEnabled: true),
            source: .fixed(source), onFuelStatus: { _ in }, onProgress: { _ in }
        )
        #expect(result.legs.count == 2)
        #expect(result.legs.first?.endsAtFuelStop?.stationID == "osm:w183099842")
        #expect(result.legs.last?.endsAtFuelStop == nil)
        #expect(result.legs.last?.toCoordinate == b.coordinate)
        #expect(result.legs.allSatisfy { $0.riderLegID == itinerary.legs[0].id })
        #expect(result.riderLegStatus.values.allSatisfy {
            if case .built = $0 { return true }
            return false
        })
    }
    @Test("Fuel distance guidance spans recorded regional seams in both directions")
    @MainActor
    func crossPackFuelDistances() async throws {
        let (store, temp, _) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        let from = RouteCoordinate(longitude: -63.340350, latitude: 44.764919)
        let to = RouteCoordinate(longitude: -64.7782, latitude: 46.0878)
        let pumps = store.fuelStations(from: from, to: to)
        let ns = try loadPack("ns"), nb = try loadPack("nb")
        let anchor = try #require(ns.crossPackSeams["nb"]?.first)
        let seamNode = try #require(anchor.osmNodeId)
        #expect(ns.osmNodeIds.contains(seamNode) && nb.osmNodeIds.contains(seamNode))
        let parts = anchor.localEdgeId.split(separator: ":")
        let a = try #require(Int64(parts[1])), b = try #require(Int64(parts[2]))
        let canonical = "w\(anchor.osmWayId):\(min(a, b)):\(max(a, b))"
        let localIDs = ns.localRoadIDs(matching: [canonical])
        let remoteIDs = nb.localRoadIDs(matching: [canonical])
        #expect(!localIDs.isEmpty && !remoteIDs.isEmpty)
        #expect(localIDs.allSatisfy { ns.canonicalRoadID($0) == canonical })
        #expect(remoteIDs.allSatisfy { nb.canonicalRoadID($0) == canonical })
        let began = ProcessInfo.processInfo.systemUptime
        let guidance = try #require(await store.fuelRoadProgress(from: from.locationCoordinate,
            to: to.locationCoordinate, pumps: pumps, profile: .cleanest, allowUnknown: false))
        let forward = try #require(await store.shortestGraphMeters(from: from.locationCoordinate,
            to: to.locationCoordinate, maxMeters: 1_000_000, profile: .cleanest, allowUnknown: false))
        #expect(abs(forward - guidance.originRemainingMeters) < 0.001)
        #expect(guidance.originRemainingMeters > GeoMath.meters(from, to))
        #expect(!guidance.stationRemainingMeters.isEmpty)
        print("[accepted-fuel-field] seconds=\(ProcessInfo.processInfo.systemUptime - began) meters=\(forward) stations=\(guidance.stationRemainingMeters.count)")
    }

    @Test("Initial refill precedes the ride on the accepted real packs")
    @MainActor
    func initialRefillOnAcceptedPacks() async throws {
        let (store, temp, _) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        let start = RouteCoordinate(longitude: -63.340350, latitude: 44.764919)
        let destination = RouteCoordinate(longitude: -67.296103, latitude: 45.177074)
        for profile in [RouteProfile.cleanest, .balanced, .dirt] {
            let source = PackRoutingSource(packs: store, cache: RouteResponseCache())
            let request = FuelChainRequest(profile: profile, from: start, to: destination,
                allowUnknown: false, usableRangeMeters: 207_000, firstLegMaxMeters: 207_000,
                requireFuelStopBeforeEnd: false, minimumFuelStops: 0, profileMeters: 0,
                riderLegId: "initial-refill", initialFillUp: true, sessionSeed: 3511091208,
                windowMaxStops: 1, allowPartialWindow: true, windowTimeBudgetMs: 15_000)
            let chain = try await source.fuelChain(request)
            let stop = try #require(chain.stops?.first)
            let route = try #require(chain.routes?.first)
            #expect(chain.windowComplete == false)
            #expect(route.isComplete)
            #expect(route.distanceMeters != nil && route.distanceMeters! < 207_000)
            #expect(request.locations.last?.longitude == destination.longitude)
            try saveEvidence(["request": try object(request), "response": try object(chain)],
                name: "initial-refill-\(profile.rawValue)")
            print("[initial-refill] profile=\(profile.rawValue) station=\(stop.id) meters=\(route.distanceMeters ?? -1)")
        }
    }

    @Test("All historical oracle requests replay through the real pack source")
    @MainActor
    func allOracleFuelWorkflows() async throws {
        try await replayOracleFuelWorkflows(initialFillUp: false)
    }

    @Test("Owner fuel rides start with a refill and preserve the destination")
    @MainActor
    func ownerFuelWorkflows() async throws {
        try await replayOracleFuelWorkflows(initialFillUp: true)
    }

    @MainActor
    private func replayOracleFuelWorkflows(initialFillUp: Bool) async throws {
        let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/pack-fabric/bench/routing-oracle-cases.json")
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as? [String: Any])
        var cases = try #require(fixture["scenarios"] as? [[String: Any]])
        // Additional owner regression; historical oracle coordinates remain unchanged.
        // Destination is the accepted NB sidecar's St. Stephen Irving (osm:w682170844).
        cases.append(["id": "fundy-barrier", "label": "Porters Lake to St. Stephen",
            "from": ["lat": 44.764919, "lon": -63.340350],
            "to": ["lat": 45.177074, "lon": -67.296103]])
        let seed = UInt64(try #require(fixture["sessionSeed"] as? Int))
        let tank = Double(try #require(fixture["tankRangeKm"] as? Int)) * 1000
        let usable = tank * (1 - Double(try #require(fixture["reservePercent"] as? Int)) / 100)
        let (store, temp, _) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        for scenario in cases {
            let id = try #require(scenario["id"] as? String)
            let a = try #require(scenario["from"] as? [String: Double])
            let b = try #require(scenario["to"] as? [String: Double])
            let from = RouteCoordinate(longitude: try #require(a["lon"]), latitude: try #require(a["lat"]))
            let to = RouteCoordinate(longitude: try #require(b["lon"]), latitude: try #require(b["lat"]))
            for profile in [RouteProfile.cleanest, .balanced, .dirt] {
                let source = PackRoutingSource(packs: store, cache: RouteResponseCache())
                let originStation = initialFillUp ? try await source.fuelStation(near: from,
                    within: HopSearchPolicy.fuelWaypointSnapMeters) : nil
                var needsInitialFillUp = initialFillUp && originStation == nil
                var current = from, prior: [String] = [], arrival: String?
                var excluded: [String] = [], force = false, reached = false
                var routes: [RouteResponse] = [], stops: [FuelChainStop] = [], windows: [Any] = []
                var failure: String?
                let began = ProcessInfo.processInfo.systemUptime
                for attempt in 1...16 {
                    var request = FuelChainRequest(profile: profile, from: current, to: to, allowUnknown: false,
                        usableRangeMeters: usable, firstLegMaxMeters: usable, requireFuelStopBeforeEnd: force,
                        minimumFuelStops: force ? 1 : 0, profileMeters: 0, riderLegId: "\(id):\(profile.rawValue)",
                        initialFillUp: needsInitialFillUp,
                        avoidMotorways: profile == .cleanest, priorEdgeIds: prior, arrivalEdgeId: arrival,
                        backtrackFactor: 4, excludedStationIds: excluded, windowMaxStops: 1,
                        allowPartialWindow: true, windowTimeBudgetMs: 15000, forwardFeeler: false)
                    var options = request.options ?? RouteRequestOptions()
                    options.sessionSeed = seed
                    options.startEndpointKind = stops.isEmpty && originStation == nil ? nil : "customers"
                    request.options = options
                    do {
                        let chain = try await source.fuelChain(request)
                        windows.append(["request": try object(request), "response": try object(chain)])
                        guard chain.isComplete else { failure = "fuel-\(chain.status):\(chain.error ?? chain.message ?? "unknown")"; break }
                        let stop = chain.stops?.first
                        if stop == nil && chain.windowComplete == false { failure = "partial-without-forward-stop"; break }
                        let target = stop?.coordinate ?? to
                        let routeRequest = RouteRequest(profile: profile,
                            locations: [RouteLocation(latitude: current.latitude, longitude: current.longitude, label: "from"), RouteLocation(latitude: target.latitude, longitude: target.longitude, label: "to")],
                            allowUnknown: false, priorEdgeIds: prior, arrivalEdgeId: arrival, backtrackFactor: 4,
                            sessionSeed: seed, maxPathMeters: usable, regionalHopMinimumMeters: chain.graphMeters ?? [], avoidMotorways: profile == .cleanest)
                        let route: RouteResponse
                        do {
                            if let planned = chain.routes?.first { route = planned }
                            else { route = try await source.route(routeRequest) }
                        }
                        catch {
                            windows.append(["routeRequest": try object(routeRequest), "error": error.localizedDescription])
                            if let stop { excluded.append(stop.id); continue }
                            if !force { force = true; continue }
                            throw error
                        }
                        if stop != nil || !stops.isEmpty {
                            #expect((route.backtrackMeters ?? 0) <= 1_000,
                                "Fuel leg repeats more than the existing one-kilometre retrace allowance")
                        }
                        routes.append(route)
                        for segment in route.segments ?? [] {
                            if let edge = segment.edgeId, !edge.isEmpty {
                                if !prior.contains(edge) { prior.append(edge) }; arrival = edge
                            }
                        }
                        if needsInitialFillUp {
                            prior.removeAll()
                            arrival = route.segments?.last(where: { !($0.edgeId ?? "").isEmpty && !($0.edgeId ?? "").hasPrefix("soft-stitch") })?.edgeId
                            needsInitialFillUp = false
                        }
                        guard let stop else { reached = true; break }
                        stops.append(stop); current = target; excluded.append(stop.id); force = false
                        if attempt == 16 { failure = "forward-attempt-limit" }
                    } catch { failure = error.localizedDescription; break }
                }
                if reached, let last = routes.last?.coordinates.last {
                    let endpointGap = CLLocation(latitude: last.latitude, longitude: last.longitude)
                        .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
                    #expect(endpointGap <= OnDeviceRouter.softStitchMinMeters + 0.000001)
                }
                let evidence: [String: Any] = ["scenario": scenario, "profile": profile.rawValue,
                    "seed": seed, "tankMeters": tank, "usableMeters": usable,
                    "reachedDestination": reached, "requestedDestination": try object(to), "reachedEndpoint": try object(routes.last?.coordinates.last ?? from),
                    "failure": failure as Any? ?? NSNull(), "routes": try object(routes), "stops": try object(stops), "windows": windows]
                try saveEvidence(evidence, name: "oracle-\(initialFillUp ? "initial-" : "")\(id)-\(profile.rawValue)")
                print("[\(initialFillUp ? "owner-oracle" : "accepted-oracle")] case=\(id) profile=\(profile.rawValue) reached=\(reached) seconds=\(ProcessInfo.processInfo.systemUptime-began) meters=\(routes.reduce(0) { $0 + ($1.distanceMeters ?? 0) }) stops=\(stops.map(\.id)) failure=\(failure ?? "none")")
                #expect(reached, "Oracle did not reach requested destination: \(id)/\(profile.rawValue): \(failure ?? "unknown")")
            }
        }
    }

    @Test("Installed pack reuse preserves identity and invalidates changed files")
    @MainActor func installedPackReuse() async throws {
        let (store, temp, _) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        let ns = CLLocationCoordinate2D(latitude: 44.764830, longitude: -63.340243)
        let nb = CLLocationCoordinate2D(latitude: 45.9636, longitude: -66.6431)
        await store.warmupActivePack(near: ns)
        let first = try #require(store.activePack)
        await store.warmupActivePack(near: nb)
        #expect(store.activePack?.regionId == "nb")
        await store.warmupActivePack(near: ns)
        #expect(store.activePack === first)
        await store.warmupActivePack(near: nb)
        let geometry = temp.appendingPathComponent("fabric-v4-20260908-02/ns/geometry.v1.bin")
        let oldIdentity = store.routingCacheIdentity()
        #expect(oldIdentity.contains("fabric-v4-20260908-02"))
        let oldDate = try #require(geometry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try FileManager.default.setAttributes([.modificationDate: oldDate.addingTimeInterval(2)], ofItemAtPath: geometry.path)
        #expect(store.routingCacheIdentity() != oldIdentity)
        await store.warmupActivePack(near: ns)
        #expect(store.activePack !== first)
        #expect(store.activePack?.undirectedEdgeCount == first.undirectedEdgeCount)
        #expect(store.activePack?.edgeId(0) == first.edgeId(0))
    }

}
