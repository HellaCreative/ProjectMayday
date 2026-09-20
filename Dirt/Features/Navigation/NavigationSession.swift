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
    /// Off-route state remains visible while recalculation runs.
    private(set) var missTurnActive = false
    /// Sticky recovery failure, with an explicit retry.
    private(set) var missTurnReason: String?
    /// True while automatic recovery or a retry is in flight.
    private(set) var missTurnRerouting = false
    /// Report owns recovery while its sheet is open.
    var recoverySuspended = false
    private var lastAcceptedFixTime: Date?
    private var offRouteSince: Date?
    private var lastAutomaticRerouteFix: CLLocation?
    /// GPS breadcrumbs for End Ride distance (contribute still uses edge ids).
    private(set) var riddenTrack: [RouteCoordinate] = []
    /// Fuel Range switch as Navigation sees it this ride.
    private(set) var fuelNotificationsOn = false
    /// Remaining usable metres when notifications are on; nil when off.
    var remainingFuelMeters: Double? {
        guard fuelNotificationsOn, usableFuelMeters > 0 else { return nil }
        return max(0, usableFuelMeters - fuelBurnedMeters)
    }
    /// HUD toast: route to the nearest packed station. Not shown on the cue.
    private(set) var fuelStationPromptVisible = false
    /// Sticky fuel-via failure on the same chrome as the toast.
    private(set) var fuelPromptReason: String?
    /// Did you fuel up? — only after arriving at a station they routed to.
    private(set) var fuelFillPromptVisible = false
    private var usableFuelMeters: Double = 0
    private var fuelBurnedMeters: Double = 0
    private var lastFuelFix: CLLocation?
    private var acknowledgedFuelRung = 0
    private var pendingFuelRung = 0
    private var fuelViaActive = false
    private var fuelViaStation: RouteCoordinate?
    /// Last on-route TBT, frozen when they leave the line so a puddle skip can be named.
    private var lastUpcomingManeuver: RouteManeuver?
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
    private var lastSurfaceAlertKey: String?
    private var deliveredCuePhases: [String: Set<NavigationCuePhase>] = [:]
    private var announcedStageApproaches: Set<String> = []
    private var announcedStageArrivals: Set<String> = []
    /// The last accepted segment/location keep progress tied to the rider's
    /// local part of the line. A global nearest-segment match can otherwise
    /// jump across a loop, self-crossing, or nearby parallel road.
    @ObservationIgnored private var lastMatchedSegmentIndex: Int?
    @ObservationIgnored private var lastProgressLocation: CLLocation?

    struct SurfaceRun: Sendable {
        let startMeters: Double
        let endMeters: Double
        let surfaceKey: String
        let isAdventure: Bool

        var label: String { RouteSegment.riderFacingSurfaceLabel(surfaceKey) }
    }

    /// Wired by the planner: recalculates from the rider's position to the
    /// preserved destination with the same profile + access policy.
    /// Queue validity follows route progress and replacement.
    var onCueValidityChanged: ((Set<String>) -> Void)?
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

    @discardableResult
    func beginPrefetch() -> Bool {
        guard phase == .idle else { return false }
        phase = .prefetching
        return true
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
            riddenTrack = []
            startedAt = Date()
            beginFuelTracking(enabled: FuelRangePrefs.notificationsEnabled, resetBurn: true)
        }
        // A replacement line has its own segment indices and starts progress at
        // zero, so continuity must be re-anchored by its first location fix.
        lastMatchedSegmentIndex = nil
        lastProgressLocation = nil
        lastAcceptedFixTime = nil
        offRouteSince = nil
        lastAutomaticRerouteFix = nil
        offRoute = false
        offRouteStrikes = 0
        lastUpcomingManeuver = nil
        clearMissTurn(recovered: false)
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
        onCueValidityChanged?([])
    }

    /// Cue mode changed mid-ride. Stable maneuver identities retain their
    /// delivered phases so a Junction cue does not replay when Rally is enabled
    /// and Rally-only cues do not replay after switching away and back.
    func rebuildCuesForCurrentMode() {
        guard phase == .active, coordinates.count > 1 else { return }
        maneuvers = Self.resolveManeuvers(
            coordinates: coordinates,
            incoming: sourceManeuvers,
            cueMode: cueMode
        )
            .sorted { ($0.alongMeters ?? 0) < ($1.alongMeters ?? 0) }
        guard !missTurnActive else { return }
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
        guard phase == .active, coordinates.count > 1,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 35,
              lastAcceptedFixTime.map({ location.timestamp > $0 }) ?? true
        else { return }
        lastAcceptedFixTime = location.timestamp
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
        recordRiddenFix(location)
        accumulateFuelBurn(from: location)
        noteArrivalAtFuelViaIfNeeded(location)

        guard let proj = projectionRespectingContinuity(for: location) else { return }

        // Sustained accurate fixes are required before rerouting.
        let wasOffRoute = offRoute || offRouteStrikes > 0
        if proj.offMeters > 50 {
            handleOffRoute(location)
            return
        }

        offRouteSince = nil
        lastAutomaticRerouteFix = nil
        lastMatchedSegmentIndex = proj.segmentIndex
        lastProgressLocation = location
        traveledMeters = proj.alongMeters
        remainingMeters = max(0, totalMeters - traveledMeters)
        RideEdgeSequence.appendRidden(
            into: &riddenEdgeIds,
            spans: edgeSpans,
            traveledMeters: traveledMeters
        )
        offRouteStrikes = 0
        offRoute = false
        if wasOffRoute {
            clearMissTurn(recovered: true)
            onRouteRecovered?()
        }

        updateSurfaceContext()

        let visibleManeuvers = maneuvers.filter { $0.matches(cueMode: cueMode) }
        // Keep the current decision through its actual junction. Dropping it
        // 15 m early can show/speak the next straight cue while still turning.
        let upcoming = visibleManeuvers.filter { ($0.alongMeters ?? 0) >= traveledMeters - 5 }
        var validCueIDs = Set(upcoming.map(\.announceIdentity))
        if let stage = currentStage { validCueIDs.insert("waypoint-\(stage.id)") }
        onCueValidityChanged?(validCueIDs)
        let nextManeuver = upcoming.first
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
        lastUpcomingManeuver = nextManeuver.flatMap { man in
            let kind = (man.type ?? man.kind ?? "").lowercased()
            return kind == "arrive" ? nil : man
        }

        if missTurnActive { return }

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
        onCueValidityChanged?([])
        recoverySuspended = false
        phase = .idle
        coordinates = []
        maneuvers = []
        sourceManeuvers = []
        surfaceRuns = []
        edgeSpans = []
        riddenEdgeIds = []
        riddenTrack = []
        cumulative = []
        stageEndMeters = []
        stages = []
        totalMeters = 0
        remainingMeters = 0
        traveledMeters = 0
        offRoute = false
        lastUpcomingManeuver = nil
        clearMissTurn(recovered: false)
        resetFuelTracking()
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
        lastMatchedSegmentIndex = nil
        lastProgressLocation = nil
        climbMeters = 0
        lastAltitudeMeters = nil
        startedAt = nil
        lastSpeedMPS = 0
    }

    /// GPS path length including a bypass, used at End Ride. Contribute still
    /// sends edge ids from the planned (and later Continue) line.
    var riddenDistanceMeters: Double {
        max(traveledMeters, GeoMath.lineMeters(riddenTrack))
    }

    /// Vertex ahead of last on-route progress — rejoin target for a fuel via.
    func coordinateAheadOnRoute(by meters: Double = 40) -> RouteCoordinate? {
        guard coordinates.count > 1, cumulative.count == coordinates.count else { return nil }
        let along = min(totalMeters, traveledMeters + max(0, meters))
        if let index = cumulative.firstIndex(where: { $0 >= along }) {
            return coordinates[index]
        }
        return coordinates.last
    }

    func continueMissTurnReroute() {
        guard phase == .active, missTurnActive, !missTurnRerouting else { return }
        guard !recoverySuspended, let onRerouteNeeded else { return }
        missTurnRerouting = true
        missTurnReason = nil
        currentCue = "Rerouting…"
        onRerouteNeeded()
    }

    func setMissTurnFailure(_ message: String) {
        missTurnRerouting = false
        missTurnReason = message
        currentCue = "Couldn’t reroute"
    }

    func clearMissTurn(recovered: Bool) {
        missTurnActive = false
        missTurnReason = nil
        missTurnRerouting = false
        if recovered {
            evaluateFuelStationPrompt()
        }
    }

    func beginFuelTracking(enabled: Bool, resetBurn: Bool) {
        if !enabled {
            resetFuelTracking()
            return
        }
        fuelNotificationsOn = true
        usableFuelMeters = FuelRangePrefs.snapshot.usableMeters
        if resetBurn {
            fuelBurnedMeters = 0
            acknowledgedFuelRung = 0
            pendingFuelRung = 0
            lastFuelFix = nil
        }
        fuelStationPromptVisible = false
        fuelPromptReason = nil
        fuelFillPromptVisible = false
        fuelViaActive = false
        fuelViaStation = nil
    }

    func setFuelNotificationsEnabled(_ enabled: Bool) {
        guard phase == .active else {
            if !enabled { resetFuelTracking() }
            return
        }
        if enabled == fuelNotificationsOn { return }
        if enabled {
            beginFuelTracking(enabled: true, resetBurn: true)
        } else {
            resetFuelTracking()
        }
    }

    func snoozeFuelStationPrompt() {
        fuelStationPromptVisible = false
        fuelPromptReason = nil
        acknowledgedFuelRung = max(acknowledgedFuelRung, pendingFuelRung)
    }

    func noteFuelViaSearchStarted() {
        fuelStationPromptVisible = false
        fuelPromptReason = nil
    }

    func beginFuelVia(to station: RouteCoordinate) {
        fuelViaActive = true
        fuelViaStation = station
        fuelStationPromptVisible = false
        fuelPromptReason = nil
        fuelFillPromptVisible = false
        acknowledgedFuelRung = max(acknowledgedFuelRung, pendingFuelRung)
    }

    func setFuelPromptFailure(_ message: String) {
        fuelViaActive = false
        fuelViaStation = nil
        fuelFillPromptVisible = false
        fuelStationPromptVisible = true
        fuelPromptReason = message
    }

    func confirmFuelFill() {
        fuelBurnedMeters = 0
        acknowledgedFuelRung = 0
        pendingFuelRung = 0
        lastFuelFix = nil
        fuelFillPromptVisible = false
        fuelViaActive = false
        fuelViaStation = nil
        fuelPromptReason = nil
    }

    func dismissFuelFillPrompt() {
        fuelFillPromptVisible = false
        fuelViaActive = false
        fuelViaStation = nil
    }

    private func handleOffRoute(_ location: CLLocation) {
        offRouteStrikes += 1
        if offRouteSince == nil { offRouteSince = location.timestamp }
        // All departures use hysteresis, including a named missed turn. A single
        // noisy fix must not replace the accepted line.
        guard offRouteStrikes >= 3,
              location.timestamp.timeIntervalSince(offRouteSince!) >= 2 else { return }
        presentMissTurn(named: namedMissManeuverIfBehind())
        guard !recoverySuspended, !missTurnRerouting else { return }
        if let previous = lastAutomaticRerouteFix {
            guard location.timestamp.timeIntervalSince(previous.timestamp) >= 30,
                  location.distance(from: previous) >= 30 else { return }
        }
        lastAutomaticRerouteFix = location
        continueMissTurnReroute()
    }

    private func namedMissManeuverIfBehind() -> RouteManeuver? {
        guard let man = lastUpcomingManeuver, let along = man.alongMeters else { return nil }
        let kind = (man.type ?? man.kind ?? "").lowercased()
        if kind == "arrive" { return nil }
        // At or past the turn (now-window). Instant named skip; unnamed keeps 3-fix.
        guard along <= traveledMeters + 80 else { return nil }
        return man
    }

    private func presentMissTurn(named: RouteManeuver?) {
        offRoute = true
        onCueValidityChanged?([])
        currentCueMeters = nil
        followingManeuver = nil
        followingManeuverMeters = nil
        upcomingSurfaceAlert = nil
        fuelStationPromptVisible = false
        if missTurnActive { return }
        missTurnActive = true
        missTurnReason = nil
        missTurnRerouting = false
        if let named {
            currentManeuver = named
            currentCue = Self.missedTurnCue(for: named, cueMode: cueMode)
        } else {
            currentManeuver = nil
            currentCue = "You're off the line."
        }
    }

    static func missedTurnCue(for maneuver: RouteManeuver, cueMode: NavigationCueMode) -> String {
        let side = maneuver.side?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !side.isEmpty {
            if maneuver.isRallyCurve, let number = maneuver.number {
                return "You missed a turn — you were supposed to take \(side) \(number) back there."
            }
            return "You missed a turn — you were supposed to turn \(side) back there."
        }
        let label = maneuver.displayLabel(cueMode: cueMode).lowercased()
        return "You missed a turn — you were supposed to \(label) back there."
    }

    private func recordRiddenFix(_ location: CLLocation) {
        let point = RouteCoordinate(
            longitude: location.coordinate.longitude,
            latitude: location.coordinate.latitude
        )
        if let last = riddenTrack.last, GeoMath.meters(last, point) < 12 {
            return
        }
        if riddenTrack.count >= 20_000 {
            riddenTrack.removeFirst(riddenTrack.count - 19_999)
        }
        riddenTrack.append(point)
    }

    private func accumulateFuelBurn(from location: CLLocation) {
        guard fuelNotificationsOn else { return }
        if let last = lastFuelFix {
            let delta = location.distance(from: last)
            if delta > 1, delta < 250 {
                fuelBurnedMeters += delta
            }
        }
        lastFuelFix = location
        evaluateFuelStationPrompt()
    }

    private func evaluateFuelStationPrompt() {
        guard fuelNotificationsOn, usableFuelMeters > 0 else { return }
        guard !fuelViaActive, !fuelFillPromptVisible else { return }
        if missTurnActive {
            fuelStationPromptVisible = false
            return
        }
        if fuelStationPromptVisible { return }
        let burnedFraction = min(1, fuelBurnedMeters / usableFuelMeters)
        let rung = Int((burnedFraction * 10).rounded(.down))
        guard rung >= 1, rung > acknowledgedFuelRung else { return }
        pendingFuelRung = rung
        fuelStationPromptVisible = true
        fuelPromptReason = nil
    }

    private func noteArrivalAtFuelViaIfNeeded(_ location: CLLocation) {
        guard fuelViaActive, let station = fuelViaStation else { return }
        let here = CLLocation(latitude: station.latitude, longitude: station.longitude)
        guard location.distance(from: here) <= 80 else { return }
        fuelViaActive = false
        fuelFillPromptVisible = true
        fuelStationPromptVisible = false
    }

    private func resetFuelTracking() {
        fuelNotificationsOn = false
        usableFuelMeters = 0
        fuelBurnedMeters = 0
        lastFuelFix = nil
        acknowledgedFuelRung = 0
        pendingFuelRung = 0
        fuelStationPromptVisible = false
        fuelPromptReason = nil
        fuelFillPromptVisible = false
        fuelViaActive = false
        fuelViaStation = nil
    }

    /// Match only the locally reachable portion of an established route.
    ///
    /// The first fix still uses the global route so navigation can recover when
    /// it begins after the rider has moved. Later fixes search a distance window
    /// around the last accepted segment. The window grows with elapsed time,
    /// speed, and straight-line movement, which permits background gaps and
    /// ordinary stage transitions without letting a nearby future/previous arm
    /// of a loop steal progress.
    private func projectionRespectingContinuity(for location: CLLocation) -> PolylineProjection? {
        guard let anchorSegment = lastMatchedSegmentIndex,
              let priorLocation = lastProgressLocation,
              coordinates.count > 1,
              cumulative.count == coordinates.count
        else {
            return GeoMath.nearestProjection(
                to: location,
                in: coordinates,
                cumulative: cumulative
            )
        }

        let elapsed = max(0, location.timestamp.timeIntervalSince(priorLocation.timestamp))
        let directMovement = location.distance(from: priorLocation)
        let measuredSpeed = location.speed >= 0 ? location.speed : 0
        // Speed is capped to a short recent interval. An old moving fix must
        // not widen the window forever while the rider is stationary off-route;
        // real long-gap progress is represented by direct displacement below.
        let expectedMovement = measuredSpeed * min(elapsed, 30)

        // Normal location updates need only a small local window. Longer gaps
        // and real movement expand it automatically; no fixed segment count is
        // assumed because route geometry density varies greatly.
        let forwardAllowance = max(
            100,
            expectedMovement * 1.75 + 40,
            directMovement * 1.25 + 40
        )
        let backwardAllowance = max(
            50,
            expectedMovement * 0.5 + 25,
            directMovement * 0.5 + 25
        )
        let lowerAlong = max(0, traveledMeters - backwardAllowance)
        let upperAlong = min(totalMeters, traveledMeters + forwardAllowance)
        let finalSegment = coordinates.count - 2

        var lowerSegment = min(max(0, anchorSegment), finalSegment)
        while lowerSegment > 0, cumulative[lowerSegment] > lowerAlong {
            lowerSegment -= 1
        }

        var upperSegment = min(max(0, anchorSegment), finalSegment)
        while upperSegment < finalSegment, cumulative[upperSegment + 1] < upperAlong {
            upperSegment += 1
        }

        let localCoordinates = Array(coordinates[lowerSegment...(upperSegment + 1)])
        let baseAlong = cumulative[lowerSegment]
        let localCumulative = Array(cumulative[lowerSegment...(upperSegment + 1)]).map {
            $0 - baseAlong
        }
        guard let local = GeoMath.nearestProjection(
            to: location,
            in: localCoordinates,
            cumulative: localCumulative
        ) else { return nil }

        return PolylineProjection(
            offMeters: local.offMeters,
            alongMeters: baseAlong + local.alongMeters,
            segmentIndex: lowerSegment + local.segmentIndex
        )
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
    /// Junction/Essential trusts explicit graph decision points when present;
    /// older payloads fall back to decisive geometry. Rally/Everything adds
    /// curves derived from the final displayed line while preserving every
    /// essential decision, so its 6→1 scale cannot differ by engine.
    private static func resolveManeuvers(
        coordinates: [RouteCoordinate],
        incoming: [RouteManeuver],
        cueMode: NavigationCueMode
    ) -> [RouteManeuver] {
        let enriched = RouteManeuver.enrichForVoiceCues(incoming)
        let graphDecisions = enriched.filter { $0.isJunctionCue }
        // No graph decisions means no known junctions. A bend alone cannot
        // establish a road choice; geometry only contributes Rally notes.
        let essential = graphDecisions
        let arrival = enriched.last(where: {
            ($0.type ?? $0.kind ?? "").lowercased() == "arrive"
        }) ?? RouteManeuver(
            instruction: "Arrive at destination",
            type: "arrive",
            kind: "arrive",
            distanceMeters: 0,
            alongMeters: GeoMath.lineMeters(coordinates)
        )

        switch cueMode {
        case .junctions:
            return essential + [arrival]
        case .rally:
            let curves = NavCueBuilder.build(coordinates: coordinates, cueMode: .rally)
                .filter(\.isRallyCurve)
            return NavCueBuilder.mergeRallyEverything(
                curves: curves,
                junctions: essential
            ) + [arrival]
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
