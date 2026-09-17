import Foundation
import SwiftData
import Testing
@testable import Dirt

struct RiddenRouteAndContributeTests {
    @Test func contributeNudgeFiresEveryThirdCompletedNavigationWhenPrefOff() {
        TrackContributePrefs.reset()
        defer { TrackContributePrefs.reset() }

        #expect(TrackContributePrefs.recordCompletedNavigation() == false)
        #expect(TrackContributePrefs.recordCompletedNavigation() == false)
        #expect(TrackContributePrefs.recordCompletedNavigation() == true)
        #expect(TrackContributePrefs.recordCompletedNavigation() == false)
        #expect(TrackContributePrefs.recordCompletedNavigation() == false)
        #expect(TrackContributePrefs.recordCompletedNavigation() == true)
    }

    @Test func contributeNudgeNeverFiresWhenPrefOn() {
        TrackContributePrefs.reset()
        defer { TrackContributePrefs.reset() }
        TrackContributePrefs.isEnabled = true

        #expect(TrackContributePrefs.recordCompletedNavigation() == false)
        #expect(TrackContributePrefs.recordCompletedNavigation() == false)
        #expect(TrackContributePrefs.recordCompletedNavigation() == false)
    }

    @Test func riddenAndPlannedRoutesCanBothExist() {
        let planned = SavedRoute(
            name: "Saturday plan",
            profile: .dirt,
            coordinates: [
                RouteCoordinate(longitude: -63.57, latitude: 44.64),
                RouteCoordinate(longitude: -63.61, latitude: 44.67)
            ],
            distanceMeters: 12_500,
            dirtPercent: 60,
            pavedPercent: 40
        )
        let ridden = SavedRoute(
            name: "Saturday ride",
            profile: .dirt,
            coordinates: [
                RouteCoordinate(longitude: -63.57, latitude: 44.64),
                RouteCoordinate(longitude: -63.59, latitude: 44.66)
            ],
            distanceMeters: 9_100,
            dirtPercent: 0,
            pavedPercent: 0,
            riddenSavedAt: Date()
        )

        #expect(!planned.isRidden)
        #expect(ridden.isRidden)
        #expect(planned.name != ridden.name)
    }

    @Test @MainActor func saveRiddenRouteNeverOverwritesThePlan() throws {
        let schema = Schema([SavedRoute.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let planned = SavedRoute(
            name: "Saturday plan",
            profile: .dirt,
            coordinates: [
                RouteCoordinate(longitude: -63.57, latitude: 44.64),
                RouteCoordinate(longitude: -63.61, latitude: 44.67)
            ],
            distanceMeters: 12_500,
            dirtPercent: 60,
            pavedPercent: 40
        )
        context.insert(planned)
        try context.save()

        let planner = RoutePlannerModel(
            routing: RoutingClient(),
            locationService: LocationService(),
            mapState: MapState(),
            navigation: NavigationSession(),
            offline: OfflineTileManager(),
            graphPacks: GraphPackStore(),
            network: NetworkPathMonitor()
        )
        planner.loadSavedRoute(planned)
        #expect(planner.saveAffordance == .alreadySaved)

        planner.saveRiddenRoute(
            named: "Ride from today",
            coordinates: [
                RouteCoordinate(longitude: -63.57, latitude: 44.64),
                RouteCoordinate(longitude: -63.58, latitude: 44.65),
                RouteCoordinate(longitude: -63.60, latitude: 44.66)
            ],
            distanceMeters: 2_400,
            context: context
        )

        let stored = try context.fetch(FetchDescriptor<SavedRoute>())
        #expect(stored.count == 2)
        #expect(stored.contains { $0.name == "Saturday plan" && !$0.isRidden })
        #expect(stored.contains { $0.name == "Ride from today" && $0.isRidden })
        #expect(planner.saveAffordance == .alreadySaved)
    }
}
