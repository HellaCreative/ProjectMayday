import Foundation
import CryptoKit
import CoreLocation
import Testing
import DirtRoutingEngine
@testable import Dirt

/// Opt-in qualification through the same session and response conversion used by
/// the app. Reads immutable host fixtures unless the separate download opt-in
/// enables verification of the published candidate in the test app's pack cache.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DIRT_QUALIFY_CANDIDATE"] == "1"))
struct NativeCandidateQualificationTests {
    private var root: URL {
        if let path = ProcessInfo.processInfo.environment["DIRT_QUALIFY_PACK_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/pack-fabric/routing/candidates/fabric-v4-20260917-02/packs")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRT_QUALIFY_CALIFORNIA"] == "1"),
          .timeLimit(.minutes(3)))
    func californiaArizonaDirtCompletesWithLegalAccessThroughAppAdapter() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["DIRT_QUALIFY_CALIFORNIA_PACK_ROOT"])
        let packRoot = URL(fileURLWithPath: directory, isDirectory: true)
        let directories = Dictionary(uniqueKeysWithValues: ["ca-s", "az"].map { ($0, packRoot.appendingPathComponent($0)) })
        let request = RidePreferenceContext.$current.withValue(
            .init(wander: 0.5, avoidCities: true, avoidHighways: true)) {
            RouteRequest(profile: .dirt, locations: [
                .init(latitude: 32.82610321044922, longitude: -114.82572937011719, label: "California"),
                .init(latitude: 32.68992233276367, longitude: -114.58694458007812, label: "Arizona")
            ], allowUnknown: false, sessionSeed: 1, matchLimitMeters: 250)
        }
        let native = try NativeRoutingAdapter.request(request)
        #expect(native.access.avoidFerries && !native.access.allowUnknown)
        #expect(native.profile.avoidMajorHighways && native.options.cityWall)
        let started = ContinuousClock.now
        let route = try await NativeRoutingSession().route(native, directories: directories)
        #expect(route.limit == nil)
        #expect(route.start.coordinate.distance(to: native.start) <= 250)
        #expect(route.end.coordinate.distance(to: native.end) <= 250)
        #expect(route.segments.allSatisfy { $0.access != 2 && $0.access != 5 && $0.structure != "ferry" })
        #expect(RouteQuality(route: route).reriddenMeters <= 100)
        verifyShortUnknownConnectors(route)
        let response = NativeRoutingAdapter.response(route, style: .dirt)
        #expect(response.coordinates.count > 2)
        #expect(abs((response.distanceMeters ?? 0) - route.distanceMeters) < 1)
        report("california-arizona-legal-probe", started: started, route: route)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRT_QUALIFY_STREAM_BRIDGE"] == "1"),
          .timeLimit(.minutes(5)))
    func publishedTwoPackProgressDrainsBeforeReturningTheSameRoute() async throws {
        let store = GraphPackStore()
        await store.refreshCatalog()
        for id in ["nb", "pe"] { try #require(store.hasCompleteNativePack(id)) }
        let source = PackRoutingSource(packs: store, cache: RouteResponseCache())
        let request = RouteRequest(profile: .cleanest, locations: [
            .init(latitude: 46.0878, longitude: -64.7782, label: "Moncton"),
            .init(latitude: 46.2382, longitude: -63.1316, label: "Charlottetown")
        ], allowUnknown: false, sessionSeed: 8026290980254235,
            avoidMotorways: false, preferBackRoads: false)
        let original = try await source.route(request)
        var events: [String] = []
        var stages: [RouteResponse] = []
        var completed: RouteResponse?
        let observed = try await source.route(request) { event in
            switch event {
            case .started: events.append("started")
            case .stage(let index, let response):
                events.append("stage:\(index)"); stages.append(response)
            case .leg: Issue.record("Short route must not generate long-ride legs")
            case .completed(let response):
                events.append("completed"); completed = response
            case .discarded: events.append("discarded")
            }
        }
        #expect(events == ["started", "stage:0", "stage:1", "completed"])
        #expect(stages.count == 2)
        #expect(completed?.coordinates == observed.coordinates)
        #expect(observed.coordinates == original.coordinates)
        #expect(observed.distanceMeters == original.distanceMeters)
        #expect(observed.arrivalEdgeId == original.arrivalEdgeId)
        #expect(stages.first?.coordinates.last == stages.last?.coordinates.first)
        print("CANDIDATE ordered-app-bridge events=\(events.joined(separator: ",")) meters=\(observed.distanceMeters ?? 0)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRT_QUALIFY_DOWNLOADS"] == "1"),
          .timeLimit(.minutes(5)))
    func publishedCandidateInstallsVerifiesAndRoutesThroughTheApp() async throws {
        let expected = try #require(ProcessInfo.processInfo.environment["DIRT_QUALIFY_FABRIC"])
        #expect(AppConfig.v4CandidateReleaseId == expected)
        let store = GraphPackStore()
        await store.refreshCatalog()
        #expect(store.lastManifestVersion == expected)
        if let scopedIDs = ProcessInfo.processInfo.environment["DIRT_QUALIFY_EXPECTED_REGIONS"] {
            let expectedIDs = Set(scopedIDs.split(separator: ",").map(String.init))
            let (data, response) = try await URLSession.shared.data(from: AppConfig.packManifestURL)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(catalog["version"] as? String == expected)
            let rows = try #require(catalog["regions"] as? [[String: Any]])
            let publishedIDs = rows.compactMap { $0["id"] as? String }
            #expect(Set(publishedIDs) == expectedIDs)
            #expect(publishedIDs.count == expectedIDs.count)
            #expect(Set(store.regions.filter { store.isRoutingPackPublished($0.id) }.map(\.id)) == expectedIDs)
            let neighbors = try #require(catalog["roadNeighbors"] as? [String: [String]])
            #expect(Set(neighbors.keys) == expectedIDs)
            #expect(neighbors.values.allSatisfy { Set($0).isSubset(of: expectedIDs) })
            for id in expectedIDs {
                #expect(store.resolveCatalogRegionId(id) == id)
            }
            for excluded in ["ca-n", "ca-s"] where !expectedIDs.contains(excluded) {
                #expect(!store.isRoutingPackPublished(excluded))
                #expect(store.resolveCatalogRegionId(excluded) == nil)
            }
            print("CANDIDATE published-catalog-registry regions=\(expectedIDs.count) release=\(expected)")
        }
        let islandTrip = [CLLocationCoordinate2D(latitude: 44.696743, longitude: -63.485973),
                          CLLocationCoordinate2D(latitude: 46.2382, longitude: -63.1316)]
        #expect(Set(store.requiredCatalogRoutingRegions(for: islandTrip)) == ["ns", "nb", "pe"])
        let startedInstall = ContinuousClock.now
        try await store.installVerifiedPacks(["pe", "nb"], replaceInstalled: true)
        for id in ["pe", "nb"] {
            #expect(store.hasCompleteNativePack(id))
            #expect(store.packRevisionState(id) == .current)
        }
        let points = [CLLocationCoordinate2D(latitude: 46.1636391, longitude: -63.8150711),
                      CLLocationCoordinate2D(latitude: 46.2202911, longitude: -63.740036)]
        let directories = try store.routingDirectories(for: points)
        #expect(Set(directories.keys) == ["nb", "pe"])
        let repository = try PackRepository(installedDirectories: directories)
        for id in directories.keys {
            #expect(try repository.open(id, requireSeams: true).manifest.fabricReleaseId == expected)
        }
        let identities = ["pe", "nb"].map { store.installedPackIdentity(regionId: $0) }
        try await store.installVerifiedPacks(["pe", "nb"], replaceInstalled: false)
        #expect(identities == ["pe", "nb"].map { store.installedPackIdentity(regionId: $0) })
        let request = RoutingRequest(start: .init(longitude: points[0].longitude, latitude: points[0].latitude),
            end: .init(longitude: points[1].longitude, latitude: points[1].latitude), style: .cleanest, seed: 1)
        let route = try await NativeRoutingSession().route(request, directories: directories)
        #expect(route.limit == nil)
        #expect(route.end.coordinate.distance(to: request.end) <= 250)
        #expect(route.segments.contains { $0.edgeID.hasPrefix("646650186:") || $0.edgeID.hasPrefix("w646650186:") })
        #expect(route.segments.allSatisfy { $0.structure != "ferry" && $0.access == 0 })
        report("published-download-verify-reuse-bridge", started: startedInstall, route: route)
    }

    @Test(.timeLimit(.minutes(3)))
    func southernQuebecColdAndWarmRemainWithinAppLimits() async throws {
        let directories = ["qc-s": root.appendingPathComponent("qc-s")]
        let session = NativeRoutingSession()
        var firstRoads: [String]?
        for run in 0...1 {
            var request = RoutingRequest(start: .init(longitude: -73.5673, latitude: 45.5017),
                end: .init(longitude: -71.2075, latitude: 46.8139), style: .dirt, allowUnknown: false, seed: 1)
            request.profile.wander = 0.5
            request.profile.avoidMajorHighways = true
            request.options.cityWall = true
            let started = ContinuousClock.now
            let route = try await session.route(request, directories: directories)
            #expect(route.limit == nil)
            #expect(route.end.coordinate.distance(to: request.end) <= 250)
            verifyShortUnknownConnectors(route)
            #expect(RouteQuality(route: route).reriddenMeters == 0)
            #expect(ProcessMemory.megabytes().peak < 1_300)
            let roads = route.segments.map(\.edgeID)
            if let firstRoads { #expect(roads == firstRoads) } else { firstRoads = roads }
            report("qc-s-dirt-run\(run)", started: started, route: route)
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func denseContinentalRidesCompleteColdAndWarmThroughAppSession() async throws {
        let cases: [(String, [String], Coordinate, Coordinate)] = [
            ("kitchener-barrie", ["on-s"],
             .init(longitude: -80.4925, latitude: 43.4516), .init(longitude: -79.6903, latitude: 44.3894)),
            ("austin-houston", ["tx-sw", "tx-se"],
             .init(longitude: -97.7431, latitude: 30.2672), .init(longitude: -95.3698, latitude: 29.7604)),
            ("los-angeles-san-diego", ["ca-s"],
             .init(longitude: -118.2437, latitude: 34.0522), .init(longitude: -117.1611, latitude: 32.7157))
        ]
        for (name, regions, start, end) in cases {
            let session = NativeRoutingSession()
            let directories = Dictionary(uniqueKeysWithValues: regions.map { ($0, root.appendingPathComponent($0)) })
            var firstRoads: [String]?
            for run in 0...1 {
                var request = RoutingRequest(start: start, end: end, style: .dirt, allowUnknown: false, seed: 1)
                request.profile.wander = 0.5
                request.profile.avoidMajorHighways = true
                request.access.avoidFerries = true
                request.options.cityWall = true
                let started = ContinuousClock.now
                let route = try await session.route(request, directories: directories)
                #expect(started.duration(to: .now) < .seconds(180))
                #expect(route.limit == nil)
                #expect(route.start.coordinate.distance(to: start) <= 250)
                #expect(route.end.coordinate.distance(to: end) <= 250)
                #expect(route.segments.allSatisfy { ![2, 5].contains($0.access) && $0.structure != "ferry" })
                verifyShortUnknownConnectors(route)
                #expect(RouteQuality(route: route).reriddenMeters <= 100)
                let roads = route.segments.map { "\($0.edgeID):\($0.forward)" }
                if let firstRoads { #expect(roads == firstRoads) } else { firstRoads = roads }
                // The host matrix measures isolated per-process RSS. This app
                // report also retains the process-lifetime footprint peak; it
                // must not be mislabeled as a reset, per-request peak.
                #expect(ProcessMemory.megabytes().peak < 1_300)
                report("dense-\(name)-run\(run)", started: started, route: route)
            }
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func confederationBridgeCompletesBothDirectionsInEveryStyle() async throws {
        let directories = Dictionary(uniqueKeysWithValues: ["nb", "pe"].map { ($0, root.appendingPathComponent($0)) })
        let repository = try PackRepository(installedDirectories: directories)
        for id in ["nb", "pe"] {
            let installed = try repository.open(id, requireSeams: true)
            if let expected = ProcessInfo.processInfo.environment["DIRT_QUALIFY_FABRIC"] {
                #expect(installed.manifest.fabricReleaseId == expected)
            }
        }
        let points = [Coordinate(longitude: -63.8150711, latitude: 46.1636391),
                      Coordinate(longitude: -63.740036, latitude: 46.2202911)]
        for reversed in [false, true] {
            let session = NativeRoutingSession()
            for style: RidingStyle in [.dirt, .balanced, .cleanest] {
                for repeatRun in 0...1 {
                    var request = RoutingRequest(start: points[reversed ? 1 : 0],
                        end: points[reversed ? 0 : 1], style: style, allowUnknown: false, seed: 1)
                    request.profile.wander = 0.5
                    request.profile.avoidMajorHighways = true
                    request.options.cityWall = true
                    let started = ContinuousClock.now
                    let route = try await session.route(request, directories: directories)
                    #expect(route.limit == nil)
                    #expect(route.start.coordinate.distance(to: request.start) <= 250)
                    #expect(route.end.coordinate.distance(to: request.end) <= 250)
                    #expect(route.segments.allSatisfy { $0.structure != "ferry" && $0.access == 0 })
                    #expect(route.segments.contains { $0.edgeID.hasPrefix("646650186:") || $0.edgeID.hasPrefix("w646650186:") })
                    #expect(RouteQuality(route: route).reriddenMeters == 0)
                    let response = NativeRoutingAdapter.response(route, style: style)
                    let reopened = try JSONDecoder().decode(RouteResponse.self, from: JSONEncoder().encode(response))
                    #expect(reopened.geometry == response.geometry)
                    report("bridge-\(reversed ? "reverse" : "forward")-\(style.rawValue)-run\(repeatRun)", started: started, route: route)
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(5)))
    func ontarioRideVarietyAndFrozenResponse() async throws {
        let session = NativeRoutingSession()
        let directories = ["on-s": root.appendingPathComponent("on-s")]
        var first: [String] = [], signatures = Set<String>()
        for seed: UInt64 in [1, 2, 3, 1] {
            let req = RidePreferenceContext.$current.withValue(
                .init(wander: 1, avoidCities: true, avoidHighways: true)) {
                RouteRequest(profile: .dirt, locations: [
                    .init(latitude: 43.4516, longitude: -80.4925, label: "Kitchener"), .init(latitude: 44.3894, longitude: -79.6903, label: "Barrie")
                ], allowUnknown: false, sessionSeed: seed, matchLimitMeters: 250)
            }
            let native = try NativeRoutingAdapter.request(req)
            #expect(native.profile.appetite == 1)
            #expect(native.profile.avoidMajorHighways && native.options.cityWall)
            #expect(!native.access.allowUnknown)
            let started = ContinuousClock.now
            let route = try await session.route(native, directories: directories)
            let quality = RouteQuality(route: route)
            #expect(route.limit == nil)
            // Record the actual mix below. The owner removed the universal
            // Dirt percentage floor; access, shape, variety and reporting still qualify.
            #expect(quality.reriddenMeters == 0)
            let graph = try PackRepository(installedDirectories: directories).open("on-s").graph
            #expect(!RouteQuality.hasClosedRoadCircuit(route.segments, in: graph))
            verifyShortUnknownConnectors(route)
            #expect(route.start.coordinate.distance(to: native.start) <= 250)
            #expect(route.end.coordinate.distance(to: native.end) <= 250)
            let response = NativeRoutingAdapter.response(route, style: .dirt)
            let data = try JSONEncoder().encode(response)
            let reopened = try JSONDecoder().decode(RouteResponse.self, from: data)
            #expect(reopened.geometry == response.geometry)
            #expect(reopened.dirtPercent == response.dirtPercent)
            let painted = RouteSurfaceComposition.from(responses: [response])
            #expect(abs(painted.dirtPercent - response.dirtPercent) <= 1)
            let roads = route.segments.map(\.edgeID)
            if seed == 1 {
                if first.isEmpty { first = roads } else { #expect(roads == first) }
            }
            signatures.insert(roads.joined(separator: "|"))
            report("ontario-seed-\(seed)", started: started, route: route)
        }
        #expect(signatures.count == 3)
    }

    @Test(.timeLimit(.minutes(5)))
    func crossCanadaKeepsRiderDestinationAndBoundsWorkingMemory() async throws {
        let regions = ["ns", "nb", "qc-s", "on-n", "mb", "sk", "ab", "bc"]
        let directories = Dictionary(uniqueKeysWithValues: regions.map { ($0, root.appendingPathComponent($0)) })
        let session = NativeRoutingSession()
        var firstHash: String?
        for run in 1...2 {
            var request = RoutingRequest(start: .init(longitude: -63.5752, latitude: 44.6488),
                end: .init(longitude: -123.1558, latitude: 49.7016), style: .dirt, allowUnknown: false, seed: 1)
            request.profile.wander = 1; request.profile.avoidMajorHighways = true; request.options.cityWall = true
            let started = ContinuousClock.now
            let route = try await session.route(request, directories: directories)
            #expect(route.limit == nil)
            #expect(route.end.coordinate.distance(to: request.end) <= 250)
            verifyShortUnknownConnectors(route)
            let hash = SHA256.hash(data: Data((route.segments.map(\.edgeID).joined(separator: "\n") + "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            if let firstHash { #expect(hash == firstHash) } else { firstHash = hash }
            // A continental ride must report its actual surfaces honestly;
            // it must not fail solely for falling below a fixed Dirt percentage.
            let response = NativeRoutingAdapter.response(route, style: .dirt)
            let reopened = try JSONDecoder().decode(RouteResponse.self, from: JSONEncoder().encode(response))
            #expect(reopened.geometry == response.geometry)
            #expect(reopened.dirtPercent == response.dirtPercent)
            let painted = RouteSurfaceComposition.from(responses: [response])
            #expect(abs(painted.dirtPercent - response.dirtPercent) <= 1)
            #expect(RouteQuality(route: route).reriddenMeters == 0)
            #expect(ProcessMemory.megabytes().peak < 1_300)
            report("canada-\(run)", started: started, route: route)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func ownerHalifaxStStephenRespectsUnknownConnectorSetting() async throws {
        let directories = Dictionary(uniqueKeysWithValues: ["ns", "nb"].map { ($0, root.appendingPathComponent($0)) })
        let session = NativeRoutingSession()
        for unknown in [false, true] {
            let req = RidePreferenceContext.$current.withValue(
                .init(wander: 1, avoidCities: true, avoidHighways: true)) {
                RouteRequest(profile: .dirt, locations: [
                    .init(latitude: 44.696743, longitude: -63.485973, label: "Owner start"),
                    .init(latitude: 45.213841, longitude: -67.296321, label: "St Stephen")
                ], allowUnknown: unknown, sessionSeed: 1, matchLimitMeters: 250)
            }
            let native = try NativeRoutingAdapter.request(req)
            let started = ContinuousClock.now
            let route = try await session.route(native, directories: directories)
            #expect(route.limit == nil)
            #expect(route.end.coordinate.distance(to: native.end) <= 250)
            #expect(route.segments.allSatisfy { $0.access != 2 && $0.access != 5 })
            let uncertainMeters = route.segments.filter { $0.access == 1 }.reduce(0) { $0+$1.meters }
            #expect(uncertainMeters > 0)
            if !unknown { verifyShortUnknownConnectors(route) }
            let response = NativeRoutingAdapter.response(route, style: .dirt)
            #expect(response.segments?.contains { $0.accessClass == "motorized_unknown" } == true)
            report("owner-nsnb-unknown-\(unknown)", started: started, route: route)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func ownerBridgeMidpointCompletesBothDirectionsAndStyles() async throws {
        let directories = Dictionary(uniqueKeysWithValues: ["ns","nb"].map { ($0, root.appendingPathComponent($0)) })
        let session = NativeRoutingSession()
        let owner = Coordinate(longitude: -63.340266, latitude: 44.764843)
        let bridge = Coordinate(longitude: -63.774129, latitude: 46.193790)
        for style: RidingStyle in [.dirt, .balanced, .cleanest] {
            for reverse in [false, true] {
                var request = RoutingRequest(start: reverse ? bridge : owner, end: reverse ? owner : bridge,
                    style: style, allowUnknown: false, seed: 1)
                request.mapZoom = 9.2
                request.profile.wander = 0.5
                request.options.cityWall = true
                request.profile.avoidMajorHighways = true
                let started = ContinuousClock.now
                let route = try await session.route(request, directories: directories)
                #expect(route.limit == nil)
                #expect(route.start.coordinate.distance(to: request.start) < 250)
                #expect(route.end.coordinate.distance(to: request.end) < 250)
                let bridgeSegment = reverse ? route.segments.first : route.segments.last
                #expect(bridgeSegment?.edgeID.contains("646650186") == true)
                verifyShortUnknownConnectors(route)
                #expect(RouteQuality(route: route).reriddenMeters == 0)
                report("owner-bridge-\(style.rawValue)-reverse\(reverse)", started: started, route: route)
            }
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func ownerLabradorIncludesTheFerryLandingRegion() async throws {
        let ids = ["ns", "nb", "qc-s", "qc-n", "nl-island", "nl-lab"]
        let directories = Dictionary(uniqueKeysWithValues: ids.map { ($0, root.appendingPathComponent($0)) })
        let session = NativeRoutingSession()
        var request = RoutingRequest(start: .init(longitude: -63.340289, latitude: 44.764859),
            end: .init(longitude: -60.364640, latitude: 53.293419), style: .dirt,
            allowUnknown: false, seed: 4449227719714105)
        request.mapZoom = 12.5
        request.profile.wander = 0.5
        request.options.cityWall = true
        request.profile.avoidMajorHighways = true
        // Replay the owner's historical ferry-permitted request explicitly;
        // new rides default to avoiding ferries in the app preference adapter.
        request.access.avoidFerries = false
        for run in 0...1 {
            let started = ContinuousClock.now
            let route = try await session.route(request, directories: directories)
            #expect(route.end.coordinate.distance(to: request.end) < 250)
            #expect(route.start.coordinate.distance(to: request.start) < 250)
            verifyShortUnknownConnectors(route)
            for (a, b) in zip(route.segments, route.segments.dropFirst()) {
                #expect(try #require(a.geometry.last).distance(to: #require(b.geometry.first)) < 1)
            }
            #expect(route.searchSummary?.contains("nl-island+qc-n") == true)
            #expect(Set(route.segments.filter { $0.structure == "ferry" }.map { $0.edgeID.split(separator: ":")[0] }).count == 2)
            let response = NativeRoutingAdapter.response(route, style: .dirt)
            #expect(response.status == "complete")
            #expect(route.limit == nil)
            #expect(response.warnings?.contains { $0.code == "search_incomplete" } != true)
            // Qualify the actual landing and legal journey above. Which other
            // regional connections were considered is not a riding requirement.
            report("owner-labrador-run\(run)", started: started, route: route)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func ownerPeiSpeedReplayColdAndWarm() async throws {
        let directories = Dictionary(uniqueKeysWithValues: ["ns","nb","pe"].map { ($0, root.appendingPathComponent($0)) })
        let session = NativeRoutingSession()
        for run in 0...1 {
            var request = RoutingRequest(start: .init(longitude: -63.340266, latitude: 44.764843),
                end: .init(longitude: -64.402863, latitude: 46.676426), style: .dirt, allowUnknown: false, seed: 1)
            request.mapZoom = 10.6
            request.profile.wander = 0.5
            request.options.cityWall = true
            request.profile.avoidMajorHighways = true
            let started = ContinuousClock.now
            let route = try await session.route(request, directories: directories)
            #expect(route.limit == nil)
            #expect(route.end.coordinate.distance(to: request.end) < 250)
            verifyShortUnknownConnectors(route)
            #expect(RouteQuality(route: route).reriddenMeters == 0)
            report("owner-pei-speed-run\(run)", started: started, route: route)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func ownerCapeBretonInsertedWaypointsContinueAtMatchedRoad() async throws {
        let source = WaypointNativeReplaySource(directories: ["ns": root.appendingPathComponent("ns")])
        let cases: [[RouteCoordinate]] = [
            [.init(longitude: -63.340242, latitude: 44.764801),
             .init(longitude: -61.32647093974907, latitude: 45.77566149968744),
             .init(longitude: -60.474758, latitude: 46.986049)],
            [.init(longitude: -63.340206, latitude: 44.764840),
             .init(longitude: -60.43133042857463, latitude: 46.509154854013474),
             .init(longitude: -60.339340, latitude: 46.814511)]
        ]
        for (index, points) in cases.enumerated() {
            let itinerary = reduce(RiderItinerary(), .replaceAll(waypoints: points, profile: .dirt,
                allowUnknown: false, avoidMotorways: true, preferBackRoads: false)).itinerary
            let builder = ItineraryBuilder()
            builder.mapZoom = index == 0 ? 8.1 : 8.2
            source.requests.removeAll()
            let result = await RidePreferenceContext.$current.withValue(
                .init(wander: 1, avoidCities: true, avoidHighways: true)) {
                await RoutingSessionContext.$seed.withValue(1) {
                    await builder.build(itinerary, from: 0, reuse: nil, fuel: .routeOnly,
                        source: .fixed(source), onProgress: { _ in })
                }
            }
            #expect(result.riderLegStatus.values.allSatisfy { $0 == .built })
            #expect(result.legs.count == 2)
            #expect(itinerary.waypoints.map(\.coordinate) == points)
            let first = try #require(result.legs.first)
            let last = try #require(result.legs.last)
            let end = try #require(last.response.coordinates.last)
            #expect(Coordinate(longitude: end.longitude, latitude: end.latitude).distance(
                to: .init(longitude: points[2].longitude, latitude: points[2].latitude)) < 250)
            #expect(first.response.coordinates.last == last.response.coordinates.first)
            #expect(source.requests.count == 2)
            let continuation = try #require(source.requests.last)
            #expect(continuation.options?.arrivalEdgeId == first.response.arrivalEdgeId)
            #expect(continuation.locations.first?.latitude == first.response.coordinates.last?.latitude)
            #expect(continuation.locations.first?.longitude == first.response.coordinates.last?.longitude)
            print("WAYPOINT owner-case=\(index+1) complete=\(result.legs.count == 2) continuous=\(first.response.coordinates.last == last.response.coordinates.first)")
        }
    }

    // Audit the returned itinerary, including joins, independently of search labels.
    private func verifyShortUnknownConnectors(_ route: ComputedRoute) {
        var run = 0.0
        var previous: UInt8?
        for segment in route.segments where segment.meters > 0.01 {
            #expect(segment.access != 2 && segment.access != 5)
            if segment.access == 1 {
                if run == 0 { #expect(previous == 0) }
                run += segment.meters
                #expect(run <= 100)
            } else {
                if run > 0 { #expect(segment.access == 0) }
                run = 0
            }
            previous = segment.access
        }
        #expect(run == 0)
    }

    @Test(.timeLimit(.minutes(10)))
    func ferryChoiceOwnerRequestsThroughAppAdapter() async throws {
        let session = NativeRoutingSession()
        let cases: [(String, Double, Double, UInt64, Double, Bool)] = [
            ("pei-bridge", -63.669072, 46.260319, 5275785009779777, 12, true),
            ("quebec-mainland", -66.37367732134696, 50.21154046857525, 8923365313346608, 7.5, false),
            ("labrador-mainland", -56.1224962260599, 52.75449672754457, 3345497217482049, 12.3, false),
            ("newfoundland", -56.518567, 51.398736, 1223774934041503, 8.9, true)]
        for (name, lon, lat, seed, zoom, highway) in cases {
            let ids: [String]
            switch name {
            case "pei-bridge": ids = ["ns", "nb", "pe"]
            case "newfoundland": ids = ["ns", "nl-island"]
            case "quebec-mainland": ids = ["ns", "nb", "qc-s", "qc-n", "nl-island"]
            default: ids = ["ns", "nb", "qc-s", "qc-n", "nl-island", "nl-lab"]
            }
            let directories = Dictionary(uniqueKeysWithValues: ids.map { ($0, root.appendingPathComponent($0)) })
            for avoid in [true, false] {
                let preferences = RidePreferences(wander: 0.5, avoidCities: true,
                    avoidHighways: highway, avoidFerries: avoid)
                let appRequest = RidePreferenceContext.$current.withValue(preferences) {
                    RouteRequest(profile: .dirt, locations: [
                        .init(latitude: name == "quebec-mainland" ? 44.764799 : 44.764845,
                              longitude: name == "quebec-mainland" ? -63.340282 : -63.340271, label: "Start"),
                        .init(latitude: lat, longitude: lon, label: "End")], allowUnknown: false,
                        sessionSeed: seed, mapZoom: zoom)
                }
                let request = try NativeRoutingAdapter.request(appRequest)
                #expect(request.access.avoidFerries == avoid)
                let started = ContinuousClock.now
                if name == "newfoundland" && avoid {
                    do {
                        _ = try await session.route(request, directories: directories)
                        Issue.record("Ferry avoidance must require explicit opt-in for Newfoundland")
                    } catch RoutingFailure.ferriesAvoided { }
                    continue
                }
                let route = try await session.route(request, directories: directories)
                #expect(route.limit == nil)
                #expect(route.end.coordinate.distance(to: request.end) < 250)
                #expect(route.start.coordinate.distance(to: request.start) < 250)
                #expect(route.segments.allSatisfy { ![2,5].contains($0.access) })
                if avoid { #expect(route.segments.allSatisfy { $0.structure != "ferry" }) }
                if name == "pei-bridge" && avoid {
                    #expect(route.segments.contains { $0.edgeID.hasPrefix("646650186:") || $0.edgeID.hasPrefix("w646650186:") })
                }
                if name == "newfoundland" { #expect(route.segments.contains { $0.structure == "ferry" }) }
                for (a, b) in zip(route.segments, route.segments.dropFirst()) {
                    #expect(try #require(a.geometry.last).distance(to: #require(b.geometry.first)) < 1)
                }
                verifyShortUnknownConnectors(route)
                let response = NativeRoutingAdapter.response(route, style: .dirt)
                #expect(try JSONDecoder().decode(RouteResponse.self, from: JSONEncoder().encode(response)).status == "complete")
                report("ferry-choice-\(name)-avoid\(avoid)", started: started, route: route)
            }
        }
    }

    private func report(_ name: String, started: ContinuousClock.Instant, route: ComputedRoute) {
        let d = started.duration(to: .now).components
        let seconds = Double(d.seconds) + Double(d.attoseconds) / 1e18
        let q = RouteQuality(route: route)
        print("CANDIDATE \(name) seconds=\(seconds) km=\(route.distanceMeters/1000) dirt=\(q.knownDirtPercent) repeatM=\(q.reriddenMeters) nearbyReturnM=\(q.returnMeters) peakFootprintMB=\(ProcessMemory.megabytes().peak)")
    }
}

@MainActor
private final class WaypointNativeReplaySource: RoutingSource {
    let name = "pack-waypoint-replay"
    let directories: [String: URL]
    let session = NativeRoutingSession()
    var requests: [RouteRequest] = []
    init(directories: [String: URL]) { self.directories = directories }
    func route(_ request: RouteRequest) async throws -> RouteResponse {
        requests.append(request)
        let native = try NativeRoutingAdapter.request(request)
        let route = try await session.route(native, directories: directories)
        return NativeRoutingAdapter.response(route, style: native.profile.style)
    }
    func fuelChain(_ request: FuelChainRequest) async throws -> FuelChainResponse {
        throw RoutingFailure.unsupported("Fuel must not participate in waypoint editing")
    }
    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? { nil }
}
