import Foundation

public struct NavigationCue: Codable, Sendable, Equatable {
    public let stableID: String
    public let type: String
    public let kind: String
    public let instruction: String
    public let side: String?
    public let degrees: Double?
    public let alongMeters: Double
}

struct NavigationCues {
    static func make(route: ComputedRoute,graph: any RoadGraph,access: AccessPolicy,arrival: SearchArrival?) -> [NavigationCue] {
        let segments = route.segments
        guard let last = segments.last else { return [] }
        var result: [NavigationCue] = [], along = 0.0, active = arrival?.restrictions ?? []
        for i in 1..<segments.count {
            let incoming = segments[i-1], outgoing = segments[i]
            along += incoming.meters
            let node = graph.endpoint(incoming.edge,from: !incoming.forward)
            guard node == graph.endpoint(outgoing.edge,from: outgoing.forward) else { continue }
            let from = graph.restrictionEdge(incoming.edge), to = graph.restrictionEdge(outgoing.edge)
            let alternatives = graph.outgoing(node).filter { arc in
                let id = graph.restrictionEdge(arc.edge)
                return id != from && id != to && graph.distance(arc.edge) >= 30 &&
                    !["service","parking","driveway"].contains(graph.roadClass(arc.edge)) &&
                    access.permits(graph.accessCode(arc.edge,forward: arc.forward),isStart: false,isEnd: false) &&
                    graph.restrictionIndex.advance(active,from: from,to: id,at: node) != nil
            }
            active = graph.restrictionIndex.advance(active,from: from,to: to,at: node) ?? []
            guard incoming.access != 4, outgoing.access != 4,
                  let delta = turnDegrees(incoming: incoming.geometry, outgoing: outgoing.geometry) else { continue }
            // A legal U-turn is itself a decision even at a dead end. Other
            // calls require a plausible graph branch, never just a road bend.
            guard abs(delta) >= 160 || !alternatives.isEmpty else { continue }
            let degrees = abs(delta).rounded(), straight = degrees < 30, turnAround = degrees >= 160
            let side = straight ? nil : delta > 0 ? "right" : "left"
            result.append(.init(stableID: "jct:\(incoming.edgeID)>\(outgoing.edgeID)",
                type: straight ? "continueStraight" : turnAround ? "uTurn" : "turn",kind: "junction",
                instruction: straight ? "Continue straight" : turnAround ? "Turn around" : "Turn \(side!)",
                side: side,degrees: degrees,alongMeters: along.rounded()))
        }
        result.append(.init(stableID: "arrive:\(last.edgeID)",type: "arrive",kind: "arrive",
                            instruction: "Arrive at destination",side: nil,degrees: nil,alongMeters: route.distanceMeters.rounded()))
        return result
    }
    /// Measure the road approaches, not a tiny OSM vertex at the junction.
    /// Short vertex pairs can say straight while the rider is still in a bend.
    static func turnDegrees(incoming: [Coordinate], outgoing: [Coordinate]) -> Double? {
        guard incoming.count >= 2, outgoing.count >= 2,
              let junction = incoming.last else { return nil }
        func approach(_ points: [Coordinate]) -> Coordinate {
            var remaining = 25.0
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i], meters = a.distance(to: b)
                if meters >= remaining, meters > 0 {
                    let fraction = remaining / meters
                    return Coordinate(longitude: a.longitude + (b.longitude - a.longitude) * fraction,
                                      latitude: a.latitude + (b.latitude - a.latitude) * fraction)
                }
                remaining -= meters
            }
            return points.last!
        }
        let before = approach(Array(incoming.reversed())), after = approach(outgoing)
        guard before.distance(to: junction) > 0.1, junction.distance(to: after) > 0.1 else { return nil }
        var delta = (junction.bearing(to: after) - before.bearing(to: junction)) * 180 / .pi
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

}
