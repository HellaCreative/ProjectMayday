import CoreLocation
import SwiftUI

/// Navigation chrome — Figma `Navigation — Turn Left - Junction` (node 50:5240):
/// - Top: `DIRT.` · turn cue (+ distance) · dark speed
/// - Bottom: full-bleed portrait ride panel

// MARK: - Cue card (top center)

struct NavCueCard: View {
    @Environment(AppEnvironment.self) private var app
    /// When set, the card is clipped to the landscape top band so it lines up with speed and brand.
    var bandHeight: CGFloat? = nil

    private var nav: NavigationSession { app.navigation }

    var body: some View {
        VStack(alignment: .leading, spacing: nav.missTurnActive ? 10 : 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: arrowSymbol)
                    .font(.system(size: cueIconSize, weight: .bold))
                    .foregroundStyle(nav.offRoute ? DirtTheme.danger : DirtTheme.orange)
                    .frame(width: 44, height: 44)
                    .scaleEffect(cueBand == .now && !nav.offRoute ? 1.08 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mainLabel)
                        .font(.dirtUI(cueTitleSize, weight: .heavy))
                        .foregroundStyle(DirtTheme.ink)
                        .tracking(0.3)
                        .lineLimit(3)
                        .minimumScaleFactor(0.55)
                        .multilineTextAlignment(.leading)
                    // Distance matches the spoken cue — always show when we have meters.
                    if let meters = nav.currentCueMeters {
                        Text(Self.formatDistance(meters))
                            .font(.dirtUI(cueDistanceSize, weight: .heavy))
                            .foregroundStyle(DirtTheme.ink)
                            .tracking(0.4)
                            .monospacedDigit()
                    } else if let reason = nav.missTurnReason, !reason.isEmpty {
                        Text(reason)
                            .font(.dirtUI(14, weight: .heavy))
                            .foregroundStyle(DirtTheme.ink.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !nav.offRoute,
                       app.cueSettings.mode == .rally,
                       let following = nav.followingManeuver {
                        Text("Next \(following.displayLabel(cueMode: .rally)) · \(Self.formatDistance(nav.followingManeuverMeters ?? 0))")
                            .font(.dirtUI(11, weight: .semibold))
                            .foregroundStyle(DirtTheme.ink.opacity(0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)

            if nav.missTurnActive {
                missTurnActions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, bandHeight == nil ? (cueBand == .now ? 12 : 10) : 8)
        .frame(maxWidth: .infinity, minHeight: bandHeight ?? 72, alignment: .leading)
        .frame(height: nav.missTurnActive ? nil : bandHeight)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color.white.opacity(0.22))
            }
        }
        .overlay(cueUrgencyWash)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cueBorderColor, lineWidth: cueBorderWidth)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
        .accessibilityElement(children: nav.missTurnActive ? .contain : .combine)
    }

    private var missTurnActions: some View {
        VStack(spacing: 8) {
            Button {
                app.planner.continueAfterMissTurn()
            } label: {
                Text("Continue & reroute")
                    .font(.dirtUI(15, weight: .heavy))
                    .foregroundStyle(DirtTheme.onOrange)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(DirtTheme.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .disabled(nav.missTurnRerouting)
            .opacity(nav.missTurnRerouting ? 0.55 : 1)
            .accessibilityLabel("Continue and reroute")
            .accessibilityHint("Rebuilds the line ahead with your last ride style")

            Button {
                app.planner.turnAroundAfterMissTurn()
            } label: {
                Text("Turn around")
                    .font(.dirtUI(15, weight: .heavy))
                    .foregroundStyle(DirtTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DirtTheme.chromeBorder, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Turn around")
            .accessibilityHint("Follows the verified line back to the last junction")
        }
        .buttonStyle(.plain)
    }

    private var cueBand: NavigationCueBand {
        if nav.offRoute { return .now }
        return NavigationCueBand.band(forMeters: nav.currentCueMeters)
    }

    private var cueIconSize: CGFloat {
        switch cueBand {
        case .now: 36
        case .near: 34
        case .mid: 32
        case .far, .none: 30
        }
    }

    private var cueDistanceSize: CGFloat {
        switch cueBand {
        case .now: 16
        case .near: 15
        default: 14
        }
    }

    private var cueBorderColor: Color {
        if nav.offRoute { return DirtTheme.danger }
        switch cueBand {
        case .now: return DirtTheme.orange
        case .near: return DirtTheme.orange.opacity(0.85)
        default: return DirtTheme.chromeBorder
        }
    }

    private var cueBorderWidth: CGFloat {
        switch cueBand {
        case .now: 2.5
        case .near: 1.75
        default: 1
        }
    }

    @ViewBuilder private var cueUrgencyWash: some View {
        if nav.offRoute {
            DirtTheme.danger.opacity(0.14)
        } else if cueBand == .now {
            DirtTheme.orange.opacity(0.12)
        } else if cueBand == .near {
            DirtTheme.orange.opacity(0.06)
        }
    }

    private var accessibilitySummary: String {
        if let reason = nav.missTurnReason, !reason.isEmpty {
            return "\(mainLabel). \(reason)"
        }
        if let meters = nav.currentCueMeters {
            return "\(mainLabel), \(Self.formatDistance(meters))"
        }
        return mainLabel
    }

    private var mainLabel: String {
        nav.currentCue
    }

    /// Callout size, not a headline. Longer turn copy steps down so two lines fit.
    private var cueTitleSize: CGFloat {
        let count = mainLabel.count
        var base: CGFloat = 19
        if count > 24 { base = 16 }
        else if count > 16 { base = 17 }
        switch cueBand {
        case .now: return min(base + 1, 20)
        case .near: return min(base + 1, 19)
        default: return base
        }
    }

    private var arrowSymbol: String {
        if nav.offRoute { return "exclamationmark.triangle.fill" }
        guard let maneuver = nav.currentManeuver else { return "arrow.up" }
        return maneuver.arrowSystemName(cueMode: app.cueSettings.mode)
    }

    static func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters))m"
    }
}

// MARK: - Speed readout

/// Speed is the rider's third priority, so it owns a glass block of its own rather than a
/// slot in the crowded top band. Monospaced digits stop the number twitching at speed.
struct NavSpeedReadout: View {
    @Environment(AppEnvironment.self) private var app

    /// Compact keeps the old top-band footprint for the landscape packing.
    var compact: Bool = false

    private var speedKMH: Int {
        let mps = app.location.lastLocation?.speed ?? -1
        return mps > 0 ? Int((mps * 3.6).rounded()) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 1) {
            Text("KM/H")
                .font(.dirtUI(compact ? 10 : 11, weight: .heavy))
                .foregroundStyle(DirtTheme.orange)
                .tracking(0.8)
            Text("\(speedKMH)")
                .font(.dirtUI(compact ? 32 : 44, weight: .heavy))
                .foregroundStyle(DirtTheme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 8 : 6)
        .frame(
            width: compact ? 96 : 106,
            height: compact ? NavChromeMetrics.landscapeTopBandHeight : 80,
            alignment: .leading
        )
        .dirtSheetSurface(radius: compact ? 12 : 16)
        .dirtDenseChrome()
        .accessibilityLabel("Current speed \(speedKMH) kilometers per hour")
    }
}

// MARK: - Shared nav trip metrics / actions

enum NavChromeMetrics {
    /// Figma landscape: brand chip + left rail share this column width.
    /// Wide enough for full “REPORT” + icon without truncating.
    static let landscapeBrandColumn: CGFloat = 143
    /// Cue, speed, and wordmark share one top-band height so the cluster edge is square.
    static let landscapeTopBandHeight: CGFloat = 78
    /// Outer pad on the clustered (non-island) edge — hug the phone.
    static let landscapeClusterEdgePad: CGFloat = 6
    /// Cue gets room without eating the whole top band.
    static let landscapeCueMaxWidth: CGFloat = 320
}

enum NavTripFormat {
    static func travelTime(phase: NavigationSession.Phase, etaSeconds: Double?) -> String {
        guard phase == .active else { return "0:00" }
        let seconds = Int(etaSeconds ?? 0)
        if seconds <= 0 { return "0:00" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return String(format: "%d:%02d", hours, minutes)
        }
        return String(format: "%d min", max(minutes, 1))
    }

    /// Cumulative uphill this ride (not absolute altitude).
    static func climbMeters(_ meters: Double) -> String {
        meters < 1 ? "0" : "\(Int(meters.rounded()))"
    }

    static func elapsed(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int(seconds) / 60)
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    static func tripSummaryLine(
        remainingKm: Double,
        phase: NavigationSession.Phase,
        etaSeconds: Double?,
        climbMeters: Double
    ) -> String {
        let km = String(format: "%.1f km", remainingKm)
        let time = travelTime(phase: phase, etaSeconds: etaSeconds)
        let climb = "+\(Self.climbMeters(climbMeters)) m"
        return "\(km) · \(time) · \(climb)"
    }

    /// Quiet remaining-fuel figure on the same trip row as destination km · climb.
    static func destinationClimbFuelLine(
        remainingKm: Double,
        climbMeters: Double,
        fuelRemainingKm: Double?
    ) -> String {
        let base = String(
            format: "Destination %.1f km · +%@ m",
            remainingKm,
            Self.climbMeters(climbMeters)
        )
        guard let fuelRemainingKm else { return base }
        return String(format: "%@ · %.0f km fuel", base, max(0, fuelRemainingKm))
    }
}

struct NavReportButton: View {
    var title: String = "REPORT"
    var fillWidth: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.dirtUI(12, weight: .heavy))
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(DirtTheme.onOrange)
            .padding(.horizontal, 12)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .frame(minHeight: 48)
            .background(DirtTheme.orange)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Report a route incident")
    }
}

struct NavEndButton: View {
    var title: String = "END RIDE"
    var fillWidth: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.dirtUI(12, weight: .heavy))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(DirtTheme.danger)
            .padding(.horizontal, 12)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .frame(minHeight: 48)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DirtTheme.danger.opacity(0.85), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .accessibilityLabel("End navigation")
        .accessibilityHint("Asks for confirmation before ending the ride")
    }
}

// MARK: - Portrait bottom panel

struct NavBottomPanel: View {
    @Environment(AppEnvironment.self) private var app
    @State private var showEndConfirm = false

    private var nav: NavigationSession { app.navigation }

    private var surfaceIsAlert: Bool {
        if let alert = nav.upcomingSurfaceAlert, !alert.isEmpty { return true }
        return false
    }

    var body: some View {
        Group {
            if nav.phase == .prefetching {
                prefetchCard
            } else {
                activeCard
            }
        }
        .confirmationDialog(
            "End this ride?",
            isPresented: $showEndConfirm,
            titleVisibility: .visible
        ) {
            Button("End navigation", role: .destructive) {
                app.planner.endNavigation()
            }
            Button("Keep riding", role: .cancel) {}
        } message: {
            Text("Stops turn-by-turn and returns to the planner.")
        }
    }

    /// Two rows instead of four: surface and trip share one line (each with its own
    /// alignment), actions sit below. Everything cut here goes back to the map.
    private var activeCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                waypointProgress
                statusRow
                fuelChrome

                // Report (primary) left · End (secondary + confirm) right — side by side.
                HStack(spacing: 10) {
                    NavReportButton(fillWidth: true) { app.incidents.open() }
                    NavEndButton(fillWidth: true) { showEndConfirm = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .safeAreaPadding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Rectangle().fill(Color.white.opacity(0.22))
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    /// The rider's next meaningful anchor is primary trip information—not a
    /// hidden detail. Keep it visible beside its live countdown at all times.
    private var waypointProgress: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: nav.currentStage?.kind == .fuelStop ? "fuelpump.fill" : "flag.checkered")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DirtTheme.orange)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(nav.currentStage?.title ?? "Destination")
                    .font(.dirtUI(18, weight: .heavy))
                    .foregroundStyle(DirtTheme.ink)
                    .lineLimit(1)
                if let detail = nav.currentStage?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.dirtUI(12, weight: .semibold))
                        .foregroundStyle(DirtTheme.ink.opacity(0.72))
                        .lineLimit(1)
                }
                Text("\(NavTripFormat.travelTime(phase: nav.phase, etaSeconds: nav.etaSeconds)) to waypoint · Ride \(NavTripFormat.elapsed(nav.elapsedSeconds))")
                    .font(.dirtUI(11, weight: .semibold))
                    .foregroundStyle(DirtTheme.ink.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 6)
            Text(Self.waypointDistance(nav.remainingInCurrentStageMeters))
                .font(.dirtMono(22, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next \(nav.currentStage?.title ?? "destination"), \(Self.waypointDistance(nav.remainingInCurrentStageMeters)), \(NavTripFormat.travelTime(phase: nav.phase, etaSeconds: nav.etaSeconds))")
    }

    private static func waypointDistance(_ meters: Double) -> String {
        if meters >= 10_000 { return "\(Int((meters / 1000).rounded())) km" }
        if meters >= 1_000 { return String(format: "%.1f km", meters / 1000) }
        return "\(Int(max(0, meters).rounded())) m"
    }

    /// Surface under the tires.
    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: surfaceIsAlert ? "exclamationmark.triangle.fill" : DirtSurfaceIcon.symbol(for: surfaceLine))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DirtTheme.orange)
            Text(surfaceLine)
                .font(.dirtUI(surfaceIsAlert ? 15 : 14, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: DirtHit.min, alignment: .leading)
        .background(surfaceIsAlert ? DirtTheme.orange.opacity(0.12) : Color.clear)
        .accessibilityLabel("Surface \(surfaceLine)")
    }

    private var tripSummaryLine: String {
        NavTripFormat.destinationClimbFuelLine(
            remainingKm: nav.remainingMeters / 1000,
            climbMeters: nav.climbMeters,
            fuelRemainingKm: nav.remainingFuelMeters.map { $0 / 1000 }
        )
    }

    /// Upcoming change wins; otherwise the surface under the tires.
    private var surfaceLine: String {
        if let alert = nav.upcomingSurfaceAlert, !alert.isEmpty { return alert }
        return nav.currentSurfaceLabel ?? "On route"
    }

    @ViewBuilder
    private var fuelChrome: some View {
        if nav.fuelFillPromptVisible {
            NavFuelPromptCard(
                title: "Did you fuel up?",
                primaryTitle: "Yes",
                secondaryTitle: "No",
                reason: nil,
                onPrimary: { nav.confirmFuelFill() },
                onSecondary: { nav.dismissFuelFillPrompt() }
            )
        } else if nav.fuelStationPromptVisible || (nav.fuelPromptReason != nil && nav.fuelNotificationsOn) {
            NavFuelPromptCard(
                title: "Do you want to route to the nearest fuel station?",
                primaryTitle: "Route",
                secondaryTitle: "Close",
                reason: nav.fuelPromptReason,
                onPrimary: { app.planner.routeToNearestPackedFuelStation() },
                onSecondary: { nav.snoozeFuelStationPrompt() }
            )
        }
    }

    @ViewBuilder
    private func tripStatBoxes(compact: Bool) -> some View {
        NavStatBox(
            label: "destination km",
            value: String(format: "%.1f", nav.remainingMeters / 1000),
            compact: compact
        )
        NavStatBox(
            label: "climb:m",
            value: NavTripFormat.climbMeters(nav.climbMeters),
            compact: compact
        )
    }

    // MARK: Prefetch (legacy phase — copy matches OfflineMapPrepOverlay)

    private var prefetchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OFFLINE MAPS")
                .font(.dirtUI(10, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(DirtTheme.orange)
            Text("Saving maps for the trail")
                .font(.dirtUI(15, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
            ProgressView(value: app.offline.progress)
                .tint(DirtTheme.orange)
            HStack {
                Text("\(Int(app.offline.progress * 100))%")
                    .font(.dirtMono(12, weight: .bold))
                    .foregroundStyle(DirtTheme.ink)
                Spacer()
                Button("Cancel") { app.planner.skipPrefetch() }
                    .font(.dirtUI(12, weight: .bold))
                    .foregroundStyle(DirtTheme.orange)
            }
        }
        .padding(16)
        .safeAreaPadding(.bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Rectangle().fill(DirtTheme.sheetMaterial)
                Rectangle().fill(Color.white.opacity(0.22))
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saving maps for the trail, \(Int(app.offline.progress * 100)) percent")
    }
}

// MARK: - Landscape left rail (Figma 65:6)

/// Narrow chrome column under the DIRT brand — surface, Report / End, trip stats.
struct NavLandscapeRail: View {
    @Environment(AppEnvironment.self) private var app
    @State private var showEndConfirm = false

    private var nav: NavigationSession { app.navigation }

    private var landscapeSurfaceLine: String {
        if let alert = nav.upcomingSurfaceAlert, !alert.isEmpty { return alert }
        return nav.currentSurfaceLabel ?? "On route"
    }

    private var surfaceIsAlert: Bool {
        if let alert = nav.upcomingSurfaceAlert, !alert.isEmpty { return true }
        return false
    }

    var body: some View {
        Group {
            if nav.phase == .prefetching {
                prefetchRail
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    activeRail
                }
            }
        }
        .frame(width: NavChromeMetrics.landscapeBrandColumn)
        .confirmationDialog(
            "End this ride?",
            isPresented: $showEndConfirm,
            titleVisibility: .visible
        ) {
            Button("End navigation", role: .destructive) {
                app.planner.endNavigation()
            }
            Button("Keep riding", role: .cancel) {}
        } message: {
            Text("Stops turn-by-turn and returns to the planner.")
        }
    }

    private var activeRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: nav.currentStage?.kind == .fuelStop ? "fuelpump.fill" : "flag.checkered")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DirtTheme.orange)
                    Text(nav.currentStage?.title ?? "Destination")
                        .font(.dirtUI(13, weight: .heavy))
                        .foregroundStyle(DirtTheme.ink)
                        .lineLimit(1)
                }
                if let detail = nav.currentStage?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.dirtUI(9, weight: .semibold))
                        .foregroundStyle(DirtTheme.ink.opacity(0.72))
                        .lineLimit(1)
                }
                Text(Self.waypointDistance(nav.remainingInCurrentStageMeters))
                    .font(.dirtMono(19, weight: .bold))
                    .foregroundStyle(DirtTheme.ink)
                    .monospacedDigit()
                Text("\(NavTripFormat.travelTime(phase: nav.phase, etaSeconds: nav.etaSeconds)) · Ride \(NavTripFormat.elapsed(nav.elapsedSeconds))")
                    .font(.dirtUI(9, weight: .semibold))
                    .foregroundStyle(DirtTheme.ink.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack(spacing: 6) {
                Image(systemName: surfaceIsAlert ? "exclamationmark.triangle.fill" : DirtSurfaceIcon.symbol(for: landscapeSurfaceLine))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DirtTheme.orange)
                Text(landscapeSurfaceLine)
                    .font(.dirtUI(12, weight: .bold))
                    .foregroundStyle(DirtTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surfaceIsAlert ? DirtTheme.orange.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            landscapeFuelChrome

            // Narrow rail can’t fit side-by-side labels — stack with 48pt hits.
            VStack(spacing: 10) {
                NavReportButton(fillWidth: true) { app.incidents.open() }
                NavEndButton(title: "END", fillWidth: true) { showEndConfirm = true }
            }

            Text(String(format: "Destination %.1f km · +%@ m", nav.remainingMeters / 1000, NavTripFormat.climbMeters(nav.climbMeters)))
                .font(.dirtUI(11, weight: .semibold))
                .foregroundStyle(DirtTheme.ink.opacity(0.9))
                .lineLimit(2)
                .minimumScaleFactor(0.65)
                .padding(.top, 6)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var landscapeFuelChrome: some View {
        if nav.fuelFillPromptVisible {
            NavFuelPromptCard(
                title: "Did you fuel up?",
                primaryTitle: "Yes",
                secondaryTitle: "No",
                reason: nil,
                compact: true,
                onPrimary: { nav.confirmFuelFill() },
                onSecondary: { nav.dismissFuelFillPrompt() }
            )
        } else if nav.fuelStationPromptVisible || (nav.fuelPromptReason != nil && nav.fuelNotificationsOn) {
            NavFuelPromptCard(
                title: "Do you want to route to the nearest fuel station?",
                primaryTitle: "Route",
                secondaryTitle: "Close",
                reason: nav.fuelPromptReason,
                compact: true,
                onPrimary: { app.planner.routeToNearestPackedFuelStation() },
                onSecondary: { nav.snoozeFuelStationPrompt() }
            )
        }
    }

    private static func waypointDistance(_ meters: Double) -> String {
        if meters >= 10_000 { return "\(Int((meters / 1000).rounded())) km" }
        if meters >= 1_000 { return String(format: "%.1f km", meters / 1000) }
        return "\(Int(max(0, meters).rounded())) m"
    }

    private var prefetchRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OFFLINE MAPS")
                .font(.dirtUI(9, weight: .heavy))
                .tracking(1)
                .foregroundStyle(DirtTheme.orange)
            Text("Saving maps…")
                .font(.dirtUI(11, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
            ProgressView(value: app.offline.progress)
                .tint(DirtTheme.orange)
            Text("\(Int(app.offline.progress * 100))%")
                .font(.dirtMono(11, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
            Button("Cancel") { app.planner.skipPrefetch() }
                .font(.dirtUI(11, weight: .bold))
                .foregroundStyle(DirtTheme.orange)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
    }
}

/// Orange "Recenter" chip shown when the rider pans away during navigation.
struct FollowChip: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("Recenter")
                    .font(.dirtUI(13, weight: .heavy))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(DirtTheme.orange)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .accessibilityLabel("Recenter on your location")
    }
}

/// Fill / station toast. Lives on the trip chrome, never on the cue card.
struct NavFuelPromptCard: View {
    let title: String
    let primaryTitle: String
    let secondaryTitle: String
    var reason: String?
    var compact: Bool = false
    var onPrimary: () -> Void
    var onSecondary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(title)
                .font(.dirtUI(compact ? 13 : 15, weight: .heavy))
                .foregroundStyle(DirtTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(.dirtUI(compact ? 11 : 13, weight: .semibold))
                    .foregroundStyle(DirtTheme.ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(action: onSecondary) {
                    Text(secondaryTitle)
                        .font(.dirtUI(compact ? 13 : 15, weight: .heavy))
                        .foregroundStyle(DirtTheme.ink)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(DirtTheme.chromeBorder, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                }
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .font(.dirtUI(compact ? 13 : 15, weight: .heavy))
                        .foregroundStyle(DirtTheme.onOrange)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(DirtTheme.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirtTheme.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
