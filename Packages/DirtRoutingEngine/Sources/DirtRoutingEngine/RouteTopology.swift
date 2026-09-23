import Foundation

/// Junction passages, rather than map-line intersections: a bridge over another
/// road is not a crossing, and a shared lollipop stem is not a figure-eight.
enum RouteTopology {
    struct Passage {
        let node: Int
        let incoming: Int
        let outgoing: Int
    }
    static func passages(_ segments: [RouteSegment], graph: any RoadGraph) -> [Passage] {
        let roads = segments.filter { $0.meters > 0.01 }
        return zip(roads, roads.dropFirst()).compactMap { a, b in
            let node = graph.endpoint(a.edge, from: !a.forward)
            guard graph.osmNodeID(node) == graph.osmNodeID(graph.endpoint(b.edge, from: b.forward)),
                  let end = a.geometry.last, let start = b.geometry.first,
                  end.distance(to: graph.coordinate(node: node)) < 0.1,
                  start.distance(to: end) < 0.1 else { return nil }
            return Passage(node: node, incoming: a.edge, outgoing: b.edge)
        }
    }
    static func crossings(_ segments: [RouteSegment], companion: Set<String>,
                          graph: any RoadGraph, endpoints: [Coordinate]) -> Set<Int> {
        guard !companion.isEmpty else { return [] }
        var result = Set<Int>()
        for passage in passages(segments, graph: graph) {
            let point = graph.coordinate(node: passage.node)
            guard !endpoints.contains(where: { $0.distance(to: point) < 250 }),
                  !graph.matches(passage.incoming, identities: companion),
                  !graph.matches(passage.outgoing, identities: companion) else { continue }
            let other = Set(graph.outgoing(passage.node).filter {
                graph.matches($0.edge, identities: companion)
            }.map(\.edge))
            if other.count >= 2 { result.insert(passage.node) }
        }
        return result
    }
    static func selfCrossings(_ segments: [RouteSegment], graph: any RoadGraph) -> Set<Int> {
        var seen: [Int64: [Passage]] = [:]
        var result = Set<Int>()
        for passage in passages(segments, graph: graph) {
            let key = graph.osmNodeID(passage.node)
            let arms = Set([passage.incoming, passage.outgoing])
            if arms.count == 2, (seen[key] ?? []).contains(where: {
                let other = Set([$0.incoming, $0.outgoing])
                return other.count == 2 && arms.isDisjoint(with: other)
            }) { result.insert(passage.node) }
            seen[key, default: []].append(passage)
        }
        return result
    }
}
