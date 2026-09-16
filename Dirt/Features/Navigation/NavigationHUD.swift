import CoreLocation
import SwiftUI

/// Navigation chrome — Figma `Navigation — Turn Left - Junction` (node 50:5240):
/// - Top: `DIRT.` · turn cue (+ distance) · dark speed
/// - Bottom: inset chrome card (top radius 16 / bottom 29) with compact REPORT / END

// MARK: - Cue card (top center)

struct NavCueCard: View {
    @Environment(AppEnvironment.self) private var app

    private var nav: NavigationSession { app.navigation }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: arrowSymbol)
                .font(.system(size: cueIconSize, weight: .bold))
                .foregroundStyle(nav.offRoute ? DirtTheme.danger : DirtTheme.orange)
                .frame(width: 48, height: 48)
                .scaleEffect(cueBand == .now && !nav.offRoute ? 1.08 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(mainLabel)
                        .font(.dirtUI(cueTitleSize, weight: .heavy))
                        .foregroundStyle(DirtTheme.ink)
                        .tracking(0.3)
                        .lineLimit(2)
                        .minimumScaleFactor(0.55)
                        .multilineTextAlignment(.leading)
                    if let number = rallyNumber {
                        Text("\(number)")
                            .font(.dirtMono(min(cueTitleSize, 16), weight: .bold))
                            .foregroundStyle(DirtTheme.orange)
                    }
                }
                // Distance matches the spoken cue — always show when we have meters.
                if let meters = nav.currentCueMeters {
                    Text(Self.formatDistance(meters))
                        .font(.dirtUI(cueDistanceSize, weight: .heavy))
                        .foregroundStyle(DirtTheme.ink)
                        .tracking(0.4)
                        .monospacedDigit()
                } else if nav.offRoute {
                    Text("Back on the line")
                        .font(.dirtUI(14, weight: .heavy))
                        .foregroundStyle(DirtTheme.ink.opacity(0.7))
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
        .padding(.horizontal, 14)
        .padding(.vertical, cueBand == .now ? 12 : 10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var cueBand: NavigationCueBand {
        if nav.offRoute { return .now }
        return NavigationCueBand.band(forMeters: nav.currentCueMeters)
    }

    private var cueIconSize: CGFloat {
        switch cueBand {
        case .now: 42
        case .near: 38
        case .mid: 33
        case .far, .none: 31
        }
    }

    private var cueDistanceSize: CGFloat {
        switch cueBand {
        case .now: 20
        case .near: 18
        default: 17
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
        if nav.offRoute { return "Off route" }
        if let meters = nav.currentCueMeters {
            return "\(mainLabel), \(Self.formatDistance(meters))"
        }
        return mainLabel
    }

    /// Rally severity number shown in orange next to the side (curve cues only).
    private var rallyNumber: Int? {
        guard let maneuver = nav.currentManeuver else { return nil }
        guard maneuver.isRallyCurve || app.cueSettings.mode == .rally else { return nil }
        if let side = maneuver.side, mainLabel.lowercased().contains(side.lowercased()),
           let number = maneuver.number,
           mainLabel.contains("\(number)") {
            return nil
        }
        return maneuver.number
    }

    private var mainLabel: String {
        if nav.offRoute { return "Off route" }
        if let maneuver = nav.currentManeuver {
            return maneuver.displayLabel(cueMode: app.cueSettings.mode)
        }
        return nav.currentCue
    }

    /// Sized for the full-width card left by the relocated speed block; long idle copy
    /// still steps down. Urgency band bumps size when the junction is imminent.
    private var cueTitleSize: CGFloat {
        let count = mainLabel.count
        var base: CGFloat = 21
        if count > 22 { base = 16 }
        else if count > 14 { base = 18 }
        switch cueBand {
        case .now: return min(base + 3, 24)
        case .near: return min(base + 2, 23)
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
                .font(.dirtUI(compact ? 28 : 44, weight: .heavy))
                .foregroundStyle(DirtTheme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 8 : 6)
        .frame(
            width: compact ? 96 : 106,
            height: compact ? 68 : 80,
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
    static let landscapeBrandColumn: CGFloat = 128
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
}

struct NavStatBox: View {
    let label: String
    let value: String
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.dirtMono(compact ? 8 : 10, weight: .semibold))
                .foregroundStyle(DirtTheme.orange)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                // Values only — labels stay put. +50% over prior 16 / 20.
                .font(.dirtMono(compact ? 24 : 30, weight: .semibold))
                .foregroundStyle(DirtTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 6 : 8)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
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
    @State private var statsExpanded = false

    private var nav: NavigationSession { app.navigation }

    /// Figma NavCueCard: ~8pt side inset on a 393pt frame; top 16 / bottom 29 radii.
    private let panelShape = UnevenRoundedRectangle(
        topLeadingRadius: 16,
        bottomLeadingRadius: 29,
        bottomTrailingRadius: 29,
        topTrailingRadius: 16,
        style: .continuous
    )

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

                if statsExpanded {
                    HStack(spacing: 10) {
                        tripStatBoxes(compact: false)
                    }
                }

                // Report (primary) left · End (secondary + confirm) right — side by side.
                HStack(spacing: 10) {
                    NavReportButton(fillWidth: true) { app.incidents.open() }
                    NavEndButton(fillWidth: true) { showEndConfirm = true }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Rectangle().fill(Color.white.opacity(0.22))
                }
            }
            .clipShape(panelShape)
            .overlay(panelShape.stroke(DirtTheme.chromeBorder, lineWidth: 1))
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

    /// Surface under the tires (left) + remaining trip (right) on one tappable line.
    private var statusRow: some View {
        let summary = String(
            format: "Destination %.1f km · +%@ m",
            nav.remainingMeters / 1000,
            NavTripFormat.climbMeters(nav.climbMeters)
        )
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { statsExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: surfaceIsAlert ? "exclamationmark.triangle.fill" : DirtSurfaceIcon.symbol(for: surfaceLine))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DirtTheme.orange)
                Text(surfaceLine)
                    .font(.dirtUI(surfaceIsAlert ? 15 : 14, weight: .bold))
                    .foregroundStyle(DirtTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 8)

                Text(summary)
                    .font(.dirtMono(11, weight: .semibold))
                    .foregroundStyle(DirtTheme.ink.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(DirtTheme.orange)
                    .rotationEffect(.degrees(statsExpanded ? 180 : 0))
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: DirtHit.min)
            .background(surfaceIsAlert ? DirtTheme.orange.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Surface \(surfaceLine). Trip \(summary)")
        .accessibilityHint(statsExpanded ? "Hides trip detail" : "Shows trip detail")
    }

    /// Upcoming change wins; otherwise the surface under the tires.
    private var surfaceLine: String {
        if let alert = nav.upcomingSurfaceAlert, !alert.isEmpty { return alert }
        return nav.currentSurfaceLabel ?? "On route"
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(panelShape)
        .overlay(panelShape.stroke(DirtTheme.chromeBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saving maps for the trail, \(Int(app.offline.progress * 100)) percent")
    }
}

// MARK: - Landscape left rail (Figma 65:6)

/// Narrow chrome column under the DIRT brand — surface, Report / End, trip stats.
struct NavLandscapeRail: View {
    @Environment(AppEnvironment.self) private var app
    @State private var showEndConfirm = false
    @State private var statsExpanded = false

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

            // Narrow rail can’t fit side-by-side labels — stack with 48pt hits.
            VStack(spacing: 10) {
                NavReportButton(fillWidth: true) { app.incidents.open() }
                NavEndButton(title: "END", fillWidth: true) { showEndConfirm = true }
            }

            let summary = String(format: "Destination %.1f km · +%@ m", nav.remainingMeters / 1000, NavTripFormat.climbMeters(nav.climbMeters))
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { statsExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(statsExpanded ? "Hide" : summary)
                        .font(.dirtUI(11, weight: .semibold))
                        .foregroundStyle(DirtTheme.ink.opacity(0.9))
                        .lineLimit(2)
                        .minimumScaleFactor(0.65)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DirtTheme.orange)
                        .rotationEffect(.degrees(statsExpanded ? 180 : 0))
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            if statsExpanded {
                VStack(spacing: 8) {
                    NavStatBox(
                        label: "destination km",
                        value: String(format: "%.1f", nav.remainingMeters / 1000),
                        compact: true
                    )
                    NavStatBox(
                        label: "climb:m",
                        value: NavTripFormat.climbMeters(nav.climbMeters),
                        compact: true
                    )
                }
            }
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
