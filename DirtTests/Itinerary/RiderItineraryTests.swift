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
        let initial = itinerary([point(0), point(2)])
        let originalEndID = initial.waypoints[1].id
        let oldLegID = try #require(initial.legs.first?.id)

        let change = reduce(initial, .insert(afterLegID: oldLegID, coordinate: point(1)))

        #expect(change.itinerary.waypoints.count == 3)
        #expect(change.itinerary.waypoints[2].id == originalEndID)
        #expect(change.rebuildFromLegIndex == 0)
        #expect(change.itinerary.legs[0].id != oldLegID)
        #expect(change.itinerary.legs[1].id != oldLegID)
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
            .replaceAll(waypoints: coordinates, profile: profile, allowUnknown: allowUnknown)
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
