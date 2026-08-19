import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct FuelAssistTests {
    @Test func fuelPickPrefersStationOnTheLineNotASpur() {
        let start = RouteCoordinate(longitude: -123.2, latitude: 50.0)
        let end = RouteCoordinate(longitude: -119.7, latitude: 50.0)
        let line = [start, end]
        let total = GeoMath.meters(start, end)
        #expect(total > 230_000)

        let alongTarget = 200_000 * 0.82
        let t = alongTarget / total
        let onRoute = GeoMath.interpolate(start, end, fraction: t)
        let spur = RouteCoordinate(longitude: onRoute.longitude, latitude: 50.45)
        let nearB = GeoMath.interpolate(start, end, fraction: 0.97)

        let fuels = [
            poi("spur", spur),
            poi("pump", onRoute),
            poi("doorstep", nearB)
        ]
        let pick = RoutePlannerModel.pickFuelStop(
            fuels: fuels,
            along: line,
            rangeMeters: 200_000
        )
        #expect(pick?.id == "osm:pump")
    }

    @Test func fuelPickSkipsWhenOnlyBarelyOverATank() {
        let start = RouteCoordinate(longitude: -123.0, latitude: 50.0)
        let end = RouteCoordinate(longitude: -121.2, latitude: 50.0)
        let total = GeoMath.meters(start, end)
        #expect(total > 120_000)
        #expect(total < 200_000 * 1.15)
        let mid = GeoMath.interpolate(start, end, fraction: 0.5)
        let pick = RoutePlannerModel.pickFuelStop(
            fuels: [poi("mid", mid)],
            along: [start, end],
            rangeMeters: 200_000
        )
        #expect(pick == nil)
    }

    private func poi(_ id: String, _ at: RouteCoordinate) -> POIFeature {
        POIFeature(
            id: "osm:\(id)",
            category: "fuel",
            latitude: at.latitude,
            longitude: at.longitude,
            name: id,
            address: nil,
            brand: nil,
            openingHours: nil,
            phone: nil,
            website: nil
        )
    }
}
