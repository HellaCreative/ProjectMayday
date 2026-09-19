import Foundation

public struct RoadMatch: Sendable, Equatable {
    public let edge: Int
    public let coordinate: Coordinate
    public let distanceMeters: Double
    public let alongMeters: Double
    public let geometryMeters: Double
    public let forward: Bool?
    public let score: Double
    public init(edge: Int,coordinate: Coordinate,distanceMeters: Double,alongMeters: Double,geometryMeters: Double,
                forward: Bool? = nil,score: Double? = nil) {
        self.edge = edge; self.coordinate = coordinate; self.distanceMeters = distanceMeters
        self.alongMeters = alongMeters; self.geometryMeters = geometryMeters
        self.forward = forward; self.score = score ?? distanceMeters
    }
    public var fraction: Double { geometryMeters > 0 ? alongMeters / geometryMeters : 0 }
}

public struct AccessPolicy: Sendable {
    public var allowUnknown = false
    public var startIsCustomer = false
    public var endIsCustomer = false
    public init(allowUnknown: Bool = false, startIsCustomer: Bool = false, endIsCustomer: Bool = false) {
        self.allowUnknown = allowUnknown; self.startIsCustomer = startIsCustomer; self.endIsCustomer = endIsCustomer
    }
    /// Off still permits a continuous connector of at most 100 m, bounded by
    /// through-permitted roads. Weak connectivity must include code 1 as an
    /// optimistic possibility, not proof of access or a valid length. Exact search
    /// enforces the continuous cap (and excludes it for Clean); matching stays strict.
    var includesUnknownConnectivity: Bool { true }
    func permits(_ code: UInt8, isStart: Bool, isEnd: Bool) -> Bool {
        switch code {
        case 0: return true
        case 1: return allowUnknown
        case 3: return (isStart && !startIsCustomer) || (isEnd && !endIsCustomer)
        case 4: return (isStart && startIsCustomer) || (isEnd && endIsCustomer)
        default: return false
        }
    }
}

public struct RoadMatcher: Sendable {
    let pack: any RoadGraph
    public init(pack: any RoadGraph) { self.pack = pack }

    /// Exact geometry matching. No coordinate-based node stitching is permitted.
    /// This scan is the reference implementation; a hash-bound spatial index may accelerate it.
    public func matches(at point: Coordinate, radius: Double, start: Bool, policy: AccessPolicy,
                        heading: Double? = nil,intent: Double? = nil,limit: Int = 12, budget: ComputationBudget) throws -> [RoadMatch] {
        guard point.isValid, radius.isFinite, radius > 0, limit > 0 else { throw RoutingFailure.invalidRequest("match parameters") }
        var matches: [RoadMatch] = []
        for (visited,e) in pack.candidates(near: point,radius: radius).enumerated() {
            if visited & 255 == 0 { try budget.check() }
            guard [true,false].contains(where: {
                policy.permits(pack.accessCode(e,forward: $0),isStart: start,isEnd: !start)
            }) else { continue }
            let line = pack.polyline(e)
            guard line.count >= 2 else { continue }
            var walked = 0.0, bestDistance = Double.infinity, bestAlong = 0.0, best = line[0], tangent = 0.0
            for i in 1..<line.count {
                let a = line[i-1], b = line[i]
                guard a.isValid, b.isValid else { throw RoutingFailure.invalidPack("invalid geometry coordinate") }
                let projected = Self.project(point,onto: a,to: b)
                let distance = point.distance(to: projected.point)
                let segment = a.distance(to: b)
                if distance < bestDistance {
                    bestDistance = distance; bestAlong = walked+segment*projected.fraction; best = projected.point
                    tangent = a.bearing(to: b)*180 / .pi
                }
                walked += segment
            }
            if bestDistance <= radius {
                for direction in [true,false] where policy.permits(pack.accessCode(e,forward: direction),isStart: start,isEnd: !start) {
                    let bearing = direction ? tangent : tangent+180
                    let customer = start ? policy.startIsCustomer : policy.endIsCustomer
                    var score = bestDistance
                    if !customer, let heading, heading.isFinite { score += Self.angle(heading,bearing)*0.4 }
                    if !customer, let intent, intent.isFinite { score += Self.angle(intent,bearing)*0.25 }
                    matches.append(.init(edge: e,coordinate: best,distanceMeters: bestDistance,alongMeters: bestAlong,
                                         geometryMeters: walked,forward: direction,score: score))
                }
            }
        }
        let sorted = matches.enumerated().sorted {
            $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score < $1.element.score
        }.map(\.element)
        let headingRef = heading ?? intent
        var kept: [RoadMatch] = []
        for candidate in sorted {
            if suppressOpposite(candidate, kept: kept, heading: headingRef) { continue }
            kept.append(candidate)
            if kept.count >= limit { break }
        }
        let customer = start ? policy.startIsCustomer : policy.endIsCustomer
        let nearest = kept.first?.distanceMeters ?? .infinity
        return kept.filter { !customer || $0.distanceMeters <= nearest+2 }
    }
    /// JS `median_opposite_carriageway`: drop a nearby reverse carriageway when
    /// heading/intent already selected a better-facing legal road.
    private func suppressOpposite(_ candidate: RoadMatch, kept: [RoadMatch], heading: Double?) -> Bool {
        guard let heading, candidate.distanceMeters < 80, let candidateForward = candidate.forward else { return false }
        let candidateTangent = Self.travelBearing(pack.polyline(candidate.edge), along: candidate.alongMeters, forward: candidateForward)
        for previous in kept where previous.distanceMeters < 80 && previous.edge != candidate.edge {
            guard let previousForward = previous.forward else { continue }
            // Roads meeting at a source junction are departure alternatives,
            // not opposite carriageways. The viable road may initially point
            // away from the destination (a bend, spur or geographic detour).
            // Keep both and let legal search decide; intent still ranks them.
            let candidateEnds = [pack.endpoint(candidate.edge, from: true), pack.endpoint(candidate.edge, from: false)]
            let previousEnds = [pack.endpoint(previous.edge, from: true), pack.endpoint(previous.edge, from: false)]
            if candidateEnds.contains(where: { a in previousEnds.contains(where: { b in
                a == b || (pack.osmNodeID(a) != 0 && pack.osmNodeID(a) == pack.osmNodeID(b))
            }) }) { continue }
            let previousTangent = Self.travelBearing(pack.polyline(previous.edge), along: previous.alongMeters, forward: previousForward)
            guard RoadMatcher.angle(previousTangent, candidateTangent) > 140 else { continue }
            if RoadMatcher.angle(heading, candidateTangent) > 70 && RoadMatcher.angle(heading, previousTangent) < 40 {
                return true
            }
        }
        return false
    }
    static func travelBearing(_ line: [Coordinate], along: Double, forward: Bool) -> Double {
        guard line.count >= 2 else { return 0 }
        var walked = 0.0
        for i in 1..<line.count {
            let segment = line[i-1].distance(to: line[i])
            if walked+segment >= along || i == line.count-1 {
                let tangent = line[i-1].bearing(to: line[i])*180 / .pi
                return forward ? tangent : tangent+180
            }
            walked += segment
        }
        return 0
    }
    static func angle(_ a: Double,_ b: Double) -> Double {
        let d = abs(a-b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360-d : d
    }
    /// JS `legal-topology/snap.js` `projectOnSegment`: unscaled lon/lat. A
    /// latitude-scaled projector chose a different destination road on the
    /// published NS short Dirt comparison.
    static func project(_ p: Coordinate, onto a: Coordinate, to b: Coordinate) -> (point: Coordinate,fraction: Double) {
        let dx = b.longitude-a.longitude, dy = b.latitude-a.latitude
        let d = dx*dx+dy*dy
        let t = d > 0 ? min(1,max(0,((p.longitude-a.longitude)*dx+(p.latitude-a.latitude)*dy)/d)) : 0
        return (.init(longitude: a.longitude+dx*t,latitude: a.latitude+dy*t),t)
    }
}

enum WeakComponents {
    static func ids(in pack: any RoadGraph, allowUnknown: Bool) -> [Int] {
        if let indexed = pack as? IndexedGraph { return indexed.weakComponentIDs(allowUnknown: allowUnknown) }
        return compute(in: pack, allowUnknown: allowUnknown)
    }
    static func compute(in pack: any RoadGraph, allowUnknown: Bool) -> [Int] {
        var parent = Array(0..<pack.nodeCount)
        func find(_ i: Int) -> Int {
            var n = i
            while parent[n] != n { parent[n] = parent[parent[n]]; n = parent[n] }
            return n
        }
        func member(_ code: UInt8) -> Bool {
            code == 0 || code == 3 || code == 4 || (code == 1 && allowUnknown)
        }
        for edge in 0..<pack.edgeCount {
            if member(pack.accessCode(edge,forward: true)) || member(pack.accessCode(edge,forward: false)) {
                let a = find(pack.endpoint(edge,from: true)), b = find(pack.endpoint(edge,from: false))
                if a != b { parent[max(a,b)] = min(a,b) }
            }
        }
        return (0..<pack.nodeCount).map(find)
    }
    static func of(match: RoadMatch, pack: any RoadGraph, ids: [Int]) -> Int {
        let node = pack.endpoint(match.edge, from: match.forward != false)
        guard node >= 0, node < ids.count else { return -1 }
        return ids[node]
    }
}
