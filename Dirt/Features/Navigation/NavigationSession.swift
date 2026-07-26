import CoreLocation
import Foundation
import Observation

/// Turn-by-turn session: follows the rider along the routed polyline, surfaces
/// the next cue, upcoming surface changes (Mapbox RoadSurface-style), and asks
/// for a recalculation when the rider leaves the line.
@Observable
final class NavigationSession {
    enum Phase {
        case idle
        case prefetching
        case active
    }

    private(set) var phase: Phase = .idle
    private(set) var coordinates: [RouteCoordinate] = []
    private(set) var maneuvers: [RouteManeuver] = []
    /// Along-route surface runs built from `/api/route` segments (OSM fabric).
    private(set) var surfaceRuns: [SurfaceRun] = []
    private var cumulative: [Double] = []
    private(set) var totalMeters: Double = 0
    private(set) var remainingMeters: Double = 0
    private(set) var traveledMeters: Double = 0
    private(set) var currentCue = "Follow the route"
    private(set) var currentCueMeters: Double?
    private(set) var currentSurfaceLabel: String?
    private(set) var upcomingSurfaceAlert: String?
    private(set) var offRoute = false
    private var offRouteStrikes = 0
    private var lastRerouteRequest: Date?
    private var lastSurfaceAlertKey: String?

    struct SurfaceRun: Sendable {
        let startMeters: Double
        let endMeters: Double
        let surfaceKey: String
        let isAdventure: Bool

        var label: String { RouteSegment.riderFacingSurfaceLabel(surfaceKey) }
    }

    /// Wired by the planner: recalculates from the rider's position to the
    /// preserved destination with the same profile + access policy.
    var onRerouteNeeded: (() -> Void)?

    var etaSeconds: Double? {
        guard phase == .active, remainingMeters > 0 else { return nil }
        return remainingMeters / 12.0 // ~43 km/h mixed-surface planning speed
    }

    func beginPrefetch() {
        phase = .prefetching
    }

    func activate(
        coordinates: [RouteCoordinate],
        maneuvers: [RouteManeuver],
        segments: [RouteDisplaySegment] = []
    ) {
        self.coordinates = coordinates
        self.maneuvers = maneuvers.sorted { ($0.alongMeters ?? 0) < ($1.alongMeters ?? 0) }
        cumulative = GeoMath.cumulativeMeters(coordinates)
        totalMeters = cumulative.last ?? 0
        remainingMeters = totalMeters
        traveledMeters = 0
        surfaceRuns = Self.buildSurfaceRuns(segments: segments, totalMeters: totalMeters)
        offRoute = false
        offRouteStrikes = 0
        lastSurfaceAlertKey = nil
        currentCue = "Follow the route"
        currentCueMeters = nil
        currentSurfaceLabel = surfaceRuns.first?.label
        upcomingSurfaceAlert = nil
        phase = .active
    }

    /// Replaces the line mid-trip (recalculate). Offline tiles are kept.
    func replaceRoute(
        coordinates: [RouteCoordinate],
        maneuvers: [RouteManeuver],
        segments: [RouteDisplaySegment] = []
    ) {
        guard phase == .active else { return }
        activate(coordinates: coordinates, maneuvers: maneuvers, segments: segments)
        currentCue = "Route recalculated"
    }

    func update(with location: CLLocation) {
        guard phase == .active, coordinates.count > 1 else { return }
        guard let nearest = GeoMath.nearestVertex(to: location, in: coordinates) else { return }

        traveledMeters = cumulative[nearest.index]
        remainingMeters = max(0, totalMeters - traveledMeters + min(nearest.meters, 50))

        if nearest.meters > 80 {
            offRouteStrikes += 1
        } else {
            offRouteStrikes = 0
            offRoute = false
        }

        if offRouteStrikes >= 3 {
            offRoute = true
            currentCue = "Off route — recalculating…"
            currentCueMeters = nil
            upcomingSurfaceAlert = nil
            let now = Date()
            if lastRerouteRequest == nil || now.timeIntervalSince(lastRerouteRequest!) > 20 {
                lastRerouteRequest = now
                onRerouteNeeded?()
            }
            return
        }

        updateSurfaceContext()

        let nextManeuver = maneuvers.first(where: { ($0.alongMeters ?? 0) > traveledMeters + 15 })
        let metersToTurn = nextManeuver.flatMap { man -> Double? in
            guard let along = man.alongMeters else { return nil }
            return max(0, along - traveledMeters)
        }

        // Prefer turn cues when a maneuver is close; otherwise promote surface alerts
        // (Mapbox-style unpaved notifications from OSM segment classes).
        if let next = nextManeuver, let metersToTurn, metersToTurn < 250 {
            currentCue = next.instruction ?? next.type ?? "Continue"
            currentCueMeters = metersToTurn
        } else if let alert = upcomingSurfaceAlert {
            currentCue = alert
            currentCueMeters = nil
        } else if let next = nextManeuver, let metersToTurn {
            currentCue = next.instruction ?? next.type ?? "Continue"
            currentCueMeters = metersToTurn
        } else {
            currentCue = remainingMeters < 120 ? "Arriving at destination" : "Continue on route"
            currentCueMeters = remainingMeters < 120 ? remainingMeters : nil
        }
    }

    func end() {
        phase = .idle
        coordinates = []
        maneuvers = []
        surfaceRuns = []
        cumulative = []
        totalMeters = 0
        remainingMeters = 0
        traveledMeters = 0
        offRoute = false
        currentCue = "Follow the route"
        currentCueMeters = nil
        currentSurfaceLabel = nil
        upcomingSurfaceAlert = nil
        lastSurfaceAlertKey = nil
    }

    // MARK: - Surface awareness (OSM segment classes ↔ Mapbox RoadSurface idea)

    private func updateSurfaceContext() {
        guard let current = surfaceRuns.first(where: {
            traveledMeters >= $0.startMeters && traveledMeters < $0.endMeters
        }) ?? surfaceRuns.last else {
            currentSurfaceLabel = nil
            upcomingSurfaceAlert = nil
            return
        }
        currentSurfaceLabel = current.label

        // Look ~600 m ahead for a change onto adventure / unpaved surface.
        let lookAhead = traveledMeters + 600
        if let upcoming = surfaceRuns.first(where: {
            $0.startMeters > traveledMeters + 40
                && $0.startMeters <= lookAhead
                && $0.isAdventure
                && !current.isAdventure
        }) {
            let key = "\(Int(upcoming.startMeters))-\(upcoming.surfaceKey)"
            if lastSurfaceAlertKey != key {
                lastSurfaceAlertKey = key
            }
            let distance = Int(max(0, upcoming.startMeters - traveledMeters))
            upcomingSurfaceAlert = "\(upcoming.label) in \(distance) m"
        } else {
            upcomingSurfaceAlert = nil
        }
    }

    static func buildSurfaceRuns(
        segments: [RouteDisplaySegment],
        totalMeters: Double
    ) -> [SurfaceRun] {
        guard !segments.isEmpty else {
            return [SurfaceRun(startMeters: 0, endMeters: max(totalMeters, 1), surfaceKey: "connector", isAdventure: false)]
        }
        var runs: [SurfaceRun] = []
        var cursor = 0.0
        for segment in segments {
            let length = GeoMath.lineMeters(segment.coordinates)
            let end = cursor + max(length, 0)
            let key = segment.surfaceKey
            if let last = runs.last, last.surfaceKey == key {
                runs[runs.count - 1] = SurfaceRun(
                    startMeters: last.startMeters,
                    endMeters: end,
                    surfaceKey: key,
                    isAdventure: last.isAdventure
                )
            } else {
                runs.append(
                    SurfaceRun(
                        startMeters: cursor,
                        endMeters: end,
                        surfaceKey: key,
                        isAdventure: RouteSegment.isAdventureSurface(key)
                    )
                )
            }
            cursor = end
        }
        if let last = runs.last, last.endMeters < totalMeters {
            runs[runs.count - 1] = SurfaceRun(
                startMeters: last.startMeters,
                endMeters: totalMeters,
                surfaceKey: last.surfaceKey,
                isAdventure: last.isAdventure
            )
        }
        return runs
    }
}
