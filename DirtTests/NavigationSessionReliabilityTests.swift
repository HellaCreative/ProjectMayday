import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct NavigationSessionReliabilityTests {
    @Test @MainActor func sustainedOffRouteFixesRerouteOnceWithoutATap() {
        let session = NavigationSession()
        var requests = 0
        session.onRerouteNeeded = { requests += 1 }
        session.activate(coordinates: Self.straightRoute(), maneuvers: [])
        let start = Date(timeIntervalSince1970: 1_000)
        sendOffRouteStrikes(to: session, startingAt: start)
        #expect(session.offRoute && session.missTurnRerouting)
        #expect(session.currentCue == "Rerouting…")
        #expect(requests == 1)
        sendOffRouteStrikes(to: session, startingAt: start.addingTimeInterval(5))
        #expect(requests == 1)
        session.end()
        session.activate(coordinates: Self.straightRoute(), maneuvers: [])
        sendOffRouteStrikes(to: session, startingAt: start.addingTimeInterval(20))
        #expect(requests == 2)
    }

    @Test @MainActor func reportSuspendsAutomaticRecoveryAndFailureDoesNotLoop() {
        let session = NavigationSession()
        var requests = 0
        session.onRerouteNeeded = { requests += 1 }
        session.activate(coordinates: Self.straightRoute(), maneuvers: [])
        session.recoverySuspended = true
        let start = Date(timeIntervalSince1970: 1_000)
        sendOffRouteStrikes(to: session, startingAt: start)
        #expect(requests == 0)
        session.recoverySuspended = false
        sendOffRouteStrikes(to: session, startingAt: start.addingTimeInterval(5))
        #expect(requests == 1)
        session.setMissTurnFailure("No connection")
        sendOffRouteStrikes(to: session, startingAt: start.addingTimeInterval(60))
        #expect(requests == 1) // Stationary rider: no repeated expensive search.
        session.continueMissTurnReroute()
        #expect(requests == 2)
    }

    @Test @MainActor func inaccurateOrRepeatedFixesCannotTriggerRerouting() {
        let session = NavigationSession()
        var requests = 0
        session.onRerouteNeeded = { requests += 1 }
        session.activate(coordinates: Self.straightRoute(), maneuvers: [])
        let start = Date(timeIntervalSince1970: 1_000)
        for i in 0..<5 {
            session.update(with: CLLocation(coordinate: .init(latitude: 45.01, longitude: -63),
                altitude: 0, horizontalAccuracy: 100, verticalAccuracy: -1,
                timestamp: start.addingTimeInterval(Double(i))))
        }
        let fix = Self.location(latitude: 45.01, longitude: -63, speed: 12, timestamp: start)
        for _ in 0..<5 { session.update(with: fix) }
        #expect(requests == 0)
        #expect(!session.offRoute)
    }

    @Test @MainActor func bendsNeverInventJunctionsWithoutGraphDecisions() {
        let session = NavigationSession()
        session.cueMode = .junctions
        session.activate(coordinates: [
            .init(longitude: -63, latitude: 45),
            .init(longitude: -62.99, latitude: 45),
            .init(longitude: -62.99, latitude: 45.01)
        ], maneuvers: [])
        #expect(!session.maneuvers.contains { $0.isJunctionCue })
    }

    @Test @MainActor func cueRemainsAtJunctionAndPassedQueueEntriesExpire() {
        let session = NavigationSession()
        session.cueMode = .junctions
        var valid: Set<String> = []
        session.onCueValidityChanged = { valid = $0 }
        session.activate(coordinates: Self.straightRoute(), maneuvers: [
            RouteManeuver(instruction: "Turn left", type: "turn", stableID: "turn",
                kind: "junction", side: "left", distanceMeters: 0, alongMeters: 300)
        ])
        let start = Date(timeIntervalSince1970: 2_000)
        session.update(with: Self.location(latitude: 45, longitude: -62.9963, speed: 10, timestamp: start))
        #expect(session.currentManeuver?.stableID == "turn")
        #expect(valid.contains("turn"))
        session.update(with: Self.location(latitude: 45, longitude: -62.9958, speed: 10, timestamp: start.addingTimeInterval(5)))
        #expect(!valid.contains("turn"))
        session.end()
        #expect(valid.isEmpty)
    }

    @Test @MainActor func fuelRemainingStartsAtUsableWhenNotificationsOn() {
        let previous = UserDefaults.standard.object(forKey: FuelRangePrefs.notificationsEnabledKey)
        FuelRangePrefs.notificationsEnabled = true
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: FuelRangePrefs.notificationsEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FuelRangePrefs.notificationsEnabledKey)
            }
        }
        let session = NavigationSession()
        session.activate(coordinates: Self.straightRoute(), maneuvers: [])
        #expect(session.fuelNotificationsOn)
        let usable = FuelRangePrefs.snapshot.usableMeters
        #expect(session.remainingFuelMeters != nil)
        #expect(abs((session.remainingFuelMeters ?? 0) - usable) < 1)
    }

    @Test @MainActor func fuelRemainingHiddenWhenNotificationsOff() {
        let previous = UserDefaults.standard.object(forKey: FuelRangePrefs.notificationsEnabledKey)
        FuelRangePrefs.notificationsEnabled = false
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: FuelRangePrefs.notificationsEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FuelRangePrefs.notificationsEnabledKey)
            }
        }
        let session = NavigationSession()
        session.activate(coordinates: Self.straightRoute(), maneuvers: [])
        #expect(!session.fuelNotificationsOn)
        #expect(session.remainingFuelMeters == nil)
        #expect(!session.fuelStationPromptVisible)
    }

    @Test @MainActor func changingCueModeDoesNotReplayDeliveredJunction() {
        let session = NavigationSession()
        session.cueMode = .junctions
        var junctionAnnouncements: [String] = []
        session.onCueAnnounced = { _, key in
            if key.hasPrefix("junction-a|") { junctionAnnouncements.append(key) }
        }
        session.activate(
            coordinates: Self.straightRoute(),
            maneuvers: [
                RouteManeuver(
                    instruction: "Turn right",
                    type: "turn",
                    stableID: "junction-a",
                    kind: "junction",
                    side: "right",
                    distanceMeters: 0,
                    alongMeters: 300
                )
            ]
        )

        let fix = Self.location(latitude: 45, longitude: -63, speed: 15)
        session.update(with: fix)
        #expect(junctionAnnouncements == ["junction-a|prepare"])

        session.cueMode = .rally
        session.rebuildCuesForCurrentMode()
        session.update(with: fix)
        #expect(junctionAnnouncements == ["junction-a|prepare"])
    }

    @Test @MainActor func progressStaysOnLocalArmBesideLaterParallelArm() {
        let session = NavigationSession()
        let started = Date(timeIntervalSince1970: 2_000)
        let route = [
            RouteCoordinate(longitude: -63.0000, latitude: 45.0000),
            RouteCoordinate(longitude: -62.9900, latitude: 45.0000),
            RouteCoordinate(longitude: -62.9900, latitude: 45.0300),
            RouteCoordinate(longitude: -63.0000, latitude: 45.0300),
            RouteCoordinate(longitude: -63.0000, latitude: 45.0001),
            RouteCoordinate(longitude: -62.9900, latitude: 45.0001),
        ]
        session.activate(coordinates: route, maneuvers: [])
        session.update(with: Self.location(
            latitude: 45.0000,
            longitude: -63.0000,
            speed: 15,
            timestamp: started
        ))
        session.update(with: Self.location(
            latitude: 45.0001,
            longitude: -62.9950,
            speed: 15,
            timestamp: started.addingTimeInterval(1)
        ))

        #expect(session.traveledMeters > 300)
        #expect(session.traveledMeters < 1_000)
        #expect(!session.offRoute)
    }

    @Test @MainActor func nearbyParallelArmDoesNotBeatPlausibleProgress() {
        let session = NavigationSession()
        let started = Date(timeIntervalSince1970: 2_500)
        let route = [
            RouteCoordinate(longitude: -63.0000, latitude: 45.0000),
            RouteCoordinate(longitude: -62.9987, latitude: 45.0000),
            RouteCoordinate(longitude: -62.9987, latitude: 45.0001),
            RouteCoordinate(longitude: -63.0000, latitude: 45.0001),
            RouteCoordinate(longitude: -63.0013, latitude: 45.0001),
        ]
        session.activate(coordinates: route, maneuvers: [])
        session.update(with: Self.location(
            latitude: 45,
            longitude: -63,
            speed: 10,
            timestamp: started
        ))

        // GPS scatter places this fix slightly nearer the later return arm,
        // even though one second of motion makes that arm unreachable.
        session.update(with: Self.location(
            latitude: 45.00006,
            longitude: -62.99935,
            speed: 10,
            timestamp: started.addingTimeInterval(1)
        ))

        #expect(session.traveledMeters > 35)
        #expect(session.traveledMeters < 80)
        #expect(!session.offRoute)
    }

    @Test @MainActor func progressDoesNotJumpBackwardAtSelfCrossing() {
        let session = NavigationSession()
        let started = Date(timeIntervalSince1970: 3_000)
        let crossing = RouteCoordinate(longitude: -63.0000, latitude: 45.0000)
        let route = [
            RouteCoordinate(longitude: -63.0100, latitude: 45.0000),
            crossing,
            RouteCoordinate(longitude: -62.9900, latitude: 45.0200),
            RouteCoordinate(longitude: -63.0100, latitude: 45.0200),
            crossing,
            RouteCoordinate(longitude: -62.9900, latitude: 44.9800),
        ]
        session.activate(coordinates: route, maneuvers: [])

        // Establish progress on the later approach to the crossing.
        session.update(with: Self.location(
            latitude: 45.0060,
            longitude: -63.0030,
            speed: 15,
            timestamp: started
        ))
        let beforeCrossing = session.traveledMeters
        session.update(with: Self.location(
            latitude: crossing.latitude,
            longitude: crossing.longitude,
            speed: 15,
            timestamp: started.addingTimeInterval(1)
        ))

        #expect(beforeCrossing > 4_000)
        #expect(session.traveledMeters >= beforeCrossing)
        #expect(!session.offRoute)
    }

    @Test @MainActor func localProgressWindowAllowsOrdinaryStageTransition() {
        let session = NavigationSession()
        let route = [
            RouteCoordinate(longitude: -63.0000, latitude: 45.0000),
            RouteCoordinate(longitude: -62.9900, latitude: 45.0000),
            RouteCoordinate(longitude: -62.9800, latitude: 45.0000),
        ]
        let ends = GeoMath.cumulativeMeters(route)
        session.activate(
            coordinates: route,
            maneuvers: [],
            stageEndMeters: [ends[1], ends[2]],
            stages: [
                NavigationStage(id: "fuel-1", title: "F1", detail: nil, kind: .fuelStop, endMeters: ends[1]),
                NavigationStage(id: "point-2", title: "Point 2", detail: nil, kind: .destination, endMeters: ends[2]),
            ]
        )
        let started = Date(timeIntervalSince1970: 4_000)
        session.update(with: Self.location(
            latitude: 45,
            longitude: -62.9905,
            speed: 15,
            timestamp: started
        ))
        #expect(session.currentStage?.id == "fuel-1")

        session.update(with: Self.location(
            latitude: 45,
            longitude: -62.9895,
            speed: 15,
            timestamp: started.addingTimeInterval(1)
        ))
        #expect(session.currentStage?.id == "point-2")
    }

    @Test @MainActor func rerouteReplacementReanchorsProgressToNewLine() {
        let session = NavigationSession()
        let oldRoute = [
            RouteCoordinate(longitude: -63.000, latitude: 45),
            RouteCoordinate(longitude: -62.995, latitude: 45),
            RouteCoordinate(longitude: -62.990, latitude: 45),
        ]
        let newRoute = stride(from: -64.000, through: -63.900, by: 0.010).map {
            RouteCoordinate(longitude: $0, latitude: 46)
        }
        let started = Date(timeIntervalSince1970: 4_500)
        session.activate(coordinates: oldRoute, maneuvers: [])
        session.update(with: Self.location(
            latitude: 45,
            longitude: -62.999,
            speed: 12,
            timestamp: started
        ))

        session.replaceRoute(coordinates: newRoute, maneuvers: [])
        session.update(with: Self.location(
            latitude: 46,
            longitude: -63.920,
            speed: 12,
            timestamp: started.addingTimeInterval(1)
        ))

        #expect(session.traveledMeters > 5_000)
        #expect(!session.offRoute)
    }

    @Test @MainActor func progressWindowExpandsAcrossBackgroundLocationGap() {
        let session = NavigationSession()
        let route = stride(from: -64.000, through: -63.900, by: 0.010).map {
            RouteCoordinate(longitude: $0, latitude: 46)
        }
        let started = Date(timeIntervalSince1970: 5_000)
        session.activate(coordinates: route, maneuvers: [])
        session.update(with: Self.location(
            latitude: 46,
            longitude: -64,
            speed: 20,
            timestamp: started
        ))
        session.update(with: Self.location(
            latitude: 46,
            longitude: -63.940,
            speed: 20,
            timestamp: started.addingTimeInterval(240)
        ))

        #expect(session.traveledMeters > 4_000)
        #expect(!session.offRoute)
    }

    @Test @MainActor func repeatedStationaryOffRouteFixesNeverAdvanceProgressAnchor() {
        let session = NavigationSession()
        let route = stride(from: -63.0000, through: -62.9800, by: 0.001).map {
            RouteCoordinate(longitude: $0, latitude: 45)
        }
        let started = Date(timeIntervalSince1970: 5_500)
        session.activate(coordinates: route, maneuvers: [])
        session.update(with: Self.location(
            latitude: 45,
            longitude: -63,
            speed: 12,
            timestamp: started
        ))
        let acceptedProgress = session.traveledMeters

        for offset in 1...12 {
            session.update(with: Self.location(
                latitude: 45.0010,
                longitude: -62.9920,
                speed: 0,
                timestamp: started.addingTimeInterval(Double(offset * 10))
            ))
        }

        #expect(session.offRoute)
        #expect(abs(session.traveledMeters - acceptedProgress) < 1)
    }

    @Test @MainActor func movingRiderCanNaturallyRejoinAheadAfterOffRouteStrikes() {
        let session = NavigationSession()
        let route = stride(from: -63.0000, through: -62.9800, by: 0.001).map {
            RouteCoordinate(longitude: $0, latitude: 45)
        }
        let started = Date(timeIntervalSince1970: 6_000)
        var recoveries = 0
        session.onRouteRecovered = { recoveries += 1 }
        session.activate(coordinates: route, maneuvers: [])
        session.update(with: Self.location(
            latitude: 45,
            longitude: -63,
            speed: 12,
            timestamp: started
        ))
        for offset in 1...3 {
            session.update(with: Self.location(
                latitude: 45.0010,
                longitude: -63 + Double(offset) * 0.002,
                speed: 12,
                timestamp: started.addingTimeInterval(Double(offset * 10))
            ))
        }
        #expect(session.offRoute)

        session.update(with: Self.location(
            latitude: 45,
            longitude: -62.9920,
            speed: 12,
            timestamp: started.addingTimeInterval(40)
        ))

        #expect(!session.offRoute)
        #expect(recoveries == 1)
        #expect(session.traveledMeters > 500)
    }

    @Test @MainActor func prefetchTransitionIsIdleOnly() {
        let session = NavigationSession()
        #expect(session.beginPrefetch())
        #expect(!session.beginPrefetch())
        #expect(session.phase == .prefetching)
        session.cancelPrefetch()
        #expect(session.beginPrefetch())
        session.cancelPrefetch()

        session.activate(coordinates: Self.straightRoute(), maneuvers: [])
        #expect(!session.beginPrefetch())
        #expect(session.phase == .active)
    }

    @Test func failedPrepCanBeConsumedForExplicitLiveMapsRide() {
        #expect(OfflineTileManager.canConsumePrepForRide(.ready(cached: 10, total: 10)))
        #expect(OfflineTileManager.canConsumePrepForRide(.failed("offline unavailable")))
        #expect(!OfflineTileManager.canConsumePrepForRide(.idle))
        #expect(!OfflineTileManager.canConsumePrepForRide(.downloading(completed: 3, total: 10)))
    }

    private static func straightRoute() -> [RouteCoordinate] {
        [
            RouteCoordinate(longitude: -63.0000, latitude: 45.0000),
            RouteCoordinate(longitude: -62.9500, latitude: 45.0000),
        ]
    }

    @MainActor
    private func sendOffRouteStrikes(to session: NavigationSession, startingAt: Date) {
        for offset in 0..<3 {
            session.update(with: Self.location(
                latitude: 45.0100,
                longitude: -63.0000,
                speed: 10,
                timestamp: startingAt.addingTimeInterval(Double(offset))
            ))
        }
    }

    private static func location(
        latitude: Double,
        longitude: Double,
        speed: Double,
        timestamp: Date = Date()
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: -1,
            course: -1,
            speed: speed,
            timestamp: timestamp
        )
    }
}
