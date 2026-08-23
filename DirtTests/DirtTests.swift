//
//  DirtTests.swift
//  DirtTests
//
//  Created by Richard Smith on 7/25/26.
//

import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct DirtTests {
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

    @Test func routeRequestEncodesProfileAndAccessPolicy() throws {
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

    @Test func routeResponseDecodesSurfaceStatsAndSegments() throws {
        let json = """
        {
          "status":"complete",
          "distanceMeters":12500,
          "geometry":[[-63.57,44.64],[-63.61,44.67]],
          "segments":[{"surfaceClass":"gravel","distanceMeters":7500,"geometry":[[-63.57,44.64],[-63.59,44.65]]}],
          "stats":{"dirtPercent":60,"pavedPercent":40},
          "maneuvers":[{"instruction":"Continue","distanceMeters":12500,"alongMeters":0}]
        }
        """
        let response = try JSONDecoder().decode(RouteResponse.self, from: Data(json.utf8))
        #expect(response.isComplete)
        #expect(response.dirtPercent == 60)
        #expect(response.pavedPercent == 40)
        #expect(response.coordinates.count == 2)
        #expect(response.segments?.first?.surfaceClass == "gravel")
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
        #expect(NavigationChrome.showsDock(for: .idle))
        #expect(!NavigationChrome.showsDock(for: .prefetching))
        #expect(!NavigationChrome.showsDock(for: .active))
        #expect(NavigationChrome.mapStackCompact(routeCardOpen: true, phase: .idle))
        #expect(!NavigationChrome.mapStackCompact(routeCardOpen: false, phase: .idle))
        #expect(!NavigationChrome.mapStackCompact(routeCardOpen: true, phase: .active))
    }

    @Test func cueModeFiltersBendAndJunctionManeuvers() {
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

        #expect(bend.matches(cueMode: .all))
        #expect(bend.matches(cueMode: .rally))
        #expect(!bend.matches(cueMode: .junctions))

        #expect(sharp.matches(cueMode: .junctions))
        #expect(junction.matches(cueMode: .junctions))
        #expect(!junction.matches(cueMode: .rally))
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
