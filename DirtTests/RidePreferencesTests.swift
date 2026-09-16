import Foundation
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

    @MainActor @Test func defaultRequestsDoNotChangeAcceptedPayload() {
        #expect(RouteRequestOptions().ridePreferences == nil)
    }

    @MainActor @Test func settingsAreCapturedByRequestsAndDoNotLeakToNextBuild() async throws {
        let preferences = RidePreferences(wander: 0.25, avoidCities: false, avoidHighways: true)
        let captured = await RidePreferenceContext.$current.withValue(preferences) {
            await Task.yield()
            return RouteRequestOptions()
        }
        #expect(captured.ridePreferences == preferences)
        #expect(RouteRequestOptions().ridePreferences == nil)
        let decoded = try JSONDecoder().decode(RouteRequestOptions.self, from: JSONEncoder().encode(captured))
        #expect(decoded.ridePreferences == preferences)
    }

    @MainActor @Test func olderOptionsRemainDecodable() throws {
        let old = try JSONDecoder().decode(RouteRequestOptions.self, from: Data("{}".utf8))
        #expect(old.ridePreferences == nil)
    }

    @Test func invalidWanderIsNormalized() {
        #expect(RidePreferences(wander: -.infinity).normalized.wander == 1)
        #expect(RidePreferences(wander: -1).normalized.wander == 0)
        #expect(RidePreferences(wander: 2).normalized.wander == 1)
    }
}
