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
            guard !alternatives.isEmpty, incoming.access != 4, outgoing.access != 4,
                  incoming.geometry.count >= 2, outgoing.geometry.count >= 2 else { continue }
            let a = incoming.geometry[incoming.geometry.count-2], b = incoming.geometry.last!, c = outgoing.geometry[1]
            var delta = (b.bearing(to: c)-a.bearing(to: b))*180 / .pi
            while delta > 180 { delta -= 360 }; while delta < -180 { delta += 360 }
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
}
