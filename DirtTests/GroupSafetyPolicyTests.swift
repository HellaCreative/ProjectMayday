import CoreLocation
import Foundation
import Testing
import UIKit
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
            heartbeatAt: now.addingTimeInterval(-121),
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
            heartbeatAt: now.addingTimeInterval(-30),
            now: now
        ))
        #expect(!GroupPresencePolicy.isLive(
            sharingEnabled: true,
            latitude: 44.65,
            longitude: -63.57,
            accuracyMeters: 12,
            heartbeatAt: nil,
            now: now
        ))
        #expect(!GroupPresencePolicy.isLive(
            sharingEnabled: true,
            latitude: 44.65,
            longitude: -63.57,
            accuracyMeters: 500,
            heartbeatAt: now.addingTimeInterval(-30),
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

        // Stationary phones may keep the same Core Location timestamp. Once a
        // fix is accepted during this sharing session, it remains usable while
        // a separate heartbeat proves the rider is still online.
        #expect(GroupPresencePolicy.retainedPublishableFix(
            latest: stale,
            accepted: valid,
            now: now
        ) === valid)
        #expect(GroupPresencePolicy.retainedPublishableFix(
            latest: stale,
            accepted: nil,
            now: now
        ) == nil)
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

    @Test @MainActor func riderMarkerRefreshPreservesItsMapPosition() {
        let annotation = DirtAnnotation()
        annotation.label = "Alex"
        annotation.status = "riding"

        let marker = DirtRiderMarkerView(reuseIdentifier: "test-rider")
        marker.center = CGPoint(x: 320, y: 480)
        marker.configure(for: annotation)

        #expect(marker.center == CGPoint(x: 320, y: 480))
        #expect(marker.bounds.width > 22)
        #expect(marker.bounds.height > 22)

        let dot = marker.subviews[0]
        let chip = marker.subviews[1]
        #expect(chip.frame.maxY < dot.frame.minY)
        #expect(abs(chip.frame.midX - dot.frame.midX) < 0.5)
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
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "riding") == 10)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "flat_tire") == 5)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "dead_battery") == 5)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "unrepairable") == 5)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "offline") == 10)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "breakdown") == 5)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "injured") == 5)
        #expect(GroupPresenceCadencePolicy.intervalSeconds(forStatus: "stuck") == 5)
        #expect(GroupPresenceCadencePolicy.distressSeconds < GroupPresenceCadencePolicy.ordinarySeconds)
    }

    @Test func riderStatusesUseCurrentLabelsAndAcceptLegacyAvailable() {
        #expect(GroupsViewModel.selectableStatuses == [
            "riding", "flat_tire", "dead_battery", "unrepairable", "injured", "stuck"
        ])
        #expect(GroupsViewModel.normalizedStatus("available") == "riding")
        #expect(GroupsViewModel.statusLabel("riding") == "Riding")
        #expect(GroupsViewModel.statusLabel("flat_tire") == "Flat Tire")
        #expect(GroupsViewModel.statusLabel("dead_battery") == "Dead Battery")
        #expect(GroupsViewModel.isDistressStatus("flat_tire"))
        #expect(GroupsViewModel.isDistressStatus("dead_battery"))
        #expect(GroupsViewModel.isDistressStatus("unrepairable"))
        #expect(!GroupsViewModel.isDistressStatus("riding"))
    }

    @Test func rosterRouteTargetRequiresALiveValidCoordinate() {
        let now = Date()
        let live = GroupMemberRow(
            userID: "alex",
            role: "member",
            displayName: "Alex",
            isLive: true,
            latitude: 44.65,
            longitude: -63.57,
            status: "riding",
            lastSeenAt: now,
            accuracyMeters: 12
        )
        let target = live.routeTarget(groupID: "trail")
        #expect(target?.userID == "alex")
        #expect(target?.groupID == "trail")
        #expect(target?.isLive == true)

        let offline = GroupMemberRow(
            userID: "alex",
            role: "member",
            displayName: "Alex",
            isLive: false,
            latitude: 44.65,
            longitude: -63.57,
            status: "offline",
            lastSeenAt: now,
            accuracyMeters: 12
        )
        #expect(offline.routeTarget(groupID: "trail") == nil)
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
