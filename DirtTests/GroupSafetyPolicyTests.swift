import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct GroupSafetyPolicyTests {
    @Test func presenceRejectsSentinelInvalidAndStaleCoordinates() {
        #expect(!GroupPresencePolicy.isValidCoordinate(latitude: 0, longitude: 0))
        #expect(!GroupPresencePolicy.isValidCoordinate(latitude: 91, longitude: -63))
        #expect(GroupPresencePolicy.isValidCoordinate(latitude: 44.65, longitude: -63.57))

        let now = Date(timeIntervalSince1970: 10_000)
        #expect(!GroupPresencePolicy.isLive(
            sharingEnabled: true,
            latitude: 44.65,
            longitude: -63.57,
            accuracyMeters: 12,
            lastSeenAt: now.addingTimeInterval(-121),
            now: now
        ))

        let inaccurateTarget = GroupMemberRouteTarget(
            groupID: "group",
            userID: "rider",
            displayName: "Rider",
            coordinate: RouteCoordinate(longitude: -63.57, latitude: 44.65),
            lastSeenAt: now.addingTimeInterval(-10),
            accuracyMeters: 500,
            isLive: true
        )
        #expect(!StopTriggeredTrackingPolicy.targetIsFresh(inaccurateTarget, now: now))
        #expect(GroupPresencePolicy.isLive(
            sharingEnabled: true,
            latitude: 44.65,
            longitude: -63.57,
            accuracyMeters: 12,
            lastSeenAt: now.addingTimeInterval(-30),
            now: now
        ))
        #expect(!GroupPresencePolicy.isLive(
            sharingEnabled: true,
            latitude: 44.65,
            longitude: -63.57,
            accuracyMeters: 12,
            lastSeenAt: nil,
            now: now
        ))
        #expect(!GroupPresencePolicy.isLive(
            sharingEnabled: true,
            latitude: 44.65,
            longitude: -63.57,
            accuracyMeters: 500,
            lastSeenAt: now.addingTimeInterval(-30),
            now: now
        ))
    }

    @Test func onlyFreshAccurateLocalFixesCanPublish() {
        let now = Date(timeIntervalSince1970: 10_000)
        let valid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 44.65, longitude: -63.57),
            altitude: 0,
            horizontalAccuracy: 12,
            verticalAccuracy: 12,
            course: 0,
            speed: 0,
            timestamp: now.addingTimeInterval(-10)
        )
        let stale = CLLocation(
            coordinate: valid.coordinate,
            altitude: 0,
            horizontalAccuracy: 12,
            verticalAccuracy: 12,
            course: 0,
            speed: 0,
            timestamp: now.addingTimeInterval(-60)
        )
        let inaccurate = CLLocation(
            coordinate: valid.coordinate,
            altitude: 0,
            horizontalAccuracy: 500,
            verticalAccuracy: 12,
            course: 0,
            speed: 0,
            timestamp: now
        )

        #expect(GroupPresencePolicy.canPublish(valid, now: now))
        #expect(!GroupPresencePolicy.canPublish(stale, now: now))
        #expect(!GroupPresencePolicy.canPublish(inaccurate, now: now))
        #expect(!GroupPresencePolicy.canPublish(nil, now: now))
    }

    @Test func stopTriggeredTrackingRequiresARealStopAndMeaningfulTargetMove() {
        let base = Date(timeIntervalSince1970: 20_000)
        #expect(!StopTriggeredTrackingPolicy.hasBeenStoppedLongEnough(
            since: base,
            now: base.addingTimeInterval(7.9)
        ))
        #expect(StopTriggeredTrackingPolicy.hasBeenStoppedLongEnough(
            since: base,
            now: base.addingTimeInterval(8)
        ))

        let stopped = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 44.65, longitude: -63.57),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: 0.4,
            timestamp: base
        )
        let moving = CLLocation(
            coordinate: stopped.coordinate,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: 3,
            timestamp: base
        )
        let stoppedMotionMatches: Bool
        switch StopTriggeredTrackingPolicy.motion(for: stopped) {
        case .stopped: stoppedMotionMatches = true
        case .moving, .uncertain: stoppedMotionMatches = false
        }
        let movingMotionMatches: Bool
        switch StopTriggeredTrackingPolicy.motion(for: moving) {
        case .moving: movingMotionMatches = true
        case .stopped, .uncertain: movingMotionMatches = false
        }
        #expect(stoppedMotionMatches)
        #expect(movingMotionMatches)

        let old = RouteCoordinate(longitude: -63.57, latitude: 44.65)
        let smallMove = RouteCoordinate(longitude: -63.5704, latitude: 44.65)
        let realMove = RouteCoordinate(longitude: -63.568, latitude: 44.65)
        #expect(!StopTriggeredTrackingPolicy.targetMovedMeaningfully(from: old, to: smallMove))
        #expect(StopTriggeredTrackingPolicy.targetMovedMeaningfully(from: old, to: realMove))
    }

    @Test func groupMarkerUpdatesDoNotRebuildPlannerMarkerState() {
        let state = MapState()
        state.setPlannerMarkers([
            MapState.Marker(
                id: "dest",
                latitude: 44.65,
                longitude: -63.57,
                label: "2",
                kind: .destination
            )
        ])
        let plannerGeneration = state.plannerMarkerGeneration
        state.setGroupMarkers([
            MapState.Marker(
                id: "rider:alex",
                latitude: 44.66,
                longitude: -63.58,
                label: "Alex",
                kind: .rider
            )
        ])

        #expect(state.plannerMarkerGeneration == plannerGeneration)
        #expect(state.plannerMarkers.map(\.id) == ["dest"])
        #expect(state.groupMarkers.map(\.id) == ["rider:alex"])
    }

    @Test @MainActor func backgroundLocationPurposesAreIndependent() {
        let service = LocationService()
        service.setBackgroundUpdates(true, for: .navigation)
        service.setBackgroundUpdates(true, for: .groupSharing)
        service.setBackgroundUpdates(false, for: .navigation)
        #expect(service.backgroundUpdatePurposes == [.groupSharing])
        service.setBackgroundUpdates(false, for: .groupSharing)
        #expect(service.backgroundUpdatePurposes.isEmpty)
    }

    @Test func distressAlertsOnlyBroadcastToThePersistedTargetGroup() {
        let targets = GroupAlertPolicy.broadcastGroupIDs(
            targetGroupID: "trail-riders",
            connectedGroupIDs: ["trail-riders", "friends", "event-staff"]
        )
        #expect(targets == ["trail-riders"])

        let disconnected = GroupAlertPolicy.broadcastGroupIDs(
            targetGroupID: "trail-riders",
            connectedGroupIDs: ["friends", "event-staff"]
        )
        #expect(disconnected.isEmpty)
    }

    @Test func distressPresencePublishesMoreFrequentlyThanOrdinarySharing() {
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "available") == 10)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "offline") == 10)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "breakdown") == 5)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "injured") == 5)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "stuck") == 5)
        #expect(GroupPresenceCadencePolicy.distressSeconds < GroupPresenceCadencePolicy.ordinarySeconds)
    }

    @Test func appleSignInFailuresRemainVisibleToTheRider() {
        let error = NSError(
            domain: "DIRTTests.AppleSignIn",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Apple sign-in is unavailable."]
        )
        #expect(AppleSignInFailure.message(from: error) == "Apple sign-in is unavailable.")
    }
}
