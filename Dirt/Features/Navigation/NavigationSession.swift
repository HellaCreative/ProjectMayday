import CoreLocation
import Foundation
import Observation

/// Turn-by-turn session: follows the rider along the routed polyline, surfaces
/// the next cue and distance-to-end, and asks for a recalculation when the
/// rider leaves the line.
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
    private var cumulative: [Double] = []
    private(set) var totalMeters: Double = 0
    private(set) var remainingMeters: Double = 0
    private(set) var traveledMeters: Double = 0
    private(set) var currentCue = "Follow the orange line"
    private(set) var currentCueMeters: Double?
    private(set) var offRoute = false
    private var offRouteStrikes = 0
    private var lastRerouteRequest: Date?

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

    func activate(coordinates: [RouteCoordinate], maneuvers: [RouteManeuver]) {
        self.coordinates = coordinates
        self.maneuvers = maneuvers.sorted { ($0.alongMeters ?? 0) < ($1.alongMeters ?? 0) }
        cumulative = GeoMath.cumulativeMeters(coordinates)
        totalMeters = cumulative.last ?? 0
        remainingMeters = totalMeters
        traveledMeters = 0
        offRoute = false
        offRouteStrikes = 0
        currentCue = "Follow the orange line"
        currentCueMeters = nil
        phase = .active
    }

    /// Replaces the line mid-trip (recalculate). Offline tiles are kept.
    func replaceRoute(coordinates: [RouteCoordinate], maneuvers: [RouteManeuver]) {
        guard phase == .active else { return }
        activate(coordinates: coordinates, maneuvers: maneuvers)
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
            let now = Date()
            if lastRerouteRequest == nil || now.timeIntervalSince(lastRerouteRequest!) > 20 {
                lastRerouteRequest = now
                onRerouteNeeded?()
            }
            return
        }

        if let next = maneuvers.first(where: { ($0.alongMeters ?? 0) > traveledMeters + 15 }),
           let along = next.alongMeters {
            currentCue = next.instruction ?? next.type ?? "Continue"
            currentCueMeters = max(0, along - traveledMeters)
        } else {
            currentCue = remainingMeters < 120 ? "Arriving at destination" : "Continue on route"
            currentCueMeters = remainingMeters < 120 ? remainingMeters : nil
        }
    }

    func end() {
        phase = .idle
        coordinates = []
        maneuvers = []
        cumulative = []
        totalMeters = 0
        remainingMeters = 0
        traveledMeters = 0
        offRoute = false
        currentCue = "Follow the orange line"
        currentCueMeters = nil
    }
}
