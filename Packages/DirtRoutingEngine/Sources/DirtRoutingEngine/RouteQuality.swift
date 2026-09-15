import Foundation

public struct RouteQuality: Sendable {
    public var knownDirtPercent: Double = 0
    public var unknownPercent: Double = 0
    public var minimumSectionDirtPercent: Double = 0
    public var longestPavedRunMeters: Double = 0
    public var urbanMeters: Double = 0
    public var pavedMeters: Double = 0
    public var backwardMeters: Double = 0
    public var lateralMeters: Double = 0
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
        knownDirtPercent = (known/totalMeters*1000).rounded()/10
        unknownPercent = (unknown/totalMeters*1000).rounded()/10
        minimumSectionDirtPercent = (0..<4).map { sectionTotal[$0] > 0 ? (sectionKnown[$0]/sectionTotal[$0]*1000).rounded()/10 : 0 }.min() ?? 0
    }

    static func progress(_ p: Coordinate,_ a: Coordinate,_ b: Coordinate) -> Double {
        let ab = a.distance(to: b), ap = a.distance(to: p), pb = p.distance(to: b)
        return ab > 1 ? (ap*ap+ab*ab-pb*pb)/(2*ab) : 0
    }
    public static func prefersDirt(_ a: Self, over b: Self, widthA: Double, widthB: Double) -> Bool {
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
    public static func shortDirtExcursions(_ segments: [RouteSegment]) -> Set<String> {
        var result: Set<String> = [], i = 0
        while i < segments.count {
            if segments[i].surface == .paved || segments[i].structure == "ferry" { i += 1; continue }
            let start = i
            var known = 0.0
            while i < segments.count && segments[i].surface != .paved && segments[i].structure != "ferry" {
                if segments[i].surface == .gravel || segments[i].surface == .loose { known += segments[i].meters }
                i += 1
            }
            if start > 0 && i < segments.count && segments[start-1].surface == .paved && segments[i].surface == .paved && known < 1000 {
                result.formUnion(segments[start..<i].map(\.edgeID))
            }
        }
        return result
    }
}
