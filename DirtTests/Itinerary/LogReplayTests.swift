import Foundation
import Testing
@testable import Dirt

struct LogReplayTests {
    @Test func intended1854SequenceReplaysWithoutBreakingCanonicalInvariants() throws {
        let fixture = """
        itinerary action=replaceAll gen=0→1 before=[] after=[44.765490,-63.339830;46.104710,-60.207400] source=fromHere
        itinerary action=insert afterLeg=ignored gen=1→2 before=[44.765490,-63.339830;46.104710,-60.207400] after=[44.765490,-63.339830;45.667440,-62.344200;46.104710,-60.207400] source=tap
        itinerary action=move id=ignored gen=2→3 before=[44.765490,-63.339830;45.667440,-62.344200;46.104710,-60.207400] after=[44.765490,-63.339830;45.700000,-62.300000;46.104710,-60.207400] source=drag
        itinerary action=delete id=ignored gen=3→4 before=[44.765490,-63.339830;45.700000,-62.300000;46.104710,-60.207400] after=[44.765490,-63.339830;46.104710,-60.207400] source=swipe
        """

        let final = try ItineraryLogReplay.replay(fixture)

        #expect(final.waypoints.map(\.coordinate) == [
            RouteCoordinate(longitude: -63.339830, latitude: 44.765490),
            RouteCoordinate(longitude: -60.207400, latitude: 46.104710)
        ])
        #expect(final.legs.count == 1)
        #expect(final.generation == 4)
        #expect(final.invariantsHold)
    }
}

private enum ItineraryLogReplay {
    enum ReplayError: Error {
        case malformed(String)
        case stateMismatch(String)
    }

    static func replay(_ text: String) throws -> RiderItinerary {
        var itinerary = RiderItinerary()
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let before = try coordinates(named: "before", in: line)
            let after = try coordinates(named: "after", in: line)
            guard itinerary.waypoints.map(\.coordinate) == before else {
                throw ReplayError.stateMismatch(line)
            }
            let action = try action(for: line, itinerary: itinerary, before: before, after: after)
            itinerary = reduce(itinerary, action).itinerary
            guard itinerary.invariantsHold,
                  itinerary.waypoints.map(\.coordinate) == after else {
                throw ReplayError.stateMismatch(line)
            }
        }
        return itinerary
    }

    private static func action(
        for line: String,
        itinerary: RiderItinerary,
        before: [RouteCoordinate],
        after: [RouteCoordinate]
    ) throws -> ItineraryAction {
        guard let name = token(after: "itinerary action=", in: line) else {
            throw ReplayError.malformed(line)
        }
        switch name {
        case "replaceAll":
            return .replaceAll(waypoints: after, profile: .balanced, allowUnknown: false)
        case "append":
            guard let coordinate = after.last else { throw ReplayError.malformed(line) }
            return .append(coordinate: coordinate)
        case "insert":
            guard after.count == before.count + 1,
                  let insertion = firstDifferentIndex(before, after),
                  insertion > 0,
                  itinerary.legs.indices.contains(insertion - 1)
            else { throw ReplayError.malformed(line) }
            return .insert(afterLegID: itinerary.legs[insertion - 1].id, coordinate: after[insertion])
        case "move":
            guard before.count == after.count,
                  let index = firstDifferentIndex(before, after),
                  itinerary.waypoints.indices.contains(index)
            else { throw ReplayError.malformed(line) }
            return .move(waypointID: itinerary.waypoints[index].id, to: after[index])
        case "delete":
            guard before.count == after.count + 1,
                  let index = firstDifferentIndex(after, before),
                  itinerary.waypoints.indices.contains(index)
            else { throw ReplayError.malformed(line) }
            return .delete(waypointID: itinerary.waypoints[index].id)
        case "clear":
            return .clear
        case "rebuild":
            return .rebuild
        default:
            throw ReplayError.malformed(line)
        }
    }

    private static func firstDifferentIndex(
        _ shorterOrEqual: [RouteCoordinate],
        _ longerOrEqual: [RouteCoordinate]
    ) -> Int? {
        let shared = min(shorterOrEqual.count, longerOrEqual.count)
        for index in 0..<shared where shorterOrEqual[index] != longerOrEqual[index] {
            return index
        }
        return shorterOrEqual.count == longerOrEqual.count ? nil : shared
    }

    private static func coordinates(named name: String, in line: String) throws -> [RouteCoordinate] {
        let prefix = "\(name)=["
        guard let start = line.range(of: prefix),
              let end = line[start.upperBound...].firstIndex(of: "]")
        else { throw ReplayError.malformed(line) }
        let body = line[start.upperBound..<end]
        if body.isEmpty { return [] }
        return try body.split(separator: ";").map { pair in
            let values = pair.split(separator: ",")
            guard values.count == 2,
                  let latitude = Double(values[0]),
                  let longitude = Double(values[1])
            else { throw ReplayError.malformed(line) }
            return RouteCoordinate(longitude: longitude, latitude: latitude)
        }
    }

    private static func token(after prefix: String, in line: String) -> String? {
        guard let range = line.range(of: prefix) else { return nil }
        return line[range.upperBound...].split(separator: " ").first.map(String.init)
    }
}
