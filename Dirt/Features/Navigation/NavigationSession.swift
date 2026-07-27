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
    /// Cumulative along-meters at each stage end (empty = single destination).
    private(set) var stageEndMeters: [Double] = []
    private(set) var currentCue = "Follow the route"
    private(set) var currentCueMeters: Double?
    /// Structured maneuver behind `currentCue` (side / rally number / kind) for
    /// the HUD cue card. Nil for surface alerts, off-route, and arrival states.
    private(set) var currentManeuver: RouteManeuver?
    /// Wall-clock start of the active session (survives mid-trip reroutes).
    private(set) var startedAt: Date?
    private(set) var currentSurfaceLabel: String?
    private(set) var upcomingSurfaceAlert: String?
    private(set) var offRoute = false
    /// Live speed (m/s) from the last GPS fix — used for ETA when moving.
    private var lastSpeedMPS: Double = 0
    /// Web cue filter (`dirt_cue_mode_v1`).
    var cueMode: NavigationCueMode = .all
    /// Optional speech hook wired by AppEnvironment.
    var onCueAnnounced: ((String, Double?) -> Void)?
    private var offRouteStrikes = 0
    private var lastRerouteRequest: Date?
    private var lastSurfaceAlertKey: String?
    private var lastAnnouncedCue: String?

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

    /// Remaining seconds to the **current stage end** (or final destination).
    /// Uses live speed when moving (>2 m/s), else ~43 km/h planning speed.
    var etaSeconds: Double? {
        guard phase == .active else { return nil }
        let remain = remainingInCurrentStageMeters
        guard remain > 0 else { return 0 }
        let speed = lastSpeedMPS > 2 ? lastSpeedMPS : 12.0
        return remain / speed
    }

    /// 1-based stage index for HUD label (nil when single-leg From here).
    var currentStageNumber: Int? {
        guard stageEndMeters.count > 1 else { return nil }
        for (index, end) in stageEndMeters.enumerated() {
            if traveledMeters < end - 5 { return index + 1 }
        }
        return stageEndMeters.count
    }

    var travelTimeLabel: String {
        if let stage = currentStageNumber {
            return "travel time stage \(stage)"
        }
        return "travel time"
    }

    private var remainingInCurrentStageMeters: Double {
        guard let end = stageEndMeters.first(where: { $0 > traveledMeters + 1 }) else {
            return remainingMeters
        }
        return max(0, end - traveledMeters)
    }

    func beginPrefetch() {
        phase = .prefetching
    }

    func activate(
        coordinates: [RouteCoordinate],
        maneuvers: [RouteManeuver],
        segments: [RouteDisplaySegment] = [],
        stageEndMeters: [Double] = []
    ) {
        self.coordinates = coordinates
        self.maneuvers = maneuvers.sorted { ($0.alongMeters ?? 0) < ($1.alongMeters ?? 0) }
        cumulative = GeoMath.cumulativeMeters(coordinates)
        totalMeters = cumulative.last ?? 0
        remainingMeters = totalMeters
        traveledMeters = 0
        self.stageEndMeters = stageEndMeters.isEmpty
            ? (totalMeters > 0 ? [totalMeters] : [])
            : stageEndMeters
        surfaceRuns = Self.buildSurfaceRuns(segments: segments, totalMeters: totalMeters)
        offRoute = false
        offRouteStrikes = 0
        lastSurfaceAlertKey = nil
        currentCue = "Follow the route"
        currentCueMeters = nil
        currentManeuver = nil
        currentSurfaceLabel = surfaceRuns.first?.label
        upcomingSurfaceAlert = nil
        if phase != .active { startedAt = Date() }
        phase = .active
    }

    /// Replaces the line mid-trip (recalculate). Offline tiles are kept.
    func replaceRoute(
        coordinates: [RouteCoordinate],
        maneuvers: [RouteManeuver],
        segments: [RouteDisplaySegment] = [],
        stageEndMeters: [Double] = []
    ) {
        guard phase == .active else { return }
        activate(
            coordinates: coordinates,
            maneuvers: maneuvers,
            segments: segments,
            stageEndMeters: stageEndMeters.isEmpty ? self.stageEndMeters : stageEndMeters
        )
        currentCue = "Route recalculated"
    }

    func update(with location: CLLocation) {
        guard phase == .active, coordinates.count > 1 else { return }
        if location.speed >= 0 {
            lastSpeedMPS = location.speed
        }
        // Project onto the nearest segment (not just the nearest vertex).
        // Vertex-only distance triggers false off-route alerts mid-segment:
        // a rider on a curved road can sit 80+ m from the nearest vertex while
        // riding directly on the surface. HTML POC uses the same segment-projection
        // approach (projectPointOnRoute / NAV_ON_ROUTE_KM = 50 m).
        guard let proj = GeoMath.nearestProjection(to: location, in: coordinates, cumulative: cumulative) else { return }

        traveledMeters = proj.alongMeters
        remainingMeters = max(0, totalMeters - traveledMeters)

        // 50 m threshold matches the HTML POC (NAV_ON_ROUTE_KM = 0.05 km).
        // Three consecutive misses required before declaring off-route so GPS
        // scatter and brief shadows don't trigger unnecessary reroutes.
        if proj.offMeters > 50 {
            offRouteStrikes += 1
        } else {
            offRouteStrikes = 0
            offRoute = false
        }

        if offRouteStrikes >= 3 {
            offRoute = true
            currentCue = "Off route — recalculating…"
            currentCueMeters = nil
            currentManeuver = nil
            upcomingSurfaceAlert = nil
            let now = Date()
            if lastRerouteRequest == nil || now.timeIntervalSince(lastRerouteRequest!) > 20 {
                lastRerouteRequest = now
                onRerouteNeeded?()
            }
            return
        }

        updateSurfaceContext()

        let visibleManeuvers = maneuvers.filter { $0.matches(cueMode: cueMode) }
        let nextManeuver = visibleManeuvers.first(where: { ($0.alongMeters ?? 0) > traveledMeters + 15 })
        let metersToTurn = nextManeuver.flatMap { man -> Double? in
            guard let along = man.alongMeters else { return nil }
            return max(0, along - traveledMeters)
        }

        // Prefer turn cues when a maneuver is close; otherwise promote surface alerts
        // (Mapbox-style unpaved notifications from OSM segment classes).
        if let next = nextManeuver, let metersToTurn, metersToTurn < 250 {
            currentCue = next.displayLabel(cueMode: cueMode)
            currentCueMeters = metersToTurn
            currentManeuver = next
        } else if let alert = upcomingSurfaceAlert {
            currentCue = alert
            currentCueMeters = nil
            currentManeuver = nil
        } else if let next = nextManeuver, let metersToTurn {
            currentCue = next.displayLabel(cueMode: cueMode)
            currentCueMeters = metersToTurn
            currentManeuver = next
        } else if remainingInCurrentStageMeters < 120 {
            if let stage = currentStageNumber, stageEndMeters.count > 1,
               traveledMeters < (stageEndMeters.last ?? 0) - 30 {
                currentCue = "Arriving at stage \(stage)"
            } else {
                currentCue = "Arriving at destination"
            }
            currentCueMeters = remainingInCurrentStageMeters
            currentManeuver = nil
        } else {
            currentCue = "Continue on route"
            currentCueMeters = nil
            currentManeuver = nil
        }

        announceCueIfNeeded()
    }

    private func announceCueIfNeeded() {
        guard phase == .active else { return }
        // Distance bands match HTML speak cadence (now / near / mid).
        let band: Int
        if let meters = currentCueMeters {
            if meters < 40 { band = 0 }
            else if meters < 120 { band = 1 }
            else if meters < 250 { band = 2 }
            else { band = 3 }
        } else {
            band = -1
        }
        let spoken: String
        if let man = currentManeuver {
            spoken = man.spokenLabel(cueMode: cueMode, meters: currentCueMeters)
        } else {
            spoken = currentCue
        }
        let key = "\(spoken)|\(band)"
        guard key != lastAnnouncedCue else { return }
        lastAnnouncedCue = key
        onCueAnnounced?(spoken, currentCueMeters)
    }

    func end() {
        phase = .idle
        coordinates = []
        maneuvers = []
        surfaceRuns = []
        cumulative = []
        stageEndMeters = []
        totalMeters = 0
        remainingMeters = 0
        traveledMeters = 0
        offRoute = false
        currentCue = "Follow the route"
        currentCueMeters = nil
        currentManeuver = nil
        currentSurfaceLabel = nil
        upcomingSurfaceAlert = nil
        lastSurfaceAlertKey = nil
        lastAnnouncedCue = nil
        startedAt = nil
        lastSpeedMPS = 0
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
