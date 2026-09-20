import CoreLocation
import Foundation
import Observation
import SwiftUI

// MARK: - Report model

/// One-tap report categories.
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
        case .accessClosed: "Access closed"
        case .gateSeasonal: "Gate / seasonal"
        case .flooded: "Flooded crossing"
        case .blocked: "Blocked route"
        case .unsafe: "Unsafe"
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

/// Rider report. Always stored locally; cloud-synced to `route_incidents` when signed in.
struct RouteIncidentReport: Codable, Identifiable {
    let id: UUID
    let category: RouteIncidentCategory
    let latitude: Double
    let longitude: Double
    let edgeId: String?
    let createdAt: Date
    let expiresAt: Date
    var status: String

    static let defaultTTL: TimeInterval = 14 * 24 * 3600 // 14-day freshness default

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

/// Device-local report store (`dirt_reports_v1`).
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
/// Hard rules:
/// - Never silently reroute; every replacement requires explicit confirmation.
/// - Never draw a free-space connector — recovery routes come from on-device
///   packs (when Start Nav locked them), or from existing
///   verified route geometry (backtrack).
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
            case .around: "Way around"
            case .backtrack: "Backtrack"
            case .returnToNetwork: "Nearest verified network"
            case .endStage: "End stage"
            }
        }

        var subtitle: String {
            switch self {
            case .around: "Detour that avoids the report"
            case .backtrack: "Back along your route to the last junction"
            case .returnToNetwork: "Route to the nearest verified network"
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
    private let network: NetworkPathMonitor
    private weak var groups: GroupsViewModel?
    private weak var rideIntelligence: RideIntelligenceService?
    private var graphPackVersion: (() -> String?)?

    init(
        planner: RoutePlannerModel,
        locationService: LocationService,
        network: NetworkPathMonitor,
        groups: GroupsViewModel? = nil,
        rideIntelligence: RideIntelligenceService? = nil,
        graphPackVersion: (() -> String?)? = nil
    ) {
        self.planner = planner
        self.locationService = locationService
        self.network = network
        self.groups = groups
        self.rideIntelligence = rideIntelligence
        self.graphPackVersion = graphPackVersion
    }

    func attachGroups(_ groups: GroupsViewModel) {
        self.groups = groups
    }

    func attachRideIntelligence(_ service: RideIntelligenceService, packVersion: @escaping () -> String?) {
        rideIntelligence = service
        graphPackVersion = packVersion
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

    /// Category tapped → log locally, optionally share to `rider_alerts`, then offer recovery.
    /// Uses the GPS fix; never invents a location.
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

        let region = GraphPackStore.regionIds(
            containingAny: [
                CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
            ]
        ).first
        rideIntelligence?.enqueueAndFlush(
            report,
            regionCode: region,
            packVersion: graphPackVersion?()
        )

        if let groups {
            Task {
                await groups.publishRouteReportAlert(
                    category: category,
                    latitude: position.latitude,
                    longitude: position.longitude
                )
            }
        }
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
            step = .working(
                planner.hasOnDeviceRoutingPack && !network.isOnline
                    ? "Finding a detour on-device…"
                    : "Finding a verified way around…"
            )
            Task { await findWayAround() }
        case .returnToNetwork:
            step = .working(
                planner.hasOnDeviceRoutingPack && !network.isOnline
                    ? "Routing back on-device…"
                    : "Routing back to the verified network…"
            )
            Task { await routeBackToNetwork() }
        }
    }

    func applyPreview() {
        guard let preview else { return }
        switch preview.kind {
        case let .response(response):
            let near = activeReport.map {
                RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude)
            }
            planner.applyRecoveryRoute(response, near: near)
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
        let reportPoint = activeReport.map {
            RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude)
        }
        var avoid: [String] = []
        if let edge = activeReport?.edgeId { avoid.append(edge) }
        if !avoid.isEmpty {
            planner.apply(.markImpassable(edgeIDs: Set(avoid)), source: "reroute")
        }
        let policy = planner.activeStageRoutingPolicy(near: reportPoint ?? rider)
        do {
            let response = try await planner.routeWhileNavigating(
                from: rider,
                to: destination,
                avoidEdgeIds: avoid,
                profile: policy.profile,
                allowUnknown: policy.allowUnknown,
                ridePreferences: policy.ridePreferences,
                avoidMotorways: policy.avoidMotorways
            )
            let km = (response.distanceMeters ?? 0) / 1000
            let stageNote = planner.shouldPreserveStagesForRecovery
                ? " Active stage only — later stages kept."
                : ""
            let avoidedNote: String
            if avoid.isEmpty {
                avoidedNote = "The reported location could not be matched to a network edge — review the line before applying."
            } else {
                avoidedNote = "Detour computed on-device; reported section excluded."
            }
            preview = Preview(
                kind: .response(response),
                headline: "On-device detour found",
                detail: String(
                    format: "%.1f km · %d%% dirt to stage end.%@ %@",
                    km,
                    response.dirtPercent,
                    stageNote,
                    avoidedNote
                )
            )
            step = .confirm
        } catch {
            fail(error.localizedDescription.isEmpty ? Self.noAlternateMessage : error.localizedDescription)
        }
    }

    private func routeBackToNetwork() async {
        guard let rider = locationService.currentCoordinate else {
            fail("No verified escape route found from here.")
            return
        }
        var avoid: [String] = []
        if let edge = activeReport?.edgeId { avoid.append(edge) }
        if !avoid.isEmpty {
            planner.apply(.markImpassable(edgeIDs: Set(avoid)), source: "reroute")
        }
        let reportPoint = activeReport.map {
            RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude)
        }
        guard let target = planner.nearestRoutePoint(to: reportPoint ?? rider, avoidEdgeIds: avoid) else {
            fail("No verified escape route found from here.")
            return
        }
        let policy = planner.activeStageRoutingPolicy(near: reportPoint ?? rider)
        do {
            let response = try await planner.routeWhileNavigating(
                from: rider,
                to: target,
                avoidEdgeIds: avoid,
                profile: policy.profile,
                allowUnknown: policy.allowUnknown,
                ridePreferences: policy.ridePreferences,
                avoidMotorways: policy.avoidMotorways
            )
            let km = (response.distanceMeters ?? 0) / 1000
            let stageNote = planner.shouldPreserveStagesForRecovery
                ? " Later stages kept."
                : ""
            preview = Preview(
                kind: .response(response),
                headline: "On-device path back to your route",
                detail: String(format: "%.1f km back to your route.%@", km, stageNote)
            )
            step = .confirm
        } catch {
            fail(error.localizedDescription.isEmpty ? "No verified escape route found from here." : error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        failureMessage = message
        step = .actions
    }
}
