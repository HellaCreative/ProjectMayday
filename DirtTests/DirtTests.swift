//
//  DirtTests.swift
//  DirtTests
//
//  Created by Richard Smith on 7/25/26.
//

import Foundation
import Testing
@testable import Dirt

struct DirtTests {
    @Test func routeRequestUsesCanonicalBackendShape() throws {
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
}
