import Foundation
import DirtRoutingEngine
import Testing
@testable import Dirt

@Suite struct RidePreferencesTests {
    @MainActor @Test func loopAddsOnlyReturnLegAndDoesNotDuplicateClosedLoop() {
        let a = RouteCoordinate(longitude: -63.3, latitude: 44.7)
        let b = RouteCoordinate(longitude: -63.5, latitude: 44.9)
        let route = reduce(RiderItinerary(), .replaceAll(waypoints: [a, b], profile: .balanced,
            allowUnknown: false, avoidMotorways: false, preferBackRoads: false)).itinerary
        #expect(RoutePlannerModel.loopReturnPoint(in: route) == a)
        let closed = reduce(route, .append(coordinate: a))
        #expect(closed.itinerary.waypoints.map(\.coordinate) == [a, b, a])
        #expect(closed.itinerary.legs.first == route.legs.first)
        #expect(closed.rebuildFromLegIndex == 1)
        #expect(RoutePlannerModel.loopReturnPoint(in: closed.itinerary) == nil)
    }

    @MainActor @Test func defaultRequestsUseRiderDefaultsInNativeRouting() throws {
        #expect(RouteRequestOptions().ridePreferences == nil)
        for profile in [RouteProfile.dirt, .balanced, .cleanest] {
            let request = RouteRequest(profile: profile, locations: [
                .init(latitude: 44.7, longitude: -63.3, label: "Start"),
                .init(latitude: 45, longitude: -63, label: "End")
            ], allowUnknown: false)
            let native = try NativeRoutingAdapter.request(request)
            #expect(native.profile.wander == 0.5)
            #expect(native.profile.avoidMajorHighways)
            #expect(native.access.avoidFerries)
            #expect(native.options.cityWall)
        }
    }

    @MainActor @Test func settingsAreCapturedByRequestsAndDoNotLeakToNextBuild() async throws {
        let preferences = RidePreferences(wander: 0.25, avoidCities: false, avoidHighways: false, avoidFerries: false)
        let captured = await RidePreferenceContext.$current.withValue(preferences) {
            await Task.yield()
            return RouteRequestOptions()
        }
        #expect(captured.ridePreferences == preferences)
        #expect(RouteRequestOptions().ridePreferences == nil)
        let decoded = try JSONDecoder().decode(RouteRequestOptions.self, from: JSONEncoder().encode(captured))
        #expect(decoded.ridePreferences == preferences)
        let native = try RidePreferenceContext.$current.withValue(decoded.ridePreferences) {
            try NativeRoutingAdapter.request(RouteRequest(profile: .dirt, locations: [
                .init(latitude: 44.7, longitude: -63.3, label: "Start"),
                .init(latitude: 45, longitude: -63, label: "End")
            ], allowUnknown: false))
        }
        #expect(native.profile.wander == 0.25)
        #expect(!native.profile.avoidMajorHighways)
        #expect(!native.access.avoidFerries)
        #expect(!native.options.cityWall)
    }

    @MainActor @Test func olderOptionsRemainDecodable() throws {
        let old = try JSONDecoder().decode(RouteRequestOptions.self, from: Data("{}".utf8))
        #expect(old.ridePreferences == nil)
    }

    @Test func preFerrySavedPreferencesPreserveExistingSettings() throws {
        let json = Data(#"{"wander":0.9,"avoidCities":false,"avoidHighways":false,"preferDifferentRoads":true}"#.utf8)
        let old = try JSONDecoder().decode(RidePreferences.self, from: json)
        #expect(old.wander == 0.9 && !old.avoidCities && !old.avoidHighways)
        #expect(old.preferDifferentRoads == true && old.avoidFerries)
        #expect(try JSONDecoder().decode(RidePreferences.self, from: JSONEncoder().encode(old)) == old)
    }

    @Test func invalidWanderIsNormalized() {
        #expect(RidePreferences(wander: -.infinity).normalized.wander == 0.5)
        #expect(RidePreferences(wander: -1).normalized.wander == 0)
        #expect(RidePreferences(wander: 2).normalized.wander == 1)
    }
}
