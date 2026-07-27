import CoreLocation
import Foundation
import Observation
import SwiftUI

// MARK: - Report model (web parity: ROUTE-INCIDENT-RECOVERY.md)

/// One-tap report categories. Colors mirror the web report sheet exactly.
enum RouteIncidentCategory: String, Codable, CaseIterable, Identifiable {
    case accessClosed = "access_closed"
    case gateSeasonal = "gate_seasonal"
    case flooded
    case blocked
    case unsafe
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessClosed: "Access closed / no trespassing"
        case .gateSeasonal: "Gate or seasonal closure"
        case .flooded: "Flooded or impassable crossing"
        case .blocked: "Blocked route"
        case .unsafe: "Unsafe condition"
        case .other: "Other"
        }
    }

    var color: Color {
        switch self {
        case .accessClosed: Color(dirtHex: 0xD22730)
        case .gateSeasonal: Color(dirtHex: 0xDC6803)
        case .flooded: Color(dirtHex: 0x0A66C2)
        case .blocked: Color(dirtHex: 0xF97316)
        case .unsafe: Color(dirtHex: 0xEAB308)
        case .other: Color(dirtHex: 0x6B7078)
        }
    }
}

/// Rider report, kept separate from the authoritative network. Local-only —
/// shared persistence is blocked until a durable store exists (web parity).
struct RouteIncidentReport: Codable, Identifiable {
    let id: UUID
    let category: RouteIncidentCategory
    let latitude: Double
    let longitude: Double
    let edgeId: String?
    let createdAt: Date
    let expiresAt: Date
    var status: String

    static let defaultTTL: TimeInterval = 14 * 24 * 3600 // matches web freshness default

    init(category: RouteIncidentCategory, latitude: Double, longitude: Double, edgeId: String?) {
        id = UUID()
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.edgeId = edgeId
        createdAt = Date()
        expiresAt = createdAt.addingTimeInterval(Self.defaultTTL)
        status = "unverified"
    }
}

/// Device-local report store (`dirt_reports_v1`, same key family as web).
/// Reports never mutate the NSTDB network — avoidance is per-request only.
enum RouteIncidentStore {
    private static let key = "dirt_reports_v1"

    static func load() -> [RouteIncidentReport] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let reports = try? JSONDecoder().decode([RouteIncidentReport].self, from: data)
        else { return [] }
        return reports.filter { $0.expiresAt > Date() }
    }

    static func append(_ report: RouteIncidentReport) {
        var reports = load()
        reports.append(report)
        if let data = try? JSONEncoder().encode(reports) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Recovery flow

/// Drives the report → recovery → confirm flow during navigation.
///
/// Hard rules (web parity):
/// - Never silently reroute; every replacement requires explicit confirmation.
/// - Never draw a free-space connector — recovery routes come from `/api/route`
///   or from the existing verified route geometry (backtrack).
@Observable
@MainActor
final class IncidentRecoveryModel {
    enum Step: Equatable {
        case hidden
        /// "Report what's ahead" category grid.
        case categories
        /// "Report logged" — pick a recovery action.
        case actions
        /// "Replace route?" preview awaiting confirmation.
        case confirm
        /// Recovery request in flight.
        case working(String)
    }

    enum RecoveryAction: String, CaseIterable, Identifiable {
        case around
        case backtrack
        case returnToNetwork
        case endStage

        var id: String { rawValue }

        var title: String {
            switch self {
            case .around: "Find a way around"
            case .backtrack: "Backtrack"
            case .returnToNetwork: "Return to nearest verified network"
            case .endStage: "End stage"
            }
        }

        var subtitle: String {
            switch self {
            case .around: "Verified detour avoiding the report"
            case .backtrack: "Return along your route to the last junction"
            case .returnToNetwork: "Route back to the verified network"
            case .endStage: "Stop navigation for this stage"
            }
        }
    }

    /// Confirmed replacement waiting for the rider's approval.
    struct Preview {
        enum Kind {
            case response(RouteResponse)
            case backtrack(coordinates: [RouteCoordinate], meters: Double)
        }

        let kind: Kind
        let headline: String
        let detail: String
    }

    private(set) var step: Step = .hidden
    private(set) var activeReport: RouteIncidentReport?
    private(set) var preview: Preview?
    var failureMessage: String?

    static let noAlternateMessage =
        "No verified alternate route found. Backtrack to the last verified junction or end this stage."

    private unowned let planner: RoutePlannerModel
    private let locationService: LocationService
    private let routing: RoutingClient

    init(planner: RoutePlannerModel, locationService: LocationService, routing: RoutingClient) {
        self.planner = planner
        self.locationService = locationService
        self.routing = routing
    }

    var isPresented: Bool { step != .hidden }

    func open() {
        failureMessage = nil
        step = .categories
    }

    func dismiss() {
        step = .hidden
        activeReport = nil
        preview = nil
        failureMessage = nil
    }

    /// Category tapped → log locally, then offer recovery actions.
    /// Uses the GPS fix; never invents a location (web rule).
    func submitReport(_ category: RouteIncidentCategory) {
        guard let position = locationService.currentCoordinate else {
            failureMessage = "No GPS fix — cannot place the report."
            return
        }
        let report = RouteIncidentReport(
            category: category,
            latitude: position.latitude,
            longitude: position.longitude,
            edgeId: planner.edgeIdNear(position)
        )
        RouteIncidentStore.append(report)
        activeReport = report
        failureMessage = nil
        step = .actions
    }

    func choose(_ action: RecoveryAction) {
        failureMessage = nil
        switch action {
        case .endStage:
            planner.endNavigation()
            dismiss()
        case .backtrack:
            if let backtrack = planner.backtrackGeometry() {
                preview = Preview(
                    kind: .backtrack(coordinates: backtrack.coordinates, meters: backtrack.meters),
                    headline: "Backtrack along your route",
                    detail: String(
                        format: "Follows your verified route %.1f km back to the last junction. No new ground.",
                        backtrack.meters / 1000
                    )
                )
                step = .confirm
            } else {
                failureMessage = "Not far enough along the route to backtrack."
            }
        case .around:
            step = .working("Finding a verified way around…")
            Task { await findWayAround() }
        case .returnToNetwork:
            step = .working("Routing back to the verified network…")
            Task { await routeBackToNetwork() }
        }
    }

    func applyPreview() {
        guard let preview else { return }
        switch preview.kind {
        case let .response(response):
            planner.applyRecoveryRoute(response)
        case let .backtrack(coordinates, _):
            planner.applyBacktrack(coordinates: coordinates)
        }
        dismiss()
    }

    func keepCurrentRoute() {
        preview = nil
        step = .actions
    }

    // MARK: - Recovery routing

    private func findWayAround() async {
        guard let rider = locationService.currentCoordinate,
              let destination = planner.preservedDestination else {
            fail(Self.noAlternateMessage)
            return
        }
        var avoid: [String] = []
        if let edge = activeReport?.edgeId { avoid.append(edge) }
        let request = RouteRequest(
            profile: planner.profile,
            locations: [
                RouteLocation(latitude: rider.latitude, longitude: rider.longitude, label: "A"),
                RouteLocation(latitude: destination.latitude, longitude: destination.longitude, label: "B")
            ],
            allowUnknown: planner.allowUnknown,
            avoidEdgeIds: avoid
        )
        do {
            let response = try await routing.route(request)
            let km = (response.distanceMeters ?? 0) / 1000
            let avoidedNote = avoid.isEmpty
                ? "The reported location could not be matched to a network edge — review the line before applying."
                : "The reported section is excluded server-side."
            preview = Preview(
                kind: .response(response),
                headline: "Verified detour found",
                detail: String(format: "%.1f km · %d%% dirt to your destination. %@", km, response.dirtPercent, avoidedNote)
            )
            step = .confirm
        } catch {
            fail(Self.noAlternateMessage)
        }
    }

    private func routeBackToNetwork() async {
        guard let rider = locationService.currentCoordinate,
              let target = planner.nearestRoutePoint(to: rider) else {
            fail("No verified escape route found from here.")
            return
        }
        let request = RouteRequest(
            profile: planner.profile,
            locations: [
                RouteLocation(latitude: rider.latitude, longitude: rider.longitude, label: "A"),
                RouteLocation(latitude: target.latitude, longitude: target.longitude, label: "B")
            ],
            allowUnknown: planner.allowUnknown
        )
        do {
            let response = try await routing.route(request)
            let km = (response.distanceMeters ?? 0) / 1000
            preview = Preview(
                kind: .response(response),
                headline: "Route back to the verified network",
                detail: String(format: "%.1f km on verified network back to your route.", km)
            )
            step = .confirm
        } catch {
            fail("No verified escape route found from here.")
        }
    }

    private func fail(_ message: String) {
        failureMessage = message
        step = .actions
    }
}
