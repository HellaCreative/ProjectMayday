import Foundation

public struct RouteQuality: Sendable {
    public var knownDirtPercent: Double = 0
    public var unknownPercent: Double = 0
    public var minimumSectionDirtPercent: Double = 0
    public var longestPavedRunMeters: Double = 0
    public var urbanMeters: Double = 0
    public var pavedMeters: Double = 0
    /// Metres whose progress along the straight start→finish chord decreases.
    /// Riding around a bay or up a peninsula counts here even when no road is
    /// repeated, so this is a chord diagnostic, not backtracking (§5 rule 5).
    public var backwardMeters: Double = 0
    public var lateralMeters: Double = 0
    /// §5 rule 3: metres of road ridden more than once. Consecutive splits of one
    /// edge in one direction are a single run; every later run of that edge is
    /// re-ridden road, so an out-and-back counts its return.
    public var reriddenMeters: Double = 0
    /// Metres ridden while back within `returnRadiusMeters` of a place the route
    /// already passed at least `returnSpanMeters` of riding earlier. Catches the
    /// loops and out-and-backs that use different roads, which edge reuse alone
    /// cannot see, without charging for weaving around a bay.
    public var returnMeters: Double = 0
    /// Known dirt inside paved→dirt→paved scraps shorter than the useful-run
    /// floor. Candidate selection prefers fewer scrap metres over a slightly
    /// higher dirt % built from orange blips.
    public var shortDirtScrapMeters: Double = 0
    /// Paved metres before the first meaningful (≥1 km) dirt run. Dirt should
    /// take the first proper dirt turn, not a long paved dip first.
    public var leadingPavedMeters: Double = 0
    public static let returnRadiusMeters = 2_000.0
    public static let returnSpanMeters = 10_000.0
    public var totalMeters: Double = 0
    public init() {}

    public init(route: ComputedRoute, urbanBoxes: [GeographicBox] = []) {
        self.init()
        let roads = route.segments.filter { $0.structure != "ferry" }
        totalMeters = roads.reduce(0) { $0+$1.meters }
        guard totalMeters > 0 else { return }
        var known = 0.0, unknown = 0.0, pavedRun = 0.0, walked = 0.0
        var sectionKnown = [Double](repeating: 0,count: 4), sectionTotal = sectionKnown
        for segment in roads {
            let isDirt = segment.surface == .gravel || segment.surface == .loose
            if isDirt { known += segment.meters; pavedRun = 0 }
            else {
                pavedRun += segment.meters
                longestPavedRunMeters = max(longestPavedRunMeters,pavedRun)
                if segment.surface == .unknown { unknown += segment.meters }
                else { pavedMeters += segment.meters }
            }
            var remaining = segment.meters
            while remaining > 0 {
                let section = min(3,Int(walked/(totalMeters/4)))
                let available = max(0,Double(section+1)*totalMeters/4-walked)
                let take = min(remaining,available > 0 ? available : remaining)
                sectionTotal[section] += take
                if isDirt { sectionKnown[section] += take }
                walked += take; remaining -= take
            }
            for (a,b) in zip(segment.geometry,segment.geometry.dropFirst()) {
                let meters = a.distance(to: b)
                if urbanBoxes.contains(where: { !$0.contains(route.start.coordinate) && !$0.contains(route.end.coordinate) && $0.intersects(a,b) }) {
                    urbanMeters += meters
                }
                let delta = Self.progress(b,route.start.coordinate,route.end.coordinate)-Self.progress(a,route.start.coordinate,route.end.coordinate)
                if delta < 0 { backwardMeters += meters }
                let along = min(meters,abs(delta))
                lateralMeters += sqrt(max(0,meters*meters-along*along))
            }
        }
        var leading = 0.0
        var i = 0
        var foundMeaningful = false
        while i < roads.count {
            let isDirt = roads[i].surface == .gravel || roads[i].surface == .loose
            if !isDirt {
                if !foundMeaningful { leading += roads[i].meters }
                i += 1
                continue
            }
            let start = i
            var knownRun = 0.0
            while i < roads.count && (roads[i].surface == .gravel || roads[i].surface == .loose) {
                knownRun += roads[i].meters
                i += 1
            }
            if knownRun >= 1_000 { foundMeaningful = true }
            let pavedBefore = start > 0 && roads[start - 1].surface == .paved
            let pavedAfter = i < roads.count && roads[i].surface == .paved
            if pavedBefore && pavedAfter && knownRun < 2_500 {
                shortDirtScrapMeters += knownRun
            }
        }
        leadingPavedMeters = leading
        reriddenMeters = Self.reriddenMeters(roads)
        returnMeters = Self.returnMeters(roads)
        knownDirtPercent = (known/totalMeters*1000).rounded()/10
        unknownPercent = (unknown/totalMeters*1000).rounded()/10
        minimumSectionDirtPercent = (0..<4).map { sectionTotal[$0] > 0 ? (sectionKnown[$0]/sectionTotal[$0]*1000).rounded()/10 : 0 }.min() ?? 0
    }

    /// A real circuit revisits a source junction after riding away. Merely
    /// passing within kilometres of another road is not a repeated junction.
    public static func hasClosedRoadCircuit(_ segments: [RouteSegment], in graph: any RoadGraph) -> Bool {
        var visited: [Int64: Double] = [:]
        var walked = 0.0
        func revisits(_ node: Int, at meters: Double) -> Bool {
            let id = graph.osmNodeID(node)
            if let before = visited[id], meters - before > 0.5 { return true }
            visited[id] = meters
            return false
        }
        for segment in segments {
            let from = graph.endpoint(segment.edge, from: segment.forward)
            let to = graph.endpoint(segment.edge, from: !segment.forward)
            if let point = segment.geometry.first, point.distance(to: graph.coordinate(node: from)) < 0.1,
               revisits(from, at: walked) { return true }
            walked += segment.meters
            if let point = segment.geometry.last, point.distance(to: graph.coordinate(node: to)) < 0.1,
               revisits(to, at: walked) { return true }
        }
        return false
    }

    /// One run per edge per direction; every repeat of an edge already ridden
    /// counts as re-ridden road (§5 rule 3).
    public static func reriddenMeters(_ segments: [RouteSegment]) -> Double {
        var runs: [(id: String, forward: Bool, meters: Double)] = []
        for segment in segments where segment.structure != "ferry" && !segment.edgeID.isEmpty {
            if let last = runs.last, last.id == segment.edgeID, last.forward == segment.forward {
                runs[runs.count-1].meters += segment.meters
            } else {
                runs.append((segment.edgeID, segment.forward, segment.meters))
            }
        }
        var seen: Set<String> = [], total = 0.0
        for run in runs {
            if seen.insert(run.id).inserted { continue }
            total += run.meters
        }
        return total
    }

    /// Metres ridden while within `radius` of a point the route passed at least
    /// `span` of riding earlier. Cells keep the lookback linear on long routes.
    public static func returnMeters(_ segments: [RouteSegment],
                                    radius: Double = RouteQuality.returnRadiusMeters,
                                    span: Double = RouteQuality.returnSpanMeters) -> Double {
        var points: [(point: Coordinate, ridden: Double)] = []
        var walked = 0.0
        for segment in segments where segment.structure != "ferry" {
            for (a,b) in zip(segment.geometry,segment.geometry.dropFirst()) {
                if points.isEmpty { points.append((a,0)) }
                walked += a.distance(to: b)
                points.append((b,walked))
            }
        }
        guard points.count > 2, radius > 0 else { return 0 }
        struct Cell: Hashable { let x: Int; let y: Int }
        func cell(_ c: Coordinate) -> Cell {
            let perDegree = 111_320.0
            let x = (c.longitude*perDegree*cos(c.latitude * .pi/180)/radius).rounded(.down)
            let y = (c.latitude*perDegree/radius).rounded(.down)
            return Cell(x: Int(x.isFinite ? x : 0), y: Int(y.isFinite ? y : 0))
        }
        var buckets: [Cell:[Int]] = [:]
        var total = 0.0
        for index in points.indices {
            let here = points[index], home = cell(here.point)
            var returning = false
            for dx in -1...1 where !returning {
                for dy in -1...1 where !returning {
                    for earlier in buckets[Cell(x: home.x+dx,y: home.y+dy)] ?? [] {
                        let past = points[earlier]
                        guard here.ridden-past.ridden >= span else { continue }
                        if here.point.distance(to: past.point) <= radius { returning = true; break }
                    }
                }
            }
            if returning, index > 0 { total += here.ridden-points[index-1].ridden }
            buckets[home,default: []].append(index)
        }
        return total
    }

    static func progress(_ p: Coordinate,_ a: Coordinate,_ b: Coordinate) -> Double {
        let ab = a.distance(to: b), ap = a.distance(to: p), pb = p.distance(to: b)
        return ab > 1 ? (ap*ap+ab*ab-pb*pb)/(2*ab) : 0
    }
    public static func prefersDirt(_ a: Self, over b: Self, widthA: Double, widthB: Double) -> Bool {
        // Scraps that inflate dirt % lose to a slightly leaner continuous ride.
        if abs(a.shortDirtScrapMeters - b.shortDirtScrapMeters) > 400 {
            return a.shortDirtScrapMeters < b.shortDirtScrapMeters
        }
        // Prefer taking the first proper dirt turn over a long paved opening dip.
        if abs(a.leadingPavedMeters - b.leadingPavedMeters) > 2_000 {
            return a.leadingPavedMeters < b.leadingPavedMeters
        }
        if abs(a.knownDirtPercent-b.knownDirtPercent) > 2 { return a.knownDirtPercent > b.knownDirtPercent }
        if abs(a.urbanMeters-b.urbanMeters) > 100 { return a.urbanMeters < b.urbanMeters }
        if abs(a.minimumSectionDirtPercent-b.minimumSectionDirtPercent) >= 5 {
            return a.minimumSectionDirtPercent > b.minimumSectionDirtPercent
        }
        if abs(a.longestPavedRunMeters-b.longestPavedRunMeters) > 2000 { return a.longestPavedRunMeters < b.longestPavedRunMeters }
        if abs(a.pavedMeters-b.pavedMeters) > 2000 { return a.pavedMeters < b.pavedMeters }
        let am = a.backwardMeters+a.lateralMeters*0.25, bm = b.backwardMeters+b.lateralMeters*0.25
        if abs(am-bm) > 1000 { return am < bm }
        if a.knownDirtPercent != b.knownDirtPercent { return a.knownDirtPercent > b.knownDirtPercent }
        return widthA < widthB
    }
    public static func shortDirtExcursions(_ segments: [RouteSegment],
                                          maximumKnownMeters: Double = 2_500) -> Set<String> {
        var result: Set<String> = [], i = 0
        while i < segments.count {
            if segments[i].surface == .paved || segments[i].structure == "ferry" { i += 1; continue }
            let start = i
            var known = 0.0
            while i < segments.count && segments[i].surface != .paved && segments[i].structure != "ferry" {
                if segments[i].surface == .gravel || segments[i].surface == .loose { known += segments[i].meters }
                i += 1
            }
            if start > 0 && i < segments.count && segments[start-1].surface == .paved && segments[i].surface == .paved
                && known < maximumKnownMeters {
                result.formUnion(segments[start..<i].map(\.edgeID))
            }
        }
        return result
    }

    public struct ShapeFaults: Sendable, Equatable {
        public var reusedEdgeIDs: Set<String> = []
        public var pinWiggleIDs: Set<String> = []
        public var avoidIDs: Set<String> { reusedEdgeIDs.union(pinWiggleIDs) }
        public var issueCount: Int { reusedEdgeIDs.count + pinWiggleIDs.count }
    }

    /// §5 rule 3: a finished leg must not loop, out-and-back, or W on the same
    /// road into or out of a waypoint. Consecutive splits of one edge are one run.
    public static func shapeFaults(_ segments: [RouteSegment], pinMeters: Double = 2_500) -> ShapeFaults {
        struct Run { let id: String; let forward: Bool; var meters: Double }
        var runs: [Run] = []
        for segment in segments where segment.structure != "ferry" && !segment.edgeID.isEmpty {
            if let last = runs.last, last.id == segment.edgeID, last.forward == segment.forward {
                runs[runs.count - 1].meters += segment.meters
            } else {
                runs.append(Run(id: segment.edgeID, forward: segment.forward, meters: segment.meters))
            }
        }
        var faults = ShapeFaults()
        var seen: [String: Int] = [:]
        for run in runs where run.meters > 80 {
            seen[run.id, default: 0] += 1
        }
        for (id, count) in seen where count >= 2 {
            faults.reusedEdgeIDs.insert(id)
        }
        func wiggle(in slice: ArraySlice<Run>) -> Set<String> {
            var local: [String: Int] = [:]
            for run in slice where run.meters > 40 {
                local[run.id, default: 0] += 1
            }
            return Set(local.compactMap { $0.value >= 2 ? $0.key : nil })
        }
        var walked = 0.0, startEnd = 0
        for (index, run) in runs.enumerated() {
            walked += run.meters
            startEnd = index
            if walked >= pinMeters { break }
        }
        var tail = runs.count
        walked = 0
        for index in stride(from: runs.count - 1, through: 0, by: -1) {
            walked += runs[index].meters
            tail = index
            if walked >= pinMeters { break }
        }
        if !runs.isEmpty {
            faults.pinWiggleIDs.formUnion(wiggle(in: runs.prefix(startEnd + 1)))
            if tail < runs.count {
                faults.pinWiggleIDs.formUnion(wiggle(in: runs.suffix(from: tail)))
            }
        }
        faults.pinWiggleIDs.subtract(faults.reusedEdgeIDs)
        return faults
    }
}
