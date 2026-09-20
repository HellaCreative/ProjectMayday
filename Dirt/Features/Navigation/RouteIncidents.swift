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

/// Logs a report and routes around it from the current GPS fix.
///
/// Hard rules:
/// - Route Around is explicit permission to replace the active leg.
/// - Every replacement comes from the installed road graph, including retreat;
///   never reverse a polyline and assume that reverse travel is legal.
@Observable
@MainActor
final class IncidentRecoveryModel {
    enum Step: Equatable {
        case hidden
        /// "Report what's ahead" category grid.
        case categories
        /// "Report logged" — pick a recovery action.
        case actions
        /// Recovery request in flight.
        case working(String)
    }

    enum RecoveryAction: String, CaseIterable, Identifiable {
        case around
        case endStage

        var id: String { rawValue }

        var title: String {
            switch self {
            case .around: "Route Around"
            case .endStage: "End Ride"
            }
        }

        var subtitle: String {
            switch self {
            case .around: "From here to your next waypoint, avoiding this section"
            case .endStage: "Stop navigation and return to your plan"
            }
        }
    }

    private(set) var step: Step = .hidden
    private(set) var activeReport: RouteIncidentReport?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryGeneration = 0
    var failureMessage: String?

    static let noAlternateMessage =
        "No legal route around this section was found. Your existing route and waypoints are kept."

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
        planner.cancelNavigationReroute()
        planner.navigation.recoverySuspended = true
        failureMessage = nil
        step = .categories
    }

    func dismiss() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryGeneration += 1
        planner.navigation.recoverySuspended = false
        planner.navigation.clearMissTurn(recovered: false)
        step = .hidden
        activeReport = nil
        failureMessage = nil
    }

    /// Category tapped → log locally, optionally share to `rider_alerts`, then offer recovery.
    /// Uses the GPS fix; never invents a location.
    func submitReport(_ category: RouteIncidentCategory) {
        guard let fix = locationService.lastLocation,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 35,
              Date().timeIntervalSince(fix.timestamp) <= 15,
              let position = locationService.currentCoordinate else {
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
        guard planner.navigation.phase == .active else { dismiss(); return }
        failureMessage = nil
        switch action {
        case .endStage:
            planner.endNavigation()
            dismiss()
        case .around:
            recoveryTask?.cancel()
            recoveryGeneration += 1
            let generation = recoveryGeneration
            step = .working("Finding a route around…")
            recoveryTask = Task { await findWayAround(generation: generation) }
        }
    }

    private func findWayAround(generation: Int) async {
        guard let fix = locationService.lastLocation,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 35,
              Date().timeIntervalSince(fix.timestamp) <= 15,
              let rider = locationService.currentCoordinate,
              let destination = planner.preservedDestination else {
            fail("Waiting for your location. Your route is kept.")
            return
        }
        guard let edge = activeReport?.edgeId else {
            fail("Could not identify the blocked section from your location. Your route is kept; move to a safe place on the mapped route and try again.")
            return
        }
        guard let escape = planner.reportEscapeToward(edgeID: edge, near: rider) else {
            fail(Self.noAlternateMessage)
            return
        }
        let stageID = planner.navigation.currentStage?.id
        planner.recordNavigationBlock(edgeID: edge, escapeToward: escape)
        let policy = planner.activeStageRoutingPolicy(near: rider)
        do {
            let response = try await planner.routeWhileNavigating(
                from: rider, to: destination, avoidEdgeIds: [edge], blockedStartEscapeToward: escape,
                profile: policy.profile, allowUnknown: policy.allowUnknown,
                ridePreferences: policy.ridePreferences, avoidMotorways: policy.avoidMotorways
            )
            guard !Task.isCancelled, generation == recoveryGeneration else { return }
            guard planner.navigation.phase == .active,
                  planner.navigation.currentStage?.id == stageID else { dismiss(); return }
            // Never apply a response calculated from a position the rider has left.
            if let current = locationService.currentCoordinate,
               GeoMath.meters(rider, current) > 75 {
                fail("You moved while the detour was building. Tap Route Around to start from where you are now.")
                return
            }
            planner.applyRecoveryRoute(response, near: rider)
            planner.showRecoveryOverview(response.coordinates)
            dismiss()
        } catch {
            guard !Task.isCancelled, generation == recoveryGeneration, planner.navigation.phase == .active else { return }
            fail(Self.noAlternateMessage)
        }
    }

    #if DEBUG
    func waitForRecoveryForTesting() async {
        await recoveryTask?.value
    }
    #endif

    private func fail(_ message: String) {
        failureMessage = message
        step = .actions
    }
}
