import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

/// Development-only replay of the accepted pack contract. This deliberately
/// calls the same unbounded on-device route entry point used by the restored
/// planner; it does not exercise the later fast-search candidate.
@Suite("Accepted V4 on-device replay", .serialized)
struct OnDevicePackBenchmarkTests {
    private var root: URL {
        if let value = ProcessInfo.processInfo.environment["DIRT_PACK_ROOT"] {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260908-02/packs", isDirectory: true)
    }


    private func verifyPack(_ region: String) throws {
        let dir = root.appendingPathComponent(region)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("pack-manifest.v2.json"))) as? [String: Any])
        #expect(manifest["fabricReleaseId"] as? String == "fabric-v4-20260908-02")
        for key in ["graph", "geometry", "fuel", "seams"] {
            let file = try #require(manifest[key] as? [String: Any])
            let name = try #require(file["name"] as? String)
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            #expect(data.count == file["bytes"] as? Int)
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file["sha256"] as? String)
        }
    }

    @MainActor
    private func fixtureStore() throws -> (GraphPackStore, URL) {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("recovery-packs-\(UUID())")
        do {
            for region in ["ns", "nb"] {
                try verifyPack(region)
                let destination = temp.appendingPathComponent("fabric-v4-20260908-02/\(region)")
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for name in ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "cross-pack-seams.v2.json", "pack-manifest.v2.json"] {
                    try fm.copyItem(at: root.appendingPathComponent("\(region)/\(name)"), to: destination.appendingPathComponent(name))
                }
            }
            return (GraphPackStore(cacheRoot: temp, refreshCatalogOnInit: false), temp)
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
        let router = OnDeviceRouter(pack: pack)
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

    @Test("September 13 Nova Scotia routes replay on the accepted pack")
    func september13NovaScotiaRoutes() throws {
        let pack = try loadPack("ns")
        let router = OnDeviceRouter(pack: pack)
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
        let (store, temp) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        let from = CLLocationCoordinate2D(latitude: 44.764830, longitude: -63.340243)
        let to = CLLocationCoordinate2D(latitude: 47.903181, longitude: -66.074515)
        let began = ProcessInfo.processInfo.systemUptime
        let result = await store.routeOnDeviceDetailed(from: from, to: to, profile: RouteProfile.dirt, allowUnknown: false, sessionSeed: 20260913)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        switch result {
        case .success(let route):
            print("[accepted-replay] case=ns-nb profile=dirt seconds=\(String(format: "%.3f", elapsed)) meters=\(Int(route.distanceMeters)) dirt=\(route.reportedDirtPercent) repeated=\(Int(route.backtrackMeters))")
            #expect(route.coordinates.count > 2)
        case .failure(let failure):
            Issue.record("Accepted NS/NB seam replay failed: \(failure)")
        }
    }

    @Test("Accepted short itinerary stays a single rider leg")
    @MainActor
    func shortItineraryDoesNotInventFuelStops() async throws {
        let (store, temp) = try fixtureStore()
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
        #expect(result.legs.count == 1)
        #expect(result.legs.first?.endsAtFuelStop == nil)
        #expect(result.riderLegStatus.values.allSatisfy {
            if case .built = $0 { return true }
            return false
        })
    }
    @Test("All historical oracle requests replay through the real pack source")
    @MainActor
    func allOracleFuelWorkflows() async throws {
        let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/pack-fabric/bench/routing-oracle-cases.json")
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as? [String: Any])
        let cases = try #require(fixture["scenarios"] as? [[String: Any]])
        let seed = UInt64(try #require(fixture["sessionSeed"] as? Int))
        let tank = Double(try #require(fixture["tankRangeKm"] as? Int)) * 1000
        let usable = tank * (1 - Double(try #require(fixture["reservePercent"] as? Int)) / 100)
        let (store, temp) = try fixtureStore()
        defer { try? FileManager.default.removeItem(at: temp) }
        for scenario in cases {
            let id = try #require(scenario["id"] as? String)
            let a = try #require(scenario["from"] as? [String: Double])
            let b = try #require(scenario["to"] as? [String: Double])
            let from = RouteCoordinate(longitude: try #require(a["lon"]), latitude: try #require(a["lat"]))
            let to = RouteCoordinate(longitude: try #require(b["lon"]), latitude: try #require(b["lat"]))
            for profile in [RouteProfile.cleanest, .balanced, .dirt] {
                let source = PackRoutingSource(packs: store, cache: RouteResponseCache())
                var current = from, prior: [String] = [], arrival: String?
                var excluded: [String] = [], force = false, reached = false
                var routes: [RouteResponse] = [], stops: [FuelChainStop] = [], windows: [Any] = []
                var failure: String?
                let began = ProcessInfo.processInfo.systemUptime
                for attempt in 1...16 {
                    var request = FuelChainRequest(profile: profile, from: current, to: to, allowUnknown: false,
                        usableRangeMeters: usable, firstLegMaxMeters: usable, requireFuelStopBeforeEnd: force,
                        minimumFuelStops: force ? 1 : 0, profileMeters: 0, riderLegId: "\(id):\(profile.rawValue)",
                        avoidMotorways: profile == .cleanest, priorEdgeIds: prior, arrivalEdgeId: arrival,
                        backtrackFactor: 4, excludedStationIds: excluded, windowMaxStops: 1,
                        allowPartialWindow: true, windowTimeBudgetMs: 15000, forwardFeeler: false)
                    var options = request.options ?? RouteRequestOptions()
                    options.sessionSeed = seed; request.options = options
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
                        do { route = try await source.route(routeRequest) }
                        catch {
                            windows.append(["routeRequest": try object(routeRequest), "error": error.localizedDescription])
                            if let stop { excluded.append(stop.id); continue }
                            if !force { force = true; continue }
                            throw error
                        }
                        routes.append(route)
                        for segment in route.segments ?? [] {
                            if let edge = segment.edgeId, !edge.isEmpty {
                                if !prior.contains(edge) { prior.append(edge) }; arrival = edge
                            }
                        }
                        guard let stop else { reached = true; break }
                        stops.append(stop); current = target; excluded.append(stop.id); force = false
                        if attempt == 16 { failure = "forward-attempt-limit" }
                    } catch { failure = error.localizedDescription; break }
                }
                let evidence: [String: Any] = ["scenario": scenario, "profile": profile.rawValue,
                    "seed": seed, "tankMeters": tank, "usableMeters": usable,
                    "reachedDestination": reached, "requestedDestination": try object(to), "reachedEndpoint": try object(routes.last?.coordinates.last ?? from),
                    "failure": failure as Any? ?? NSNull(), "routes": try object(routes), "stops": try object(stops), "windows": windows]
                try saveEvidence(evidence, name: "oracle-\(id)-\(profile.rawValue)")
                print("[accepted-oracle] case=\(id) profile=\(profile.rawValue) reached=\(reached) seconds=\(ProcessInfo.processInfo.systemUptime-began) meters=\(routes.reduce(0) { $0 + ($1.distanceMeters ?? 0) }) stops=\(stops.map(\.id)) failure=\(failure ?? "none")")
                #expect(reached, "Oracle did not reach requested destination: \(id)/\(profile.rawValue): \(failure ?? "unknown")")
            }
        }
    }

}
