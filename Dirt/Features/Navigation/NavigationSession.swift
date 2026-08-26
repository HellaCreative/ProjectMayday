import CoreLocation
import Foundation
import Observation

/// Rider-facing progress anchor. Geometry may be replaced during a reroute;
/// this identity and label survive so navigation still knows what comes next.
nonisolated struct NavigationStage: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case waypoint
        case fuelStop
        case destination
    }

    let id: String
    let title: String
    let detail: String?
    let kind: Kind
    let endMeters: Double
}

/// Turn-by-turn session: follows the rider along the routed polyline, speaks
/// junction / rally cues only, shows surface changes visually (no voice), and
/// asks for a recalculation when the rider leaves the line.
@MainActor
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
    /// Unfiltered route-engine payload retained across mid-ride mode changes.
    private var sourceManeuvers: [RouteManeuver] = []
    /// Along-route surface runs built from route segments.
    private(set) var surfaceRuns: [SurfaceRun] = []
    /// Network edge spans for ride-intelligence contribution (no stitch IDs).
    private var edgeSpans: [RideEdgeSequence.Span] = []
    /// Ordered unique edge ids entered this session (survives mid-ride recalculate).
    private(set) var riddenEdgeIds: [String] = []
    private var cumulative: [Double] = []
    private(set) var totalMeters: Double = 0
    private(set) var remainingMeters: Double = 0
    private(set) var traveledMeters: Double = 0
    /// Cumulative along-meters at each stage end (empty = single destination).
    private(set) var stageEndMeters: [Double] = []
    private(set) var stages: [NavigationStage] = []
    private(set) var currentCue = "Follow the route"
    private(set) var currentCueMeters: Double?
    /// Structured maneuver behind `currentCue` (side / rally number / kind) for
    /// the HUD cue card. Nil for surface alerts, off-route, and arrival states.
    private(set) var currentManeuver: RouteManeuver?
    private(set) var followingManeuver: RouteManeuver?
    private(set) var followingManeuverMeters: Double?
    /// Wall-clock start of the active session (survives mid-trip reroutes).
    private(set) var startedAt: Date?
    private(set) var currentSurfaceLabel: String?
    private(set) var upcomingSurfaceAlert: String?
    private(set) var offRoute = false
    /// Cumulative uphill meters this session (for HUD climb, not absolute altitude).
    private(set) var climbMeters: Double = 0
    /// Live speed (m/s) from the last GPS fix — used for ETA when moving.
    private var lastSpeedMPS: Double = 0
    private var lastAltitudeMeters: Double?
    /// Cue filter (`dirt_cue_mode_v1`).
    var cueMode: NavigationCueMode = .junctions
    /// Optional speech hook: (spoken text, stable announce key).
    var onCueAnnounced: ((String, String) -> Void)?
    private var offRouteStrikes = 0
    private var lastRerouteRequest: Date?
    private var lastSurfaceAlertKey: String?
    private var deliveredCuePhases: [String: Set<NavigationCuePhase>] = [:]
    private var announcedStageApproaches: Set<String> = []
    private var announcedStageArrivals: Set<String> = []

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
    /// Cancels an in-flight reroute if the rider naturally rejoins the line.
    var onRouteRecovered: (() -> Void)?

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
        currentStage?.title ?? "Destination"
    }

    var remainingInCurrentStageMeters: Double {
        guard let end = stageEndMeters.first(where: { $0 > traveledMeters + 1 }) else {
            return remainingMeters
        }
        return max(0, end - traveledMeters)
    }

    var currentStage: NavigationStage? {
        guard !stages.isEmpty else { return nil }
        return stages.first(where: { $0.endMeters > traveledMeters + 1 }) ?? stages.last
    }

    var finalStage: NavigationStage? { stages.last }

    var elapsedSeconds: Double {
        guard let startedAt else { return 0 }
        return max(0, Date().timeIntervalSince(startedAt))
    }

    func beginPrefetch() {
        phase = .prefetching
    }

    func cancelPrefetch() {
        guard phase == .prefetching else { return }
        phase = .idle
    }

    func activate(
        coordinates: [RouteCoordinate],
        maneuvers: [RouteManeuver],
        segments: [RouteDisplaySegment] = [],
        stageEndMeters: [Double] = [],
        stages: [NavigationStage] = [],
        networkSegments: [RouteSegment] = []
    ) {
        let continuing = phase == .active
        self.coordinates = coordinates
        sourceManeuvers = maneuvers
        self.maneuvers = Self.resolveManeuvers(
            coordinates: coordinates,
            incoming: sourceManeuvers,
            cueMode: cueMode
        )
            .sorted { ($0.alongMeters ?? 0) < ($1.alongMeters ?? 0) }
        cumulative = GeoMath.cumulativeMeters(coordinates)
        totalMeters = cumulative.last ?? 0
        remainingMeters = totalMeters
        traveledMeters = 0
        self.stageEndMeters = stageEndMeters.isEmpty
            ? (totalMeters > 0 ? [totalMeters] : [])
            : stageEndMeters
        self.stages = stages.isEmpty
            ? Self.fallbackStages(for: self.stageEndMeters)
            : stages
        surfaceRuns = Self.buildSurfaceRuns(segments: segments, totalMeters: totalMeters)
        edgeSpans = RideEdgeSequence.spans(from: networkSegments)
        if !continuing {
            riddenEdgeIds = []
            startedAt = Date()
        }
        offRoute = false
        offRouteStrikes = 0
        lastSurfaceAlertKey = nil
        if !continuing {
            deliveredCuePhases = [:]
            announcedStageApproaches = []
            announcedStageArrivals = []
            climbMeters = 0
            lastAltitudeMeters = nil
        }
        currentCue = "Follow the route"
        currentCueMeters = nil
        currentManeuver = nil
        followingManeuver = nil
        followingManeuverMeters = nil
        currentSurfaceLabel = surfaceRuns.first?.label
        upcomingSurfaceAlert = nil
        phase = .active
    }

    /// Cue mode changed mid-ride — rebuild geometry cues and clear speech dedupe.
    func rebuildCuesForCurrentMode() {
        guard phase == .active, coordinates.count > 1 else { return }
        maneuvers = Self.resolveManeuvers(
            coordinates: coordinates,
            incoming: sourceManeuvers,
            cueMode: cueMode
        )
            .sorted { ($0.alongMeters ?? 0) < ($1.alongMeters ?? 0) }
        deliveredCuePhases = [:]
        currentCue = "Follow the route"
        currentCueMeters = nil
        currentManeuver = nil
        followingManeuver = nil
        followingManeuverMeters = nil
    }

    /// Replaces the line mid-trip (recalculate). Offline tiles are kept.
    func replaceRoute(
        coordinates: [RouteCoordinate],
        maneuvers: [RouteManeuver],
        segments: [RouteDisplaySegment] = [],
        stageEndMeters: [Double] = [],
        stages: [NavigationStage]? = nil,
        networkSegments: [RouteSegment] = []
    ) {
        guard phase == .active else { return }
        activate(
            coordinates: coordinates,
            maneuvers: maneuvers,
            segments: segments,
            stageEndMeters: stageEndMeters.isEmpty ? self.stageEndMeters : stageEndMeters,
            stages: stages ?? Self.rebasedStages(
                self.stages,
                onto: stageEndMeters.isEmpty ? self.stageEndMeters : stageEndMeters
            ),
            networkSegments: networkSegments
        )
        currentCue = "Route recalculated"
    }

    func update(with location: CLLocation) {
        guard phase == .active, coordinates.count > 1 else { return }
        if location.speed >= 0 {
            let measured = location.speed
            lastSpeedMPS = lastSpeedMPS > 0
                ? lastSpeedMPS * 0.75 + measured * 0.25
                : measured
        }
        // Accumulate uphill only — ignore noisy verticals and downhill.
        if location.verticalAccuracy >= 0, location.verticalAccuracy < 30 {
            let alt = location.altitude
            if let previous = lastAltitudeMeters {
                let delta = alt - previous
                if delta > 0.5 { climbMeters += delta }
            }
            lastAltitudeMeters = alt
        }
        // Project onto the nearest segment (not just the nearest vertex).
        // Vertex-only distance triggers false off-route alerts mid-segment:
        // a rider on a curved road can sit 80+ m from the nearest vertex while
        // riding directly on the surface. Same segment-projection
        // approach (`nearestProjection` / 50 m on-route).
        guard let proj = GeoMath.nearestProjection(to: location, in: coordinates, cumulative: cumulative) else { return }

        traveledMeters = proj.alongMeters
        remainingMeters = max(0, totalMeters - traveledMeters)
        RideEdgeSequence.appendRidden(
            into: &riddenEdgeIds,
            spans: edgeSpans,
            traveledMeters: traveledMeters
        )

        // 50 m on-route threshold.
        // Three consecutive misses required before declaring off-route so GPS
        // scatter and brief shadows don't trigger unnecessary reroutes.
        let wasOffRoute = offRoute || offRouteStrikes > 0
        if proj.offMeters > 50 {
            offRouteStrikes += 1
        } else {
            offRouteStrikes = 0
            offRoute = false
            if wasOffRoute { onRouteRecovered?() }
        }

        if offRouteStrikes >= 3 {
            offRoute = true
            currentCue = "Off route — recalculating…"
            currentCueMeters = nil
            currentManeuver = nil
            followingManeuver = nil
            followingManeuverMeters = nil
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
        if let nextAlong = nextManeuver?.alongMeters,
           let following = visibleManeuvers.first(where: { ($0.alongMeters ?? 0) > nextAlong + 15 }) {
            followingManeuver = following
            followingManeuverMeters = following.alongMeters.map { max(0, $0 - traveledMeters) }
        } else {
            followingManeuver = nil
            followingManeuverMeters = nil
        }

        // Top cue card + voice are turn-by-turn only. Surface stays on the bottom
        // chrome (`currentSurfaceLabel` / `upcomingSurfaceAlert`) — never steal the
        // maneuver channel when the next junction is still far away.
        if let next = nextManeuver, let metersToTurn {
            currentCue = next.displayLabel(cueMode: cueMode)
            currentCueMeters = metersToTurn
            currentManeuver = next
        } else if remainingInCurrentStageMeters < 120 {
            if let stage = currentStageNumber, stageEndMeters.count > 1,
               traveledMeters < (stageEndMeters.last ?? 0) - 30 {
                currentCue = "Arriving at \(currentStage?.title ?? "stage \(stage)")"
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

        announceCueIfNeeded(nextManeuver: nextManeuver, metersToTurn: metersToTurn)
        announceStageIfNeeded()
    }

    private func announceStageIfNeeded() {
        guard let stage = currentStage else { return }
        let meters = remainingInCurrentStageMeters
        let spokenName: String = {
            if stage.kind == .fuelStop, stage.title.hasPrefix("F") {
                return "Fuel \(stage.title.dropFirst())"
            }
            return stage.title
        }()
        if meters <= 120, !announcedStageArrivals.contains(stage.id) {
            announcedStageApproaches.insert(stage.id)
            announcedStageArrivals.insert(stage.id)
            onCueAnnounced?("Arriving at \(spokenName)", "waypoint-\(stage.id)|now")
        } else if meters <= 2_000, !announcedStageApproaches.contains(stage.id) {
            announcedStageApproaches.insert(stage.id)
            onCueAnnounced?("\(spokenName) in two kilometres", "waypoint-\(stage.id)|prepare")
        }
    }

    private func announceCueIfNeeded(nextManeuver: RouteManeuver?, metersToTurn: Double?) {
        guard phase == .active else { return }
        guard let man = nextManeuver, let meters = metersToTurn else { return }

        guard let cuePhase = NavigationCuePhase.phase(
            forMeters: meters,
            speedMPS: lastSpeedMPS
        ) else { return }

        let identity = man.announceIdentity
        let delivered = deliveredCuePhases[identity] ?? []
        guard !delivered.contains(cuePhase) else { return }
        // A rider who first enters the window at "now" must never receive a
        // late prepare after GPS jitter moves the projection backwards.
        var updated = delivered
        if cuePhase == .now { updated.insert(.prepare) }
        updated.insert(cuePhase)
        deliveredCuePhases[identity] = updated

        let spoken = man.spokenLabel(cueMode: cueMode, meters: meters, phase: cuePhase)
        let key = "\(identity)|\(cuePhase.rawValue)"
        onCueAnnounced?(spoken, key)
    }

    func end() {
        phase = .idle
        coordinates = []
        maneuvers = []
        sourceManeuvers = []
        surfaceRuns = []
        edgeSpans = []
        riddenEdgeIds = []
        cumulative = []
        stageEndMeters = []
        stages = []
        totalMeters = 0
        remainingMeters = 0
        traveledMeters = 0
        offRoute = false
        currentCue = "Follow the route"
        currentCueMeters = nil
        currentManeuver = nil
        followingManeuver = nil
        followingManeuverMeters = nil
        currentSurfaceLabel = nil
        upcomingSurfaceAlert = nil
        lastSurfaceAlertKey = nil
        deliveredCuePhases = [:]
        announcedStageApproaches = []
        announcedStageArrivals = []
        climbMeters = 0
        lastAltitudeMeters = nil
        startedAt = nil
        lastSpeedMPS = 0
    }

    private static func fallbackStages(for ends: [Double]) -> [NavigationStage] {
        ends.enumerated().map { index, end in
            let isFinal = index == ends.count - 1
            return NavigationStage(
                id: "stage-\(index + 1)",
                title: isFinal ? "Destination" : "Point \(index + 2)",
                detail: nil,
                kind: isFinal ? .destination : .waypoint,
                endMeters: end
            )
        }
    }

    /// One maneuver contract for live, saved, and on-device routes.
    /// Junction mode trusts explicit graph decision points when present; older
    /// payloads fall back to decisive geometry. Rally is always derived from
    /// the final displayed line so its 6→1 scale cannot differ by engine.
    private static func resolveManeuvers(
        coordinates: [RouteCoordinate],
        incoming: [RouteManeuver],
        cueMode: NavigationCueMode
    ) -> [RouteManeuver] {
        switch cueMode {
        case .rally:
            return NavCueBuilder.build(coordinates: coordinates, cueMode: .rally)
        case .junctions:
            let enriched = RouteManeuver.enrichForVoiceCues(incoming)
            let graphDecisions = enriched.filter { $0.isJunctionCue }
            guard !graphDecisions.isEmpty else {
                return NavCueBuilder.build(coordinates: coordinates, cueMode: .junctions)
            }
            let arrival = enriched.last(where: {
                ($0.type ?? $0.kind ?? "").lowercased() == "arrive"
            }) ?? RouteManeuver(
                instruction: "Arrive at destination",
                type: "arrive",
                kind: "arrive",
                distanceMeters: 0,
                alongMeters: GeoMath.lineMeters(coordinates)
            )
            return graphDecisions + [arrival]
        }
    }

    private static func rebasedStages(
        _ existing: [NavigationStage],
        onto ends: [Double]
    ) -> [NavigationStage] {
        guard !ends.isEmpty else { return [] }
        return ends.enumerated().map { index, end in
            guard existing.indices.contains(index) else {
                return fallbackStages(for: ends)[index]
            }
            let stage = existing[index]
            return NavigationStage(
                id: stage.id,
                title: stage.title,
                detail: stage.detail,
                kind: stage.kind,
                endMeters: end
            )
        }
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
