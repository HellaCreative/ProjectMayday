//
//  DirtTests.swift
//  DirtTests
//
//  Created by Richard Smith on 7/25/26.
//

import CryptoKit
import CoreLocation
import Foundation
import Testing
@testable import Dirt
import DirtRoutingEngine

struct DirtTests {
    @Test func debugBuildUsesIsolatedDevelopmentBackends() {
        #expect(AppConfig.backendEnvironment == .development)
        #expect(AppConfig.supabaseURL.host == "xoufaiypnrgukzmdwicz.supabase.co")
        #expect(AppConfig.baseURL.host == "pack-fabric.vercel.app")
        #expect(AppConfig.routeURL.absoluteString == "https://pack-fabric.vercel.app/api/route")
        #expect(AppConfig.liveFuelURL.absoluteString == "https://pack-fabric.vercel.app/api/fuel")
        #expect(AppConfig.liveFuelChainURL.absoluteString == "https://pack-fabric.vercel.app/api/fuel-chain")
        #expect(AppConfig.livePOIURL.absoluteString == "https://pack-fabric.vercel.app/api/poi")
        #expect(AppConfig.v4CandidateReleaseId == "fabric-v4-20260917-01")
        #expect(AppConfig.packManifestURL.absoluteString ==
            "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/v4/candidates/" +
            "fabric-v4-20260917-01/manifest.json")
        #expect(AppConfig.riderServicesManifestURL.absoluteString ==
            "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/v4/candidates/" +
            "fabric-v4-20260917-01/rider-services/manifest.json")
        for name in ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json"] {
            #expect(AppConfig.packFileURL(version: AppConfig.v4ConnectionRevision, regionId: "on-s", fileName: name)
                == AppConfig.v4CandidateBaseURL.appendingPathComponent("on-s").appendingPathComponent(name))
        }
        #expect(AppConfig.packFileURL(version: AppConfig.v4ConnectionRevision, regionId: "on-n", fileName: "cross-pack-seams.v2.json")
            == AppConfig.v4ConnectionBaseURL.appendingPathComponent("on-n/cross-pack-seams.v2.json"))
        #expect(AppConfig.validatesSupabaseIsolation(url: AppConfig.supabaseURL))
        #expect(AppConfig.validatesRoutingIsolation(url: AppConfig.baseURL))
        #expect(!AppConfig.validatesSupabaseIsolation(
            url: URL(string: "https://wrong-project.supabase.co")!
        ))
        #expect(!AppConfig.validatesRoutingIsolation(
            url: URL(string: "https://dirt-mayday.vercel.app")!
        ))
    }

    @Test @MainActor func navigationPrepPublishesVisibleStateBeforePlanning() {
        let offline = OfflineTileManager()

        offline.beginNavigationPrepPresentation()

        #expect(offline.phase == .downloading(completed: 0, total: 0))
        #expect(offline.progress == 0)
        offline.cancelPrep()
    }

    @Test func navigationTileScopeBlocksOnlyFirstRiderOrFuelStage() throws {
        let first = [
            RouteCoordinate(longitude: -63.57, latitude: 44.64),
            RouteCoordinate(longitude: -63.82, latitude: 44.78)
        ]
        let second = [
            RouteCoordinate(longitude: -63.82, latitude: 44.78),
            RouteCoordinate(longitude: -64.15, latitude: 45.02)
        ]
        let wholeRoute = first + second.dropFirst()

        #expect(NavigationTileScope.blockingCoordinates(
            stageCoordinates: [first, second],
            fallback: wholeRoute
        ) == first)
        let lookahead = try #require(NavigationTileScope.lookaheadCoordinates(
            after: 0,
            stageCoordinates: [first, second]
        ))
        #expect(lookahead.index == 1)
        #expect(lookahead.coordinates == second)
        #expect(NavigationTileScope.lookaheadCoordinates(
            after: 1,
            stageCoordinates: [first, second]
        ) == nil)
        #expect(NavigationTileScope.blockingCoordinates(
            stageCoordinates: [],
            fallback: wholeRoute
        ) == wholeRoute)
    }

    @Test @MainActor func navigationRoutingPackScopeStartsAtFirstStageInsteadOfWholeRoute() throws {
        let novaScotia = RouteCoordinate(longitude: -63.34025, latitude: 44.76483)
        let newBrunswick = RouteCoordinate(longitude: -64.80650, latitude: 46.08652)
        let ontario = RouteCoordinate(longitude: -81.13578, latitude: 44.66843)

        let start = try #require(NavigationRoutingPackScope.startingCoordinate(
            stageCoordinates: [[novaScotia, newBrunswick], [newBrunswick, ontario]],
            fallback: [novaScotia, newBrunswick, ontario]
        ))

        #expect(start == novaScotia)
        #expect(GraphPackStore.primaryRegionId(containing: CLLocationCoordinate2D(
            latitude: start.latitude,
            longitude: start.longitude
        )) == "ns")
        #expect(NavigationRoutingPackScope.regionTransition(
            currentRegionID: "ns",
            lastPreparedRegionID: "ns"
        ) == nil)
        #expect(NavigationRoutingPackScope.regionTransition(
            currentRegionID: "nb",
            lastPreparedRegionID: "ns"
        ) == "nb")
    }

    @Test func navigationTilePlanCacheRequiresExactGeometryAndViewport() throws {
        let route = [
            RouteCoordinate(longitude: -63.5752, latitude: 44.6488),
            RouteCoordinate(longitude: -64.4935, latitude: 45.0770)
        ]
        let plan = CorridorTilePlanner.collectRouteTiles(
            coordinates: route,
            viewportWidth: 390,
            viewportHeight: 844
        )
        var cache = CorridorTilePlanCache()
        #expect(cache.plan(for: route, viewportWidth: 390, viewportHeight: 844) == nil)
        cache.store(plan, for: route, viewportWidth: 390, viewportHeight: 844)
        #expect(cache.plan(for: route, viewportWidth: 390, viewportHeight: 844)?.tiles == plan.tiles)

        var changed = route
        changed[1] = RouteCoordinate(longitude: -64.4935, latitude: 45.0870)
        #expect(cache.plan(for: changed, viewportWidth: 390, viewportHeight: 844) == nil)
        #expect(cache.plan(for: route, viewportWidth: 844, viewportHeight: 390) == nil)
        let changedPlan = CorridorTilePlanner.collectRouteTiles(coordinates: changed)
        cache.store(changedPlan, for: changed, viewportWidth: 390, viewportHeight: 844)
        #expect(cache.plan(for: route, viewportWidth: 390, viewportHeight: 844)?.tiles == plan.tiles)
    }

    @Test func navigationCorridorDistinguishesRequiredRideTilesFromBuffer() {
        let route = [
            RouteCoordinate(longitude: -63.5752, latitude: 44.6488),
            RouteCoordinate(longitude: -63.7000, latitude: 44.7000)
        ]
        let plan = CorridorTilePlanner.collectRouteTiles(coordinates: route)
        #expect(!plan.requiredTiles.isEmpty)
        #expect(plan.requiredTiles.isSubset(of: Set(plan.tiles)))
        #expect(plan.tiles.count > plan.requiredTiles.count)
    }

    @Test func navigationTileRetryIsBoundedAndTransientOnly() {
        #expect(OfflineTileManager.shouldRetry(statusCode: 429, urlErrorCode: nil, attempt: 1))
        #expect(OfflineTileManager.shouldRetry(statusCode: 503, urlErrorCode: nil, attempt: 1))
        #expect(OfflineTileManager.shouldRetry(statusCode: nil, urlErrorCode: .timedOut, attempt: 1))
        #expect(!OfflineTileManager.shouldRetry(statusCode: 404, urlErrorCode: nil, attempt: 1))
        #expect(!OfflineTileManager.shouldRetry(statusCode: 503, urlErrorCode: nil, attempt: 2))
    }

    @Test func shortbreadManifestActivatesCompatibleImmutableRelease() throws {
        let manifestURL = try #require(URL(
            string: "https://tiles.example.test/shortbread/v1/manifest.json"
        ))
        let manifest = testShortbreadManifest()
        let source = try manifest.validatedSource(manifestURL: manifestURL)

        #expect(source.provider == .dirtR2)
        #expect(source.releaseID == "maritimes-20260607")
        #expect(source.cacheNamespace == ShortbreadTileSource.publicOSM.cacheNamespace)
        #expect(source.url(z: 10, x: 331, y: 369)?.absoluteString ==
            "https://tiles.example.test/shortbread/v1/releases/maritimes-20260607/tiles/10/331/369.mvt")
    }

    @Test func shortbreadManifestRejectsSchemaOrOriginDrift() throws {
        let manifestURL = try #require(URL(
            string: "https://tiles.example.test/shortbread/v1/manifest.json"
        ))
        #expect(throws: ShortbreadTileSourceError.self) {
            try testShortbreadManifest(schema: "2.0")
                .validatedSource(manifestURL: manifestURL)
        }
        #expect(throws: ShortbreadTileSourceError.self) {
            try testShortbreadManifest(sampleHost: "other.example.test")
                .validatedSource(manifestURL: manifestURL)
        }
    }

    @Test func shortbreadStyleRewritesEveryVectorSourceToApprovedOrigin() throws {
        let source = try testShortbreadManifest().validatedSource(
            manifestURL: #require(URL(
                string: "https://tiles.example.test/shortbread/v1/manifest.json"
            ))
        )
        let styleURL = MapStyleCatalog.styleURL(for: .shortbreadRich, tileSource: source)
        let data = try Data(contentsOf: styleURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sources = try #require(root["sources"] as? [String: Any])
        let vectorSources = sources.values.compactMap { $0 as? [String: Any] }
            .filter { $0["type"] as? String == "vector" }
        #expect(!vectorSources.isEmpty)
        #expect(vectorSources.allSatisfy {
            ($0["tiles"] as? [String]) == [source.tileTemplate]
        })
    }

    @Test func generatedStyleSplitsAdminBordersAndDropsPurple() throws {
        let styleURL = MapStyleCatalog.styleURL(for: .shortbreadRich)
        let data = try Data(contentsOf: styleURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let layers = try #require(root["layers"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: layers.compactMap { layer -> (String, [String: Any])? in
            guard let id = layer["id"] as? String else { return nil }
            return (id, layer)
        })
        #expect(byID["dirt-bound-country"] != nil)
        #expect(byID["dirt-bound-state"] != nil)
        #expect(byID["dirt-bound-state-overview"] != nil)
        #expect(byID["dirt-bound-label-country"] != nil)
        #expect(byID["dirt-bound-label-state"] != nil)
        #expect(byID["boundaries-0"] == nil)
        #expect(byID["boundary_labels-named-0"] == nil)
        let countryPaint = try #require(byID["dirt-bound-country"]?["paint"] as? [String: Any])
        #expect(countryPaint["line-color"] as? String == "#7b4fa0")
        let statePaint = try #require(byID["dirt-bound-state"]?["paint"] as? [String: Any])
        #expect(statePaint["line-color"] as? String == "#9a74b8")
        let overviewPaint = try #require(byID["dirt-bound-state-overview"]?["paint"] as? [String: Any])
        #expect(overviewPaint["line-color"] as? String == "#9a74b8")
        #expect(overviewPaint["line-dasharray"] != nil)
        #expect(byID["dirt-bound-state-overview"]?["source"] as? String == "dirt-admin1-overview")
        #expect(byID["dirt-bound-state-overview"]?["source-layer"] == nil)
        #expect(intZoom(byID["dirt-bound-country"]?["minzoom"]) == 0)
        #expect(intZoom(byID["dirt-bound-state"]?["minzoom"]) == 7)
        #expect(intZoom(byID["dirt-bound-state-overview"]?["minzoom"]) == 0)
        #expect(intZoom(byID["dirt-bound-state-overview"]?["maxzoom"]) == 7)
        let town = byID.first(where: { $0.key.contains("town") })?.value
        #expect(intZoom(town?["minzoom"]) <= 7)
        if let island = byID.first(where: { $0.key.contains("island") })?.value {
            #expect(intZoom(island["minzoom"]) <= 14)
        }
        #expect(intZoom(byID["dirt-bound-label-country"]?["maxzoom"]) <= 6)
        let sources = try #require(root["sources"] as? [String: Any])
        let admin1 = try #require(sources["dirt-admin1-overview"] as? [String: Any])
        #expect(admin1["type"] as? String == "geojson")
        let collection = try #require(admin1["data"] as? [String: Any])
        #expect(collection["type"] as? String == "FeatureCollection")
        let features = try #require(collection["features"] as? [[String: Any]])
        #expect(features.count >= 40)
        #expect(features.allSatisfy { feature in
            let geom = feature["geometry"] as? [String: Any]
            let type = geom?["type"] as? String
            return type == "LineString" || type == "MultiLineString"
        })
        #expect(features.allSatisfy { feature in
            let props = feature["properties"] as? [String: Any] ?? [:]
            return props["packId"] == nil && props["regionId"] == nil
        })
    }

    @Test func bundledAdmin1OverviewIsRealPoliticalLinesNotPackBounds() throws {
        let url = try #require(MapStyleCatalog.admin1OverviewResourceURL())
        let raw = try Data(contentsOf: url)
        let root = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(root["name"] as? String == "dirt-admin1-na-overview")
        let features = try #require(root["features"] as? [[String: Any]])
        #expect(features.count >= 40)
        var minLon = 180.0, maxLon = -180.0, minLat = 90.0, maxLat = -90.0
        for feature in features {
            let geom = try #require(feature["geometry"] as? [String: Any])
            #expect(geom["type"] as? String == "LineString")
            let coords = try #require(geom["coordinates"] as? [Any])
            #expect(coords.count >= 2)
            for point in coords {
                let pair = try #require(point as? [Any])
                #expect(pair.count == 2)
                let lon = (pair[0] as? NSNumber)?.doubleValue ?? pair[0] as? Double
                let lat = (pair[1] as? NSNumber)?.doubleValue ?? pair[1] as? Double
                let x = try #require(lon)
                let y = try #require(lat)
                minLon = min(minLon, x)
                maxLon = max(maxLon, x)
                minLat = min(minLat, y)
                maxLat = max(maxLat, y)
            }
        }
        #expect(minLon < -130)
        #expect(maxLon > -70)
        #expect(minLat < 32)
        #expect(maxLat > 70)
        #expect(root["regions"] == nil)
    }

    @Test func generatedStyleShowsWaterAndStreetNames() throws {
        #expect(MapStyleCatalog.generatedStyleRevision == "osmand-v6")
        for style in [MapStyleID.shortbread, .shortbreadRich] {
            let styleURL = MapStyleCatalog.styleURL(for: style)
            let data = try Data(contentsOf: styleURL)
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let layers = try #require(root["layers"] as? [[String: Any]])
            let byID = Dictionary(uniqueKeysWithValues: layers.compactMap { layer -> (String, [String: Any])? in
                guard let id = layer["id"] as? String else { return nil }
                return (id, layer)
            })
            let lake = try #require(byID["water_polygons_labels-water-name-8"])
            #expect(intZoom(lake["minzoom"]) <= 5)
            let lakePaint = try #require(lake["paint"] as? [String: Any])
            #expect(lakePaint["text-color"] as? String == MapStyleCatalog.lakeLabelBlue)
            #expect(lakePaint["text-halo-color"] as? String == MapStyleCatalog.lakeLabelHalo)
            #expect(lakePaint["text-color"] as? String != "#163a52")
            #expect(lakePaint["text-color"] as? String != "#4f8fb0")
            #expect(lakePaint["text-halo-color"] as? String != "#f8f4f0")
            let lakeLayout = try #require(lake["layout"] as? [String: Any])
            #expect(lakeLayout["text-font"] as? [String] == ["Noto Sans Bold"])
            #expect(firstTextSize(lake) <= 8)
            if let city = byID["place_labels-city"] {
                #expect(firstTextSize(city) >= 14)
                let cityLayout = try #require(city["layout"] as? [String: Any])
                #expect(cityLayout["text-font"] as? [String] == ["Noto Sans Bold"])
            }
            if let town = byID.first(where: { $0.key.contains("town") })?.value {
                #expect(firstTextSize(town) >= 14)
            }
            let river = try #require(byID["label-waterway-bottom-12"])
            #expect(intZoom(river["minzoom"]) <= 10)
            let street = try #require(byID["label-street-centre-12"])
            #expect(intZoom(street["minzoom"]) <= 10)
            let streetPaint = try #require(street["paint"] as? [String: Any])
            #expect(streetPaint["text-color"] as? String == "#1a1f24")
            #expect(byID["dirt-bound-country"] != nil)
            #expect(byID["dirt-bound-state"] != nil)
        }
    }

    @Test func richSaturationHelperUsesOnePointOneFiveBoost() {
        let boosted = MapStyleCatalog.boostedSaturationHex("#96ce74")
        #expect(boosted.hasPrefix("#"))
        #expect(boosted.count == 7)
        #expect(boosted != "#96ce74")
        #expect(MapStyleCatalog.boostedSaturationHex("#96ce74") == boosted)
    }

    @Test func overlaySurfaceClassMapsLooseDirtToTrack() {
        #expect(PackNetworkOverlay.overlaySurfaceClass(.loose) == "track")
        #expect(PackNetworkOverlay.overlaySurfaceClass(.gravel) == "gravel")
        #expect(PackNetworkOverlay.overlaySurfaceClass(.paved) == "paved")
        #expect(PackNetworkOverlay.overlaySurfaceClass(.unknown) == "unknown")
        #expect(PackNetworkOverlay.overlaySurfaceClass(.unknown, roadClass: "track") == "track")
        #expect(PackNetworkOverlay.overlaySurfaceClass(.unknown, roadClass: "path") == "track")
        #expect(PackNetworkOverlay.overlaySurfaceClass(.paved, roadClass: "track") == "track")
    }

    @Test func overlayAccessClassMatchesGraphLegend() {
        #expect(PackNetworkOverlay.overlayAccessClass(0) == "motorized_verified")
        #expect(PackNetworkOverlay.overlayAccessClass(0, leaf: "permissive") == "motorized_permissive")
        #expect(PackNetworkOverlay.overlayAccessClass(1) == "motorized_unknown")
        #expect(PackNetworkOverlay.overlayAccessClass(3) == "motorized_restricted")
        #expect(PackNetworkOverlay.overlayAccessClass(4) == "motorized_restricted")
        #expect(PackNetworkOverlay.overlayAccessClass(2) == "motorized_excluded")
        #expect(PackNetworkOverlay.overlayAccessClass(5) == "motorized_excluded")
        #expect(PackNetworkOverlay.overlayAccessName("destination") == "motorized_restricted")
        #expect(PackNetworkOverlay.overlayAccessName("motorized_prohibited") == "motorized_excluded")
        #expect(PackNetworkOverlay.isTendrilSurface(.loose, roadClass: "residential"))
        #expect(PackNetworkOverlay.isTendrilSurface(.paved, roadClass: "track"))
        #expect(!PackNetworkOverlay.isTendrilSurface(.paved, roadClass: "primary"))
    }

    private func intZoom(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value.rounded()) }
        if let value = raw as? NSNumber { return value.intValue }
        return .max
    }

    private func firstTextSize(_ layer: [String: Any]?) -> Int {
        let layout = layer?["layout"] as? [String: Any]
        guard let size = layout?["text-size"] as? [String: Any],
              let stops = size["stops"] as? [[Any]],
              let first = stops.first, first.count >= 2
        else { return .max }
        return intZoom(first[1])
    }

    private func testShortbreadManifest(
        schema: String = "1.0",
        sampleHost: String = "tiles.example.test"
    ) -> ShortbreadTileManifest {
        ShortbreadTileManifest(
            contract: "dirt.shortbread-manifest.v1",
            releaseID: "maritimes-20260607",
            shortbreadSchema: schema,
            sourceUpdatedAt: "2026-06-07T00:00:00Z",
            cacheNamespace: "shortbread-v1",
            minZoom: 0,
            maxZoom: 14,
            bounds: [-69, 43, -59, 49],
            tileTemplate: "https://tiles.example.test/shortbread/v1/releases/maritimes-20260607/tiles/{z}/{x}/{y}.mvt",
            sampleTile: URL(
                string: "https://\(sampleHost)/shortbread/v1/releases/maritimes-20260607/tiles/10/331/369.mvt"
            )!,
            attribution: "© OpenStreetMap contributors · Shortbread vector tile schema"
        )
    }

    @Test func routingServiceContractRejectsMissingOrStaleDeployments() throws {
        #expect(throws: RoutingError.self) {
            try RoutingClient.validateServiceContract(nil, endpoint: "route")
        }
        #expect(throws: RoutingError.self) {
            try RoutingClient.validateServiceContract("older", endpoint: "fuel")
        }
        try RoutingClient.validateServiceContract(AppConfig.routingServiceContract, endpoint: "route")
    }

    @Test func installedPackIdentityRequiresExactBytesAndSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirt-pack-identity-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("approved pack bytes".utf8)
        try data.write(to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(GraphPackStore.fileMatchesIdentity(
            at: url,
            expectedBytes: data.count,
            expectedSHA256: sha
        ))
        #expect(!GraphPackStore.fileMatchesIdentity(
            at: url,
            expectedBytes: data.count + 1,
            expectedSHA256: sha
        ))
        #expect(!GraphPackStore.fileMatchesIdentity(
            at: url,
            expectedBytes: data.count,
            expectedSHA256: String(repeating: "0", count: 64)
        ))
    }

    @Test func riderServicesCacheRequiresExactBytesAndSHA256() {
        let data = Data("verified Rider Services".utf8)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(RiderServicesStore.dataMatchesIdentity(data, bytes: data.count, sha256: sha))
        #expect(!RiderServicesStore.dataMatchesIdentity(data, bytes: data.count + 1, sha256: sha))
        #expect(!RiderServicesStore.dataMatchesIdentity(
            data,
            bytes: data.count,
            sha256: String(repeating: "0", count: 64)
        ))
    }

    @Test @MainActor func navigationPackRequirementsReuseUnchangedRouteGeometry() {
        let route = [
            CLLocationCoordinate2D(latitude: 44.6488, longitude: -63.5752),
            CLLocationCoordinate2D(latitude: 45.0770, longitude: -64.4935),
            CLLocationCoordinate2D(latitude: 45.8330, longitude: -64.2130)
        ]
        var cache = NavigationRegionRequirementCache()
        var ownershipWalks = 0
        let resolve: ([CLLocationCoordinate2D]) -> [String] = { coordinates in
            ownershipWalks += 1
            return GraphPackStore.regionIds(containingAny: coordinates)
        }

        #expect(cache.regionIds(for: route, resolve: resolve) == ["ns"])
        #expect(cache.regionIds(for: route, resolve: resolve) == ["ns"])
        #expect(ownershipWalks == 1)

        var changedRoute = route
        changedRoute[1] = CLLocationCoordinate2D(latitude: 46.0878, longitude: -64.7782)
        #expect(cache.regionIds(for: changedRoute, resolve: resolve) == ["ns", "nb"])
        #expect(ownershipWalks == 2)
    }

    @Test @MainActor func navigationPackRequirementsPreserveCrossProvinceOwnership() {
        let halifax = CLLocationCoordinate2D(latitude: 44.6488, longitude: -63.5752)
        let amherst = CLLocationCoordinate2D(latitude: 45.8330, longitude: -64.2130)
        let sackville = CLLocationCoordinate2D(latitude: 45.9180, longitude: -64.3680)
        let moncton = CLLocationCoordinate2D(latitude: 46.0878, longitude: -64.7782)
        var cache = NavigationRegionRequirementCache()

        let required = cache.regionIds(
            for: [halifax, amherst, sackville, moncton],
            resolve: GraphPackStore.regionIds(containingAny:)
        )

        #expect(required == ["ns", "nb"])
    }

    @Test @MainActor func routeRequestEncodesProfileAndAccessPolicy() throws {
        let request = RouteRequest(
            profile: .balanced,
            locations: [
                RouteLocation(latitude: 44.6488, longitude: -63.5752, label: "A"),
                RouteLocation(latitude: 44.6712, longitude: -63.6123, label: "B")
            ],
            allowUnknown: true
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["profile"] as? String == "balanced")
        #expect(object["vehicle"] as? String == "dual-sport-motorcycle")
        let policy = try #require(object["accessPolicy"] as? [String: Bool])
        #expect(policy["motorizedPermissive"] == true)
        #expect(policy["motorizedUnknown"] == true)
    }

    @Test @MainActor func routeResponseDecodesSurfaceStatsAndSegments() throws {
        let json = """
        {
          "status":"complete",
          "distanceMeters":12500,
          "geometry":[[-63.57,44.64],[-63.61,44.67]],
          "segments":[{"surfaceClass":"gravel","surfaceLeaf":"fine_gravel","distanceMeters":7500,"geometry":[[-63.57,44.64],[-63.59,44.65]]}],
          "stats":{"dirtPercent":60,"pavedPercent":40,"surfaceFamilyMode":"leaf-v3"},
          "maneuvers":[{"instruction":"Continue","distanceMeters":12500,"alongMeters":0}]
        }
        """
        let response = try JSONDecoder().decode(RouteResponse.self, from: Data(json.utf8))
        #expect(response.isComplete)
        #expect(response.dirtPercent == 60)
        #expect(response.pavedPercent == 40)
        #expect(response.coordinates.count == 2)
        #expect(response.segments?.first?.surfaceClass == "gravel")
        #expect(response.segments?.first?.surfaceLeaf == "fine_gravel")
        #expect(response.stats?.surfaceFamilyMode == "leaf-v3")
    }

    @Test func surfaceFamiliesAreSpecificWithoutGuessing() {
        #expect(RouteSurfacePresentation.family(of: "asphalt") == .paved)
        #expect(RouteSurfacePresentation.family(of: "fine_gravel") == .gravel)
        #expect(RouteSurfacePresentation.family(of: "unpaved") == .gravel)
        #expect(RouteSurfacePresentation.family(of: "mud") == .loose)
        #expect(RouteSurfacePresentation.family(of: nil) == .unknown)
        #expect(RouteSurfacePresentation.family(of: "mystery_mix") == .unknown)
    }

    @Test @MainActor func routeCompositionKeepsFourFamiliesAndTwoTotalsConsistent() throws {
        let json = """
        {
          "status":"complete",
          "distanceMeters":1000,
          "geometry":[[-63.00,44.00],[-63.04,44.04]],
          "segments":[
            {"surfaceClass":"paved","surfaceLeaf":"asphalt","distanceMeters":400,"geometry":[[-63.00,44.00],[-63.01,44.01]]},
            {"surfaceClass":"gravel","surfaceLeaf":"fine_gravel","distanceMeters":300,"geometry":[[-63.01,44.01],[-63.02,44.02]]},
            {"surfaceClass":"dirt","surfaceLeaf":"mud","distanceMeters":200,"geometry":[[-63.02,44.02],[-63.03,44.03]]},
            {"surfaceClass":"unknown","distanceMeters":100,"geometry":[[-63.03,44.03],[-63.04,44.04]]}
          ],
          "stats":{"dirtPercent":60,"pavedPercent":40,"surfaceFamilyMode":"leaf-v3"}
        }
        """
        let response = try JSONDecoder().decode(RouteResponse.self, from: Data(json.utf8))
        let mix = RouteSurfaceComposition.from(responses: [response])

        #expect(mix.pavedMeters == 400)
        #expect(mix.gravelMeters == 300)
        #expect(mix.looseMeters == 200)
        #expect(mix.unknownMeters == 100)
        #expect(mix.dirtPercent == 50)
        #expect(mix.pavedPercent == 40)
        #expect(mix.gravelPercent == 30)
        #expect(mix.loosePercent == 20)
        #expect(mix.unknownPercent == 10)
    }

    @Test @MainActor func unknownAccessDoesNotReplaceKnownSurface() throws {
        let json = """
        {
          "status":"complete",
          "distanceMeters":100,
          "geometry":[[-63.00,44.00],[-63.01,44.01]],
          "segments":[{"surfaceClass":"paved","surfaceLeaf":"asphalt","accessClass":"motorized_unknown","distanceMeters":100,"geometry":[[-63.00,44.00],[-63.01,44.01]]}],
          "stats":{"dirtPercent":0,"pavedPercent":100,"surfaceFamilyMode":"leaf-v3"}
        }
        """
        let response = try JSONDecoder().decode(RouteResponse.self, from: Data(json.utf8))
        let mix = RouteSurfaceComposition.from(responses: [response])
        let display = try #require(MapState.displaySegments(from: [response]).first)

        #expect(mix.pavedPercent == 100)
        #expect(display.surfaceKey == SurfaceFamily.paved.rawValue)
        #expect(display.accessUnknown)
    }

    @Test @MainActor func displayRunsMergeByFamilyButKeepAccessBoundaries() throws {
        let json = """
        {
          "status":"complete",
          "distanceMeters":300,
          "geometry":[[-63.00,44.00],[-63.03,44.03]],
          "segments":[
            {"surfaceClass":"gravel","surfaceLeaf":"gravel","accessClass":"motorized_permissive","distanceMeters":100,"geometry":[[-63.00,44.00],[-63.01,44.01]]},
            {"surfaceClass":"gravel","surfaceLeaf":"fine_gravel","accessClass":"motorized_permissive","distanceMeters":100,"geometry":[[-63.01,44.01],[-63.02,44.02]]},
            {"surfaceClass":"gravel","surfaceLeaf":"compacted","accessClass":"motorized_unknown","distanceMeters":100,"geometry":[[-63.02,44.02],[-63.03,44.03]]}
          ],
          "stats":{"dirtPercent":100,"pavedPercent":0,"surfaceFamilyMode":"leaf-v3"}
        }
        """
        let response = try JSONDecoder().decode(RouteResponse.self, from: Data(json.utf8))
        let display = MapState.displaySegments(from: [response])

        #expect(display.count == 2)
        #expect(display[0].surfaceKey == SurfaceFamily.gravel.rawValue)
        #expect(display[0].coordinates.count == 3)
        #expect(!display[0].accessUnknown)
        #expect(display[1].surfaceKey == SurfaceFamily.gravel.rawValue)
        #expect(display[1].accessUnknown)
    }

    @Test @MainActor func ferryRunStaysDistinctFromUnknownRoadSurface() throws {
        let json = """
        {
          "status":"complete",
          "distanceMeters":300,
          "geometry":[[-69.90,47.84],[-69.60,47.84]],
          "segments":[
            {"surfaceClass":"unknown","accessClass":"motorized_permissive","distanceMeters":50,"geometry":[[-69.90,47.84],[-69.88,47.84]]},
            {"surfaceClass":"unknown","accessClass":"motorized_permissive","structureType":"ferry","crossingLabel":"Ferry crossing","distanceMeters":100,"geometry":[[-69.88,47.84],[-69.75,47.84]]},
            {"surfaceClass":"unknown","accessClass":"motorized_permissive","structureType":"ferry","crossingLabel":"Ferry crossing","distanceMeters":100,"geometry":[[-69.75,47.84],[-69.62,47.84]]},
            {"surfaceClass":"unknown","accessClass":"motorized_permissive","distanceMeters":50,"geometry":[[-69.62,47.84],[-69.60,47.84]]}
          ],
          "stats":{"dirtPercent":100,"pavedPercent":0,"surfaceFamilyMode":"leaf-v3"}
        }
        """
        let response = try JSONDecoder().decode(RouteResponse.self, from: Data(json.utf8))
        let display = MapState.displaySegments(from: [response])
        let summary = RouteFerrySummary.from(responses: [response])

        #expect(display.count == 3)
        #expect(!display[0].isFerry)
        #expect(display[1].isFerry)
        #expect(display[1].crossingLabel == "Ferry crossing")
        #expect(display[1].coordinates.count == 3)
        #expect(!display[2].isFerry)
        #expect(summary.crossingCount == 1)
        #expect(summary.distanceMeters == 200)
    }

    @Test func savedRouteRetainsDetailedSurfaceRuns() throws {
        let segment = RouteSegment(
            surfaceClass: "gravel",
            trackClass: "secondary",
            accessClass: "motorized_permissive",
            distanceMeters: 250,
            geometry: [
                RouteCoordinate(longitude: -63.00, latitude: 44.00),
                RouteCoordinate(longitude: -63.01, latitude: 44.01)
            ],
            coords: nil,
            edgeId: "edge-1",
            surfaceLeaf: "fine_gravel"
        )
        let route = SavedRoute(
            name: "Surface route",
            profile: .dirt,
            coordinates: segment.coordinates,
            distanceMeters: 250,
            dirtPercent: 100,
            pavedPercent: 0,
            segments: [segment],
            surfaceFamilyMode: "leaf-v3"
        )

        #expect(route.surfaceFamilyMode == "leaf-v3")
        #expect(route.segments?.first?.surfaceLeaf == "fine_gravel")
        #expect(route.segments?.first?.edgeId == "edge-1")
    }

    @Test @MainActor func legacySummaryUsesDirtPercentInsteadOfDumpingUnknown() throws {
        let json = """
        {"status":"complete","distanceMeters":1000,"geometry":[[-63.00,44.00],[-63.01,44.01]],"stats":{"dirtPercent":65,"pavedPercent":35}}
        """
        let response = try JSONDecoder().decode(RouteResponse.self, from: Data(json.utf8))
        let mix = RouteSurfaceComposition.from(responses: [response])

        #expect(mix.dirtPercent == 65)
        #expect(mix.pavedPercent == 35)
        #expect(mix.unknownPercent == 0)
        #expect(mix.gravelPercent == 65)
        #expect(mix.loosePercent == 0)
    }

    @Test func gpxParserReadsTrackPoints() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Test Ride</name></metadata>
          <trk>
            <name>Loop</name>
            <trkseg>
              <trkpt lat="44.64" lon="-63.57"/>
              <trkpt lat="44.67" lon="-63.61"/>
            </trkseg>
          </trk>
        </gpx>
        """
        let parsed = try GPXParser.parse(data: Data(xml.utf8))
        #expect(parsed.name == "Loop")
        #expect(parsed.pointCount == 2)
        #expect(parsed.coordinates.count == 2)
        #expect(parsed.coordinates[0].latitude == 44.64)
        #expect(parsed.coordinates[0].longitude == -63.57)
        #expect(parsed.distanceMeters > 0)
    }

    @Test func gpxParserFallsBackToRoutePoints() throws {
        let xml = """
        <?xml version="1.0"?>
        <gpx version="1.1">
          <rte><name>Day route</name>
            <rtept lat="45.0" lon="-64.0"/>
            <rtept lat="45.1" lon="-64.1"/>
          </rte>
        </gpx>
        """
        let parsed = try GPXParser.parse(data: Data(xml.utf8), fallbackName: "fallback")
        #expect(parsed.name == "Day route")
        #expect(parsed.coordinates.count == 2)
    }

    @Test func gpxExporterProducesTrackPoints() {
        let route = SavedRoute(
            name: "Saturday Loop",
            profile: .dirt,
            coordinates: [
                RouteCoordinate(longitude: -63.57, latitude: 44.64),
                RouteCoordinate(longitude: -63.61, latitude: 44.67)
            ],
            distanceMeters: 12_500,
            dirtPercent: 60,
            pavedPercent: 40
        )
        let xml = GPXExporter.document(for: route)
        #expect(xml.contains("<name>Saturday Loop</name>"))
        #expect(xml.contains("lat=\"44.64\" lon=\"-63.57\""))
        #expect(xml.contains("<trkseg>"))
    }

    @Test func gpxExporterMakesFuelGapVisible() {
        let route = SavedRoute(
            name: "Gap Ride",
            profile: .dirt,
            coordinates: [
                RouteCoordinate(longitude: -63.57, latitude: 44.64),
                RouteCoordinate(longitude: -62.57, latitude: 45.64)
            ],
            distanceMeters: 180_000,
            dirtPercent: 80,
            pavedPercent: 20
        )
        let warning = GPXExporter.FuelWarning(
            from: route.coordinates[0],
            to: route.coordinates[1],
            description: "No pump in range · 33 km over usable range"
        )

        let xml = GPXExporter.document(for: route, fuelWarnings: [warning])

        #expect(xml.contains("FUEL GAP START 1"))
        #expect(xml.contains("FUEL GAP END 1"))
        #expect(xml.contains("33 km over usable range"))
    }

    @Test func navigationChromeHidesDockAsSoonAsStartBegins() {
        #expect(!NavigationChrome.showsRideHUD(for: .idle))
        #expect(!NavigationChrome.showsRideHUD(for: .prefetching))
        #expect(NavigationChrome.showsRideHUD(for: .active))
        #expect(NavigationChrome.showsDock(for: .idle))
        #expect(!NavigationChrome.showsDock(for: .prefetching))
        #expect(!NavigationChrome.showsDock(for: .active))
        #expect(NavigationChrome.mapStackCompact(routeCardOpen: true, phase: .idle))
        #expect(!NavigationChrome.mapStackCompact(routeCardOpen: false, phase: .idle))
        #expect(!NavigationChrome.mapStackCompact(routeCardOpen: true, phase: .active))
    }

    @Test func displayedRouteGateRequiresAPaintedPolyline() {
        let mapState = MapState()
        #expect(!mapState.hasDisplayedRoute)

        mapState.setRoute([
            RouteDisplaySegment(
                coordinates: [RouteCoordinate(longitude: -63.0, latitude: 45.0)],
                surfaceKey: SurfaceFamily.paved.rawValue
            )
        ])
        #expect(!mapState.hasDisplayedRoute)

        mapState.setRoute([
            RouteDisplaySegment(
                coordinates: [
                    RouteCoordinate(longitude: -63.0, latitude: 45.0),
                    RouteCoordinate(longitude: -62.99, latitude: 45.01)
                ],
                surfaceKey: SurfaceFamily.paved.rawValue
            )
        ])
        #expect(mapState.hasDisplayedRoute)

        mapState.clearRoute()
        #expect(!mapState.hasDisplayedRoute)
    }

    @Test func cueLevelsKeepEssentialJunctionsInRallyEverything() {
        let bend = RouteManeuver(
            instruction: "3 RIGHT",
            type: "bend",
            kind: nil,
            side: "right",
            number: 3,
            degrees: 55,
            distanceMeters: 0,
            alongMeters: 100
        )
        let sharp = RouteManeuver(
            instruction: "5 LEFT",
            type: "bend",
            kind: nil,
            side: "left",
            number: 5,
            degrees: 110,
            distanceMeters: 0,
            alongMeters: 200
        )
        let junction = RouteManeuver(
            instruction: "Turn left",
            type: "turn",
            kind: "junction",
            side: "left",
            number: nil,
            degrees: nil,
            distanceMeters: 0,
            alongMeters: 300
        )

        #expect(bend.matches(cueMode: .rally))
        #expect(!bend.matches(cueMode: .junctions))

        #expect(sharp.matches(cueMode: .junctions))
        #expect(junction.matches(cueMode: .junctions))
        #expect(junction.matches(cueMode: .rally))
        #expect(NavigationCueMode.junctions.detailLabel == "Essential")
        #expect(NavigationCueMode.rally.detailLabel == "Everything")
    }

    @Test func continueStraightIsAnExplicitGraphDecisionCue() {
        let cue = RouteManeuver(
            instruction: "Continue straight",
            type: "continueStraight",
            stableID: "jct:edge-a>edge-b",
            kind: "junction",
            distanceMeters: 0,
            alongMeters: 420
        )

        #expect(cue.matches(cueMode: .junctions))
        #expect(cue.matches(cueMode: .rally))
        #expect(cue.displayLabel(cueMode: .junctions) == "Continue straight")
        #expect(cue.displayLabel(cueMode: .rally) == "Continue straight")
        #expect(cue.spokenLabel(cueMode: .rally, meters: 200, phase: .prepare) == "In 200 metres, Continue straight")
        #expect(cue.arrowSystemName(cueMode: .junctions) == "arrow.up")
        #expect(cue.announceIdentity == "jct:edge-a>edge-b")
        let enriched = RouteManeuver.enrichForVoiceCues([cue])
        #expect(enriched.first?.type == "continueStraight")
        #expect(enriched.first?.arrowSystemName(cueMode: .junctions) == "arrow.up")
        #expect(enriched.first?.announceIdentity == "jct:edge-a>edge-b")
    }

    @Test func rallyEverythingSuppressesNearbyCurvesWithoutCollapsingJunctions() {
        let nearCurve = RouteManeuver(
            instruction: "Right 3",
            type: "bend",
            kind: "curve",
            side: "right",
            number: 3,
            degrees: 60,
            distanceMeters: 0,
            alongMeters: 100
        )
        let farCurve = RouteManeuver(
            instruction: "Left 5",
            type: "bend",
            kind: "curve",
            side: "left",
            number: 5,
            degrees: 35,
            distanceMeters: 0,
            alongMeters: 300
        )
        let firstJunction = RouteManeuver(
            instruction: "Turn right",
            type: "turn",
            stableID: "junction-a",
            kind: "junction",
            side: "right",
            distanceMeters: 0,
            alongMeters: 130
        )
        let secondJunction = RouteManeuver(
            instruction: "Turn left",
            type: "turn",
            stableID: "junction-b",
            kind: "junction",
            side: "left",
            distanceMeters: 0,
            alongMeters: 170
        )

        let merged = NavCueBuilder.mergeRallyEverything(
            curves: [nearCurve, farCurve],
            junctions: [firstJunction, secondJunction]
        )

        #expect(merged.count == 3)
        #expect(merged[0].stableID == "junction-a")
        #expect(merged[1].stableID == "junction-b")
        #expect(merged[2].number == 5)
    }

    @Test @MainActor func rallyEverythingSessionPreservesIncomingJunctions() {
        let session = NavigationSession()
        session.cueMode = .rally
        session.activate(
            coordinates: [
                RouteCoordinate(longitude: -63.0, latitude: 45.0),
                RouteCoordinate(longitude: -62.99, latitude: 45.0)
            ],
            maneuvers: [
                RouteManeuver(
                    instruction: "Turn right",
                    type: "turn",
                    stableID: "essential-junction",
                    kind: "junction",
                    side: "right",
                    distanceMeters: 0,
                    alongMeters: 300
                )
            ]
        )

        #expect(session.maneuvers.contains(where: { $0.stableID == "essential-junction" }))
    }

    @Test func legacyManeuverPayloadStillDecodesWithoutStableIdentity() throws {
        let json = """
        {"instruction":"Turn left","type":"turn","kind":"junction","side":"left","alongMeters":200}
        """
        let cue = try JSONDecoder().decode(RouteManeuver.self, from: Data(json.utf8))

        #expect(cue.stableID == nil)
        #expect(cue.announceIdentity == "200-junction-left-")
    }

    @Test func retiredAllCueModeMigratesToJunctions() {
        #expect(NavigationCueMode.fromStorage(nil) == .junctions)
        #expect(NavigationCueMode.fromStorage("") == .junctions)
        #expect(NavigationCueMode.fromStorage("bends") == .junctions)
        #expect(NavigationCueMode.fromStorage("junctions") == .junctions)
        #expect(NavigationCueMode.fromStorage("rally") == .rally)
        #expect(NavigationCueMode.fromStorage("unknown") == .junctions)
    }

    @Test func navigationCueCadenceAdaptsAndStaysBounded() {
        #expect(NavigationCuePhase.phase(forMeters: 601, speedMPS: 40) == nil)
        #expect(NavigationCuePhase.phase(forMeters: 600, speedMPS: 40) == .prepare)
        #expect(NavigationCuePhase.phase(forMeters: 81, speedMPS: 40) == .prepare)
        #expect(NavigationCuePhase.phase(forMeters: 80, speedMPS: 40) == .now)
        #expect(NavigationCuePhase.phase(forMeters: 161, speedMPS: 1) == nil)
        #expect(NavigationCuePhase.phase(forMeters: 160, speedMPS: 1) == .prepare)
        #expect(NavigationCuePhase.phase(forMeters: 25, speedMPS: 1) == .now)
    }

    @Test func backgroundLocationRequiresInfoPlistMode() {
        #expect(!LocationBackgroundPolicy.shouldEnable(
            requested: true,
            hasLocationBackgroundMode: false
        ))
        #expect(LocationBackgroundPolicy.shouldEnable(
            requested: true,
            hasLocationBackgroundMode: true
        ))
        #expect(!LocationBackgroundPolicy.shouldEnable(
            requested: false,
            hasLocationBackgroundMode: true
        ))
    }

    @Test func fromHereTapShouldPaintDestinationBeforeRouteReturns() {
        // Contract: destination marker paint must not wait on the route result.
        #expect(RoutePlannerModel.paintsDestinationImmediatelyOnFromHereTap)
        #expect(RoutePlannerModel.calculatingRouteToast == "Calculating route")
    }

    @Test func poiDedupeCollapsesNearbyUnnamedCampgrounds() {
        let a = POIFeature(
            id: "1", category: "campground",
            latitude: 44.6865, longitude: -63.2908,
            name: nil, address: nil, brand: nil,
            openingHours: nil, phone: nil, website: nil
        )
        let b = POIFeature(
            id: "2", category: "campground",
            latitude: 44.6867, longitude: -63.2908,
            name: nil, address: nil, brand: nil,
            openingHours: nil, phone: nil, website: nil
        )
        let far = POIFeature(
            id: "3", category: "campground",
            latitude: 44.75, longitude: -63.29,
            name: "Other Park", address: nil, brand: nil,
            openingHours: nil, phone: nil, website: nil
        )
        let fuel = POIFeature(
            id: "4", category: "fuel",
            latitude: 44.6865, longitude: -63.2908,
            name: "Esso", address: nil, brand: nil,
            openingHours: nil, phone: nil, website: nil
        )
        let merged = POIDeduper.collapseNearby([a, b, far, fuel])
        #expect(merged.count == 3)
        #expect(merged.filter { $0.category == "campground" }.count == 2)
        #expect(merged.contains { $0.category == "fuel" })
    }

    @Test func fuelViewportUsesVisibleBoundsWithTwentyPercentOverscan() {
        let viewport = MapViewportBounds(
            minLongitude: -64,
            minLatitude: 44,
            maxLongitude: -63,
            maxLatitude: 45
        )
        let expanded = viewport.expanded(by: 0.20)
        #expect(expanded.minLongitude == -64.2)
        #expect(expanded.maxLongitude == -62.8)
        #expect(expanded.minLatitude == 43.8)
        #expect(expanded.maxLatitude == 45.2)
        #expect(expanded.contains(viewport))
    }

    @Test func fuelViewportCacheIsStableWithinCoverageAndSourceSpecific() throws {
        let coverage = MapViewportBounds(
            minLongitude: -64,
            minLatitude: 44,
            maxLongitude: -63,
            maxLatitude: 45
        )
        let inner = MapViewportBounds(
            minLongitude: -63.8,
            minLatitude: 44.2,
            maxLongitude: -63.2,
            maxLatitude: 44.8
        )
        let station = POIFeature(
            id: "irving", category: "fuel",
            latitude: 44.65, longitude: -63.57,
            name: "Irving", address: nil, brand: nil,
            openingHours: nil, phone: nil, website: nil
        )
        var cache = FuelViewportCache()
        let firstSourceChanged = cache.prepare(for: "live-pack")
        #expect(firstSourceChanged)
        cache.merge([station], coverage: coverage)
        #expect(cache.covers(inner))
        #expect(cache.features(in: inner).map(\.id) == ["irving"])
        let sameSourceChanged = cache.prepare(for: "live-pack")
        #expect(!sameSourceChanged)
        #expect(cache.count == 1)

        let installedSourceChanged = cache.prepare(for: "installed-pack")
        #expect(installedSourceChanged)
        #expect(cache.count == 0)
        #expect(!cache.covers(inner))
    }

    @Test func riderServiceViewportCachePreservesSuccessfulNonFuelResults() {
        let coverage = MapViewportBounds(
            minLongitude: -64,
            minLatitude: 44,
            maxLongitude: -63,
            maxLatitude: 45
        )
        let inner = MapViewportBounds(
            minLongitude: -63.8,
            minLatitude: 44.2,
            maxLongitude: -63.2,
            maxLatitude: 44.8
        )
        let campground = POIFeature(
            id: "camp", category: "campground",
            latitude: 44.65, longitude: -63.57,
            name: "Camp", address: nil, brand: nil,
            openingHours: nil, phone: nil, website: nil
        )
        let fuel = POIFeature(
            id: "fuel", category: "fuel",
            latitude: 44.66, longitude: -63.58,
            name: "Fuel", address: nil, brand: nil,
            openingHours: nil, phone: nil, website: nil
        )
        var cache = RiderServiceViewportCache()
        cache.merge([campground, fuel], coverage: coverage)
        #expect(cache.covers(inner))
        #expect(cache.count == 1)
        #expect(cache.features(in: inner).map(\.id) == ["camp"])
    }

    @Test func mapStatePublishesFuelReplacementModeFromCandidateMarkers() {
        let state = MapState()
        state.setMarkers([
            MapState.Marker(
                id: "fuel-target:alternate",
                latitude: 44.65,
                longitude: -63.57,
                label: "",
                kind: .fuel
            )
        ])
        #expect(state.hasFuelReplacementCandidates)
        state.setMarkers([])
        #expect(!state.hasFuelReplacementCandidates)
    }
}

struct POIActionPolicyTests {
    @Test func actionsRespectPlannerModeAndFuelIntent() {
        #expect(POIActionPolicy.primaryTitle(mode: .plan, category: "fuel") == "Add as fuel waypoint")
        #expect(POIActionPolicy.primaryTitle(mode: .plan, category: "campground") == "Add as waypoint")
        #expect(POIActionPolicy.primaryTitle(mode: .plan, category: "attraction") == "Add as waypoint")
        #expect(POIActionPolicy.primaryTitle(mode: .fromHere, category: "fuel") == "Navigate to fuel station")
        #expect(POIActionPolicy.primaryTitle(mode: .fromHere, category: "lodging") == "Navigate here")
        #expect(POIActionPolicy.primaryTitle(mode: .fromHere, category: "attraction") == "Navigate here")
    }
}

struct MapAttractionTests {
    @Test func kindReadsShortbreadPOITags() {
        #expect(MapAttraction.kind(from: ["natural": "beach"]) == "beach")
        #expect(MapAttraction.kind(from: ["kind": "beach"]) == "beach")
        #expect(MapAttraction.kind(from: ["waterway": "waterfall"]) == "waterfall")
        #expect(MapAttraction.kind(from: ["tourism": "viewpoint"]) == "viewpoint")
        #expect(MapAttraction.kind(from: ["historic": "monument"]) == "landmark")
        #expect(MapAttraction.kind(from: ["man_made": "lighthouse"]) == "landmark")
        #expect(MapAttraction.kind(from: ["tourism": "hotel"]) == nil)
    }

    @Test func tapLabelNamesTheAttractionKind() {
        let unnamed = POIFeature(
            id: "osm-attraction:1",
            category: "attraction",
            latitude: 44.65,
            longitude: -63.57,
            name: nil,
            address: nil,
            brand: nil,
            openingHours: nil,
            phone: nil,
            website: nil,
            kind: "waterfall"
        )
        #expect(unnamed.categoryLabel == "Attraction · Waterfall")
        #expect(unnamed.displayName == "Attraction · Waterfall")
        let named = POIFeature(
            id: "osm-attraction:2",
            category: "attraction",
            latitude: 44.65,
            longitude: -63.57,
            name: "Peggy's Cove",
            address: nil,
            brand: nil,
            openingHours: nil,
            phone: nil,
            website: nil,
            kind: "landmark"
        )
        #expect(named.categoryLabel == "Attraction · Landmark")
        #expect(named.displayName == "Peggy's Cove")
        #expect(MapAttraction.title(for: "beach") == "Beach")
        #expect(MapAttraction.layerIDs.contains("dirt-attraction-viewpoint"))
    }
}

@MainActor
private final class PackSessionRoutingSource: RoutingSource {
    let name = "pack"
    private let session: NativeRoutingSession
    private let directories: [String: URL]

    init(session: NativeRoutingSession, directories: [String: URL]) {
        self.session = session
        self.directories = directories
    }

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        let native = try NativeRoutingAdapter.request(req)
        let computed = try await session.route(native, directories: directories)
        return NativeRoutingAdapter.response(computed)
    }

    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: nil,
            stops: [], graphMeters: [], diagnostics: nil
        )
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        nil
    }
}

@MainActor
struct LongRouteNoDistanceBreakTests {
    @Test(.timeLimit(.minutes(5)))
    func portersLakeLongDirtRoutesStayOneLegAndKeepLoggedDirt() async throws {
        let packs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/greenfield-routing-evidence/packs")
        let ns = packs.appendingPathComponent("ns")
        let nb = packs.appendingPathComponent("nb")
        let qc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs/qc")
        try #require(FileManager.default.fileExists(atPath: ns.appendingPathComponent("graph.v4.bin").path))
        try #require(FileManager.default.fileExists(atPath: nb.appendingPathComponent("graph.v4.bin").path))
        try #require(FileManager.default.fileExists(atPath: qc.appendingPathComponent("graph.v4.bin").path))

        let cases: [(name: String, lat: Double, lon: Double, regions: [String])] = [
            ("cape-breton", 46.931127, -60.477673, ["ns", "nb"]),
            ("gaspe", 48.922934, -64.273363, ["ns", "nb", "qc"])
        ]
        let origin = RouteCoordinate(longitude: -63.34024797349485, latitude: 44.764804567541226)
        let session = NativeRoutingSession()
        let packsByRegion = ["ns": ns, "nb": nb, "qc": qc]
        let peakBefore = ProcessMemory.megabytes().peak
        for item in cases {
            let directories = Dictionary(uniqueKeysWithValues: item.regions.map { ($0, packsByRegion[$0]!) })
            let source = PackSessionRoutingSource(session: session, directories: directories)
            let destination = RouteCoordinate(longitude: item.lon, latitude: item.lat)
            let itinerary = reduce(
                RiderItinerary(),
                .replaceAll(
                    waypoints: [origin, destination],
                    profile: .dirt,
                    allowUnknown: false,
                    avoidMotorways: false,
                    preferBackRoads: false
                )
            ).itinerary
            let builder = ItineraryBuilder()
            builder.mapZoom = 12.5
            let caseStarted = ContinuousClock.now
            let built = await RoutingSessionContext.$seed.withValue(3806057305948982) {
                await builder.build(
                    itinerary,
                    from: 0,
                    reuse: nil,
                    fuel: .routeOnly,
                    source: .fixed(source),
                    onProgress: { _ in }
                )
            }
            #expect(built.legs.count == 1)
            let response = try #require(built.legs.first?.response)
            let loggedDirt = response.dirtPercent
            #expect(response.segments?.isEmpty == false)
            let painted = MapState.displaySegments(from: [response])
            #expect(painted.contains { $0.surfaceKey == SurfaceFamily.gravel.rawValue || $0.surfaceKey == SurfaceFamily.loose.rawValue })
            #expect(painted.contains { $0.surfaceKey == SurfaceFamily.paved.rawValue })
            #expect(painted.contains { $0.surfaceKey != SurfaceFamily.unknown.rawValue })
            let card = RouteSurfaceComposition.from(responses: [response])
            #expect(abs(card.dirtPercent - loggedDirt) <= 1)
            let elapsed = caseStarted.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let peak = ProcessMemory.megabytes().peak
            print(
                "LONG_ROUTE \(item.name) legs=\(built.legs.count) km=\(String(format: "%.1f", (response.distanceMeters ?? 0) / 1000)) " +
                "loggedDirt=\(loggedDirt) cardDirt=\(card.dirtPercent) " +
                "seconds=\(String(format: "%.1f", seconds)) peakMB=\(peak) (before=\(peakBefore))"
            )
        }
    }
}
