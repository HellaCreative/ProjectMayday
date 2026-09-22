import Foundation

/// A whole-segment boundary proven while its graph is still resident. Choosing
/// these boundaries keeps leg geometry and road metadata exact, and avoids
/// converting graph-local restriction progress into an unrelated pack's indices.
public struct EditableRouteBoundary: Sendable {
    public let segmentCount: Int
    public let meters: Double
    public let match: RoadMatch
    public let incomingRoadIdentity: String

    /// Validate completed geometry using the same bounded post-search allowance
    /// as seam validation. This does not renew or fund a path search.
    public static func afterCompletedSearch(in route: ComputedRoute, graph: any RoadGraph,
                              initialRestrictions: [RestrictionProgress] = [],
                              budget: ComputationBudget) throws -> [Self]? {
        try proven(in: route, graph: graph, initialRestrictions: initialRestrictions,
                   budget: budget.afterCompletedSearchForValidation())
    }

    /// Nil means proof failed, not that arbitrary points may be used instead.
    /// Generated points require through-permitted access and no active via-way
    /// sequence. The final rider endpoint is preserved independently by callers.
    public static func proven(in route: ComputedRoute, graph: any RoadGraph,
                              initialRestrictions: [RestrictionProgress] = [],
                              budget: ComputationBudget = .init()) throws -> [Self]? {
        guard route.limit == nil else { return nil }
        var active = initialRestrictions
        var result: [Self] = []
        var meters = 0.0
        for (index, segment) in route.segments.enumerated() {
            try budget.check()
            if index > 0 {
                let prior = route.segments[index - 1]
                // Match PathSearch's zero-length continuation semantics.
                if graph.restrictionEdge(prior.edge) != graph.restrictionEdge(segment.edge)
                    || segment.meters > 0.01 {
                    guard let next = graph.restrictionIndex.advance(active,
                        from: graph.restrictionEdge(prior.edge),
                        to: graph.restrictionEdge(segment.edge),
                        at: graph.endpoint(segment.edge, from: segment.forward)) else { return nil }
                    active = next
                }
            }
            meters += segment.meters
            guard active.isEmpty, segment.access == 0, segment.meters > 0.01,
                  let point = segment.geometry.last else { continue }
            let match: RoadMatch
            if index == route.segments.count - 1 {
                // The rider/stage endpoint may be inside a road, not at its node.
                match = route.end
            } else {
                let geometry = graph.polyline(segment.edge)
                let length = zip(geometry, geometry.dropFirst()).reduce(0.0) {
                    $0 + $1.0.distance(to: $1.1)
                }
                match = RoadMatch(edge: segment.edge, coordinate: point,
                    distanceMeters: 0, alongMeters: segment.forward ? length : 0,
                    geometryMeters: length, forward: segment.forward)
            }
            result.append(Self(segmentCount: index + 1, meters: meters, match: match,
                               incomingRoadIdentity: graph.identity(of: segment.edge)))
        }
        // Replay proof must agree with the actual search's terminal state.
        guard active == route.arrivalRestrictions else { return nil }
        return result
    }
}
