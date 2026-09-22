import Foundation

/// Reuses the selected roads. A generated boundary never causes another search.
/// Keep an unresolved tail so a just-published waypoint never has to move when
/// the destination turns out to be a few metres beyond an 800 km boundary.
public struct EditableRouteLegAssembler: Sendable {
    private let target: Double
    private let threshold: Double
    private let minimumTail: Double
    private var segments: [RouteSegment] = []
    private var boundaries: [EditableRouteBoundary] = []
    private var cues: [NavigationCue] = []
    private var urbanBoxes: [GeographicBox] = []
    private var start: RoadMatch?
    private var startIdentity: String?
    private var latestEnd: RoadMatch?
    private var total = 0.0
    private var emittedMeters = 0.0
    private var emittedSegments = 0
    private var finished = false

    public init(targetMeters: Double = 800_000, thresholdMeters: Double = 1_000_000) {
        precondition(targetMeters > 0 && thresholdMeters >= targetMeters)
        target = targetMeters; threshold = thresholdMeters; minimumTail = targetMeters * 0.25
    }

    public mutating func append(_ part: ComputedRoute) throws -> [ComputedRoute] {
        guard !finished, part.limit == nil, let proof = part.editableBoundaries else {
            throw RoutingFailure.invalidRequest("Editable leg boundary proof is unavailable")
        }
        if let latestEnd, latestEnd.coordinate.distance(to: part.start.coordinate) > 1 {
            throw RoutingFailure.invalidRequest("Editable leg stages are discontinuous")
        }
        if start == nil { start = part.start; startIdentity = part.startRoadIdentity }
        boundaries += proof.map {
            EditableRouteBoundary(segmentCount: segments.count + $0.segmentCount,
                meters: total + $0.meters, match: $0.match,
                incomingRoadIdentity: $0.incomingRoadIdentity)
        }
        cues += part.maneuvers.map {
            NavigationCue(stableID: $0.stableID, type: $0.type, kind: $0.kind,
                instruction: $0.instruction, side: $0.side, degrees: $0.degrees,
                alongMeters: total + $0.alongMeters)
        }
        urbanBoxes += part.qualityUrbanBoxes
        segments += part.segments
        total += part.distanceMeters
        latestEnd = part.end
        var ready: [ComputedRoute] = []
        guard total >= threshold else { return ready }
        while let boundary = boundaries.first(where: {
            $0.segmentCount > emittedSegments && $0.meters >= emittedMeters + target
                && $0.meters <= total - minimumTail
        }) {
            ready.append(try take(through: boundary.segmentCount, meters: boundary.meters,
                end: boundary.match, identity: boundary.incomingRoadIdentity, restrictions: [], final: false))
        }
        return ready
    }

    public mutating func finish(_ complete: ComputedRoute) throws -> [ComputedRoute] {
        guard !finished, complete.limit == nil else {
            throw RoutingFailure.invalidRequest("Cannot finish incomplete editable legs")
        }
        var ready: [ComputedRoute] = []
        if segments.isEmpty { ready = try append(complete) }
        // An alternative chain must reset the assembler. Never attach preview
        // pins to a different final route, even if their endpoints coincide.
        guard segments.count == complete.segments.count,
              zip(segments, complete.segments).allSatisfy({ a, b in
                  a.edgeID == b.edgeID && a.forward == b.forward
                    && a.meters == b.meters && a.geometry == b.geometry
              }), abs(total - complete.distanceMeters) < 1 else {
            throw RoutingFailure.invalidRequest("Editable preview differs from the completed route")
        }
        finished = true
        guard total >= threshold else { return [] }
        if emittedSegments < segments.count {
            ready.append(try take(through: segments.count, meters: total, end: complete.end,
                identity: complete.endRoadIdentity ?? complete.segments.last?.edgeID,
                restrictions: complete.arrivalRestrictions, final: true))
        }
        return ready
    }

    private mutating func take(through count: Int, meters: Double, end: RoadMatch,
                               identity: String?, restrictions: [RestrictionProgress],
                               final: Bool) throws -> ComputedRoute {
        guard let start, count > emittedSegments else {
            throw RoutingFailure.invalidRequest("Empty editable leg")
        }
        let selected = Array(segments[emittedSegments..<count])
        var result = ComputedRoute(start: start, end: end, segments: selected,
            distanceMeters: selected.reduce(0) { $0 + $1.meters }, searchCost: 0,
            poppedLabels: 0, arrivalRestrictions: restrictions)
        result.startRoadIdentity = startIdentity
        result.endRoadIdentity = identity
        result.qualityUrbanBoxes = urbanBoxes
        result.maneuvers = cues.filter {
            $0.alongMeters >= emittedMeters && (final ? $0.alongMeters <= meters : $0.alongMeters < meters)
        }.map {
            NavigationCue(stableID: $0.stableID, type: $0.type, kind: $0.kind,
                instruction: $0.instruction, side: $0.side, degrees: $0.degrees,
                alongMeters: $0.alongMeters - emittedMeters)
        }
        self.start = end; startIdentity = identity
        emittedSegments = count; emittedMeters = meters
        return result
    }
}
