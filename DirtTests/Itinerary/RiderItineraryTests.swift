import Foundation
import Testing
@testable import Dirt

struct RiderItineraryTests {
    @Test func appendThreeBuildsOrderedChain() {
        var itinerary = RiderItinerary()
        itinerary = reduce(itinerary, .append(coordinate: point(0))).itinerary
        itinerary = reduce(itinerary, .append(coordinate: point(1))).itinerary
        itinerary = reduce(itinerary, .append(coordinate: point(2))).itinerary

        #expect(itinerary.waypoints.count == 3)
        #expect(itinerary.legs.count == 2)
        #expect(itinerary.legs[0].from == itinerary.waypoints[0].id)
        #expect(itinerary.legs[0].to == itinerary.waypoints[1].id)
        #expect(itinerary.legs[1].from == itinerary.waypoints[1].id)
        #expect(itinerary.legs[1].to == itinerary.waypoints[2].id)
        #expect(itinerary.invariantsHold)
    }

    @Test func insertAfterFirstLegSplitsInPlace() throws {
        var initial = itinerary([point(0), point(2)])
        let preferences = RidePreferences(
            wander: 0.8,
            avoidCities: false,
            avoidHighways: true,
            avoidFerries: false
        )
        initial.legs[0].ridePreferences = preferences
        let originalEndID = initial.waypoints[1].id
        let oldLegID = try #require(initial.legs.first?.id)

        let change = reduce(initial, .insert(afterLegID: oldLegID, coordinate: point(1)))

        #expect(change.itinerary.waypoints.count == 3)
        #expect(change.itinerary.waypoints[2].id == originalEndID)
        #expect(change.rebuildFromLegIndex == 0)
        #expect(change.itinerary.legs[0].id != oldLegID)
        #expect(change.itinerary.legs[1].id != oldLegID)
        #expect(change.itinerary.legs.allSatisfy { $0.ridePreferences == preferences })
        #expect(change.itinerary.invariantsHold)
    }

    @Test func insertAfterSecondLegPreservesFirstLegID() throws {
        let initial = itinerary([point(0), point(1), point(3)])
        let firstLegID = initial.legs[0].id
        let secondLegID = initial.legs[1].id

        let change = reduce(initial, .insert(afterLegID: secondLegID, coordinate: point(2)))

        #expect(change.rebuildFromLegIndex == 1)
        #expect(change.itinerary.legs[0].id == firstLegID)
        #expect(change.itinerary.waypoints.count == 4)
        #expect(change.itinerary.invariantsHold)
    }

    @Test func moveMiddleWaypointRebuildsIncomingLegAndKeepsIDs() {
        let initial = itinerary([point(0), point(1), point(2)])
        let secondLegID = initial.legs[1].id
        let middleID = initial.waypoints[1].id

        let change = reduce(
            initial,
            .move(waypointID: middleID, to: RouteCoordinate(longitude: -62.2, latitude: 45.9))
        )

        #expect(change.rebuildFromLegIndex == 0)
        #expect(change.itinerary.legs[1].id == secondLegID)
        #expect(change.itinerary.invariantsHold)
    }

    @Test func deleteMiddleWaypointJoinsItsNeighbors() {
        let initial = itinerary([point(0), point(1), point(2)])
        let middleID = initial.waypoints[1].id

        let change = reduce(initial, .delete(waypointID: middleID))

        #expect(change.itinerary.waypoints.map(\.coordinate) == [point(0), point(2)])
        #expect(change.itinerary.legs.count == 1)
        #expect(change.rebuildFromLegIndex == 0)
        #expect(change.itinerary.invariantsHold)
    }

    @Test func deleteFromTwoLeavesValidSingleWaypoint() {
        let initial = itinerary([point(0), point(1)])
        let deletedID = initial.waypoints[1].id

        let change = reduce(initial, .delete(waypointID: deletedID))

        #expect(change.itinerary.waypoints.count == 1)
        #expect(change.itinerary.legs.isEmpty)
        #expect(change.rebuildFromLegIndex == nil)
        #expect(change.itinerary.invariantsHold)
    }

    @Test func generationOnlyAdvancesForMutatingActions() {
        let empty = RiderItinerary()
        let one = reduce(empty, .append(coordinate: point(0))).itinerary
        let two = reduce(one, .append(coordinate: point(1))).itinerary
        let noMove = reduce(
            two,
            .move(waypointID: two.waypoints[0].id, to: two.waypoints[0].coordinate)
        ).itinerary
        let missingDelete = reduce(two, .delete(waypointID: UUID())).itinerary
        let sameProfile = reduce(two, .setProfile(legID: nil, .balanced)).itinerary
        let marked = reduce(two, .markImpassable(edgeIDs: ["edge-1"])).itinerary
        let markedAgain = reduce(marked, .markImpassable(edgeIDs: ["edge-1"])).itinerary

        #expect(one.generation == empty.generation + 1)
        #expect(two.generation == one.generation + 1)
        #expect(noMove.generation == two.generation)
        #expect(missingDelete.generation == two.generation)
        #expect(sameProfile.generation == two.generation)
        #expect(marked.generation == two.generation + 1)
        #expect(markedAgain.generation == marked.generation)
    }

    @Test func setProfileForOneLegRebuildsFromThatLeg() throws {
        let initial = itinerary([point(0), point(1), point(2)])
        let secondLegID = try #require(initial.legs.last?.id)

        let change = reduce(initial, .setProfile(legID: secondLegID, .dirt))

        #expect(change.rebuildFromLegIndex == 1)
        #expect(change.rebuildThroughLegIndex == 1)
        #expect(change.itinerary.legs[0] == initial.legs[0])
        #expect(change.itinerary.legs[1].profile == .dirt)
    }

    @Test func legRideSettingsChangeOnlyTheSelectedLeg() throws {
        let initial = itinerary([point(0), point(1), point(2)], profile: .dirt)
        let selectedID = try #require(initial.legs.last?.id)
        let preferences = RidePreferences(
            wander: 0.85,
            avoidCities: false,
            avoidHighways: true,
            avoidFerries: false
        )

        let change = reduce(
            initial,
            .setLegRideSettings(
                legID: selectedID,
                profile: .balanced,
                allowUnknown: true,
                ridePreferences: preferences
            )
        )

        #expect(change.rebuildFromLegIndex == 1)
        #expect(change.rebuildThroughLegIndex == 1)
        #expect(change.itinerary.legs[0] == initial.legs[0])
        #expect(change.itinerary.legs[1].profile == .balanced)
        #expect(change.itinerary.legs[1].allowUnknown)
        #expect(change.itinerary.legs[1].ridePreferences == preferences)
    }

    @Test func cleanLegSettingsForceUnknownOffWithoutChangingAvoidanceChoices() throws {
        let initial = itinerary([point(0), point(1)], profile: .dirt)
        let legID = try #require(initial.legs.first?.id)
        let preferences = RidePreferences(
            wander: 0.25,
            avoidCities: false,
            avoidHighways: false,
            avoidFerries: false
        )

        let change = reduce(
            initial,
            .setLegRideSettings(
                legID: legID,
                profile: .cleanest,
                allowUnknown: true,
                ridePreferences: preferences
            )
        )

        let leg = try #require(change.itinerary.legs.first)
        #expect(!leg.allowUnknown)
        #expect(leg.ridePreferences == preferences)
        #expect(leg.profile == .cleanest)
    }

    @Test func olderSavedLegsReceiveCurrentRideDefaults() throws {
        let original = try #require(itinerary([point(0), point(1)], profile: .dirt).legs.first)
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "ridePreferences")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RiderLeg.self, from: legacy)

        #expect(decoded.ridePreferences == RidePreferences())
    }

    @Test func setProfileForAllLegsRebuildsFromFirstLeg() {
        let initial = itinerary([point(0), point(1), point(2)])

        let change = reduce(initial, .setProfile(legID: nil, .dirt))

        #expect(change.rebuildFromLegIndex == 0)
        #expect(change.rebuildThroughLegIndex == nil)
        #expect(change.itinerary.legs.allSatisfy { $0.profile == .dirt })
    }

    @Test func setAllowUnknownForOneLegRebuildsFromThatLeg() throws {
        let initial = itinerary([point(0), point(1), point(2)], profile: .dirt)
        let secondLegID = try #require(initial.legs.last?.id)

        let change = reduce(initial, .setAllowUnknown(legID: secondLegID, true))

        #expect(change.rebuildFromLegIndex == 1)
        #expect(change.rebuildThroughLegIndex == 1)
        #expect(change.itinerary.legs[0] == initial.legs[0])
        #expect(change.itinerary.legs[1].allowUnknown)
    }

    @Test func setAllowUnknownForAllLegsRebuildsFromFirstLeg() {
        let initial = itinerary([point(0), point(1), point(2)], profile: .dirt)

        let change = reduce(initial, .setAllowUnknown(legID: nil, true))

        #expect(change.rebuildFromLegIndex == 0)
        #expect(change.rebuildThroughLegIndex == nil)
        #expect(change.itinerary.legs.allSatisfy { $0.allowUnknown })
    }

    @Test func fuelStageUnknownAccessIsIndependentAndRebuildsItsDependentSuffix() throws {
        let initial = itinerary([point(0), point(1)], profile: .dirt)
        let leg = try #require(initial.legs.first)
        let departure = leg.from.uuidString

        let firstStage = reduce(
            initial,
            .setHopAllowUnknown(legID: leg.id, stationID: departure, true)
        )
        let firstStageLeg = try #require(firstStage.itinerary.legs.first)

        #expect(firstStage.rebuildFromLegIndex == 0)
        #expect(firstStage.rebuildThroughLegIndex == 0)
        #expect(firstStage.replanFromStationID == nil)
        #expect(!firstStageLeg.allowUnknown)
        #expect(firstStageLeg.allowsUnknown(departingFrom: departure))
        #expect(!firstStageLeg.allowsUnknown(departingFrom: "fuel-a"))

        let secondStage = reduce(
            firstStage.itinerary,
            .setHopAllowUnknown(legID: leg.id, stationID: "fuel-a", true)
        )
        let secondStageLeg = try #require(secondStage.itinerary.legs.first)

        #expect(secondStage.rebuildFromLegIndex == 0)
        #expect(secondStage.rebuildThroughLegIndex == 0)
        #expect(secondStage.replanFromStationID == "fuel-a")
        #expect(secondStageLeg.allowsUnknown(departingFrom: departure))
        #expect(secondStageLeg.allowsUnknown(departingFrom: "fuel-a"))
        #expect(!secondStageLeg.allowsUnknown(departingFrom: "fuel-b"))
    }

    @Test func settingFuelHopToItsEffectiveProfileDoesNotRebuild() throws {
        let initial = itinerary([point(0), point(1)], profile: .dirt)
        let leg = try #require(initial.legs.first)

        let unchanged = reduce(
            initial,
            .setHopProfile(legID: leg.id, stationID: "fuel-a", .dirt)
        )

        #expect(unchanged.itinerary.generation == initial.generation)
        #expect(unchanged.rebuildFromLegIndex == nil)
        #expect(unchanged.replanFromStationID == nil)
        #expect(unchanged.itinerary.legs.first?.hopOverrides.isEmpty == true)
    }

    @Test func fuelStageUnknownAccessStaysInsideItsPlannedRouteLeg() throws {
        let initial = itinerary([point(0), point(1), point(2)], profile: .dirt)
        let selectedLeg = initial.legs[1]
        let selectedDeparture = selectedLeg.from.uuidString

        let change = reduce(
            initial,
            .setHopAllowUnknown(
                legID: selectedLeg.id,
                stationID: selectedDeparture,
                true
            )
        )

        #expect(change.rebuildFromLegIndex == 1)
        #expect(change.rebuildThroughLegIndex == 1)
        #expect(change.itinerary.legs[0] == initial.legs[0])
        #expect(!change.itinerary.legs[0].allowsUnknown(
            departingFrom: change.itinerary.legs[0].from.uuidString
        ))
        #expect(change.itinerary.legs[1].allowsUnknown(departingFrom: selectedDeparture))
        #expect(!change.itinerary.legs[1].allowsUnknown(departingFrom: "later-fuel"))
    }

    @Test func cleanFuelHopOnDirtParentDefaultsToAvoidingMajorHighwaysAndTogglesIndependently() throws {
        let initial = itinerary([point(0), point(1)], profile: .dirt)
        let legID = try #require(initial.legs.first?.id)
        let firstClean = reduce(
            initial,
            .setHopProfile(legID: legID, stationID: "fuel-a", .cleanest)
        )
        let bothClean = reduce(
            firstClean.itinerary,
            .setHopProfile(legID: legID, stationID: "fuel-b", .cleanest)
        )
        let cleanLeg = try #require(bothClean.itinerary.legs.first)

        #expect(cleanLeg.profile == .dirt)
        #expect(cleanLeg.avoidMotorways == false)
        #expect(cleanLeg.avoidsMajorHighways(departingFrom: "fuel-a"))
        #expect(cleanLeg.avoidsMajorHighways(departingFrom: "fuel-b"))
        #expect(cleanLeg.hopAvoidMotorways.isEmpty)

        let allowFuelA = reduce(
            bothClean.itinerary,
            .setHopAvoidMotorways(legID: legID, stationID: "fuel-a", false)
        )
        let allowedLeg = try #require(allowFuelA.itinerary.legs.first)

        #expect(allowFuelA.rebuildFromLegIndex == 0)
        #expect(allowFuelA.replanFromStationID == "fuel-a")
        #expect(allowedLeg.hopAvoidMotorways["fuel-a"] == false)
        #expect(!allowedLeg.avoidsMajorHighways(departingFrom: "fuel-a"))
        #expect(allowedLeg.avoidsMajorHighways(departingFrom: "fuel-b"))

        let avoidFuelA = reduce(
            allowFuelA.itinerary,
            .setHopAvoidMotorways(legID: legID, stationID: "fuel-a", true)
        )
        let avoidedLeg = try #require(avoidFuelA.itinerary.legs.first)

        #expect(avoidFuelA.rebuildFromLegIndex == 0)
        #expect(avoidFuelA.replanFromStationID == "fuel-a")
        #expect(avoidedLeg.hopAvoidMotorways["fuel-a"] == true)
        #expect(avoidedLeg.avoidsMajorHighways(departingFrom: "fuel-a"))
        #expect(avoidedLeg.avoidsMajorHighways(departingFrom: "fuel-b"))
    }

    @Test func pruningFuelHopProfilesAlsoPrunesTheirStagePolicies() throws {
        var current = itinerary([point(0), point(1)], profile: .dirt)
        let leg = try #require(current.legs.first)
        let departure = leg.from.uuidString
        for anchor in [departure, "active-fuel", "stale-fuel"] {
            current = reduce(
                current,
                .setHopAllowUnknown(legID: leg.id, stationID: anchor, true)
            ).itinerary
            current = reduce(
                current,
                .setHopProfile(legID: leg.id, stationID: anchor, .cleanest)
            ).itinerary
            current = reduce(
                current,
                .setHopAvoidMotorways(legID: leg.id, stationID: anchor, false)
            ).itinerary
        }

        current.pruneHopOverrides(to: [leg.id: ["active-fuel"]])

        let pruned = try #require(current.legs.first)
        #expect(Set(pruned.hopOverrides.keys) == [departure, "active-fuel"])
        #expect(Set(pruned.hopAvoidMotorways.keys) == [departure, "active-fuel"])
        #expect(Set(pruned.hopAllowUnknown.keys) == [departure, "active-fuel"])
        #expect(pruned.hopOverrides["stale-fuel"] == nil)
        #expect(pruned.hopAvoidMotorways["stale-fuel"] == nil)
        #expect(pruned.hopAllowUnknown["stale-fuel"] == nil)
    }

    @Test func randomActionSequencesPreserveEveryInvariant() {
        var random = TestRandom(seed: 0xD1_47)
        for _ in 0..<100 {
            var current = RiderItinerary()
            for _ in 0..<100 {
                let action: ItineraryAction
                switch random.nextInt(upperBound: 7) {
                case 0:
                    action = .append(coordinate: random.coordinate())
                case 1 where !current.legs.isEmpty:
                    let leg = current.legs[random.nextInt(upperBound: current.legs.count)]
                    action = .insert(afterLegID: leg.id, coordinate: random.coordinate())
                case 2 where !current.waypoints.isEmpty:
                    let waypoint = current.waypoints[random.nextInt(upperBound: current.waypoints.count)]
                    action = .move(waypointID: waypoint.id, to: random.coordinate())
                case 3 where !current.waypoints.isEmpty:
                    let waypoint = current.waypoints[random.nextInt(upperBound: current.waypoints.count)]
                    action = .delete(waypointID: waypoint.id)
                case 4:
                    action = .setProfile(legID: nil, random.nextBool() ? .dirt : .balanced)
                case 5:
                    action = .setAllowUnknown(legID: nil, random.nextBool())
                default:
                    action = .markImpassable(edgeIDs: ["edge-\(random.nextInt(upperBound: 20))"])
                }
                current = reduce(current, action).itinerary
                #expect(current.invariantsHold)
            }
        }
    }

    @Test func codableRoundTripPreservesItinerary() throws {
        var original = itinerary([point(0), point(1), point(2)], profile: .dirt, allowUnknown: true)
        original = reduce(original, .markImpassable(edgeIDs: ["edge-a", "edge-b"])).itinerary
        let legID = try #require(original.legs.first?.id)
        original = reduce(
            original,
            .setHopProfile(legID: legID, stationID: "fuel-a", .cleanest)
        ).itinerary
        original = reduce(
            original,
            .setHopAvoidMotorways(legID: legID, stationID: "fuel-a", false)
        ).itinerary
        original = reduce(
            original,
            .setHopAllowUnknown(legID: legID, stationID: "fuel-b", false)
        ).itinerary

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RiderItinerary.self, from: data)

        #expect(decoded == original)
        #expect(decoded.invariantsHold)
    }

    @Test func logUsesCanonicalCoordinatesAndGeneration() throws {
        let before = itinerary([point(0), point(2)])
        let legID = try #require(before.legs.first?.id)
        let action = ItineraryAction.insert(afterLegID: legID, coordinate: point(1))
        let after = reduce(before, action).itinerary
        let line = ItineraryLog.line(action: action, before: before, after: after)

        #expect(line.contains("itinerary action=insert afterLeg=\(legID.uuidString)"))
        #expect(line.contains("gen=1→2"))
        #expect(line.contains("before=[45.000000,-63.000000;45.020000,-62.980000]"))
        #expect(line.contains("after=[45.000000,-63.000000;45.010000,-62.990000;45.020000,-62.980000]"))
    }

    private func itinerary(
        _ coordinates: [RouteCoordinate],
        profile: RouteProfile = .balanced,
        allowUnknown: Bool = false
    ) -> RiderItinerary {
        reduce(
            RiderItinerary(),
            .replaceAll(waypoints: coordinates, profile: profile, allowUnknown: allowUnknown, avoidMotorways: false, preferBackRoads: false)
        ).itinerary
    }

    private func point(_ index: Int) -> RouteCoordinate {
        RouteCoordinate(
            longitude: -63 + Double(index) * 0.01,
            latitude: 45 + Double(index) * 0.01
        )
    }
}

private struct TestRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    mutating func nextBool() -> Bool {
        next() & 1 == 0
    }

    mutating func coordinate() -> RouteCoordinate {
        let latitude = 43 + Double(nextInt(upperBound: 6000)) / 1000
        let longitude = -66 + Double(nextInt(upperBound: 6000)) / 1000
        return RouteCoordinate(longitude: longitude, latitude: latitude)
    }
}
