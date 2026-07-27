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
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(nav.offRoute ? DirtTheme.pavedMix : DirtTheme.orange)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(mainLabel)
                        .font(.dirtUI(18, weight: .heavy))
                        .foregroundStyle(DirtTheme.panelText)
                        .tracking(0.4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let number = rallyNumber {
                        Text("\(number)")
                            .font(.dirtMono(18, weight: .bold))
                            .foregroundStyle(DirtTheme.orange)
                    }
                }
                // Distance matches the spoken cue — always show when we have meters.
                if let meters = nav.currentCueMeters {
                    Text(Self.formatDistance(meters))
                        .font(.dirtUI(14, weight: .heavy))
                        .foregroundStyle(DirtTheme.panelText)
                        .tracking(0.4)
                } else if nav.offRoute {
                    Text("Recenter")
                        .font(.dirtUI(14, weight: .heavy))
                        .foregroundStyle(DirtTheme.panelText.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(DirtTheme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
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

    private var arrowSymbol: String {
        if nav.offRoute { return "exclamationmark.triangle.fill" }
        guard let maneuver = nav.currentManeuver else { return "arrow.up" }
        return maneuver.arrowSystemName(cueMode: app.cueSettings.mode)
    }

    static func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters))m"
    }
}

// MARK: - Speed pill (top-right, chrome)

struct NavSpeedPill: View {
    @Environment(AppEnvironment.self) private var app

    private var speedKMH: Int {
        let mps = app.location.lastLocation?.speed ?? -1
        return mps > 0 ? Int((mps * 3.6).rounded()) : 0
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(speedKMH)")
                .font(.dirtUI(24, weight: .heavy))
                .foregroundStyle(DirtTheme.panelText)
                .tracking(0.5)
                .monospacedDigit()
            Text("km")
                .font(.dirtUI(16, weight: .heavy))
                .foregroundStyle(DirtTheme.panelText)
                .tracking(0.5)
        }
        // Wide enough for three digits ("999 km") so the cue card gaps stay stable.
        .frame(minWidth: 88, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 68)
        .background(DirtTheme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
        .accessibilityLabel("Current speed \(speedKMH) kilometers per hour")
    }
}

// MARK: - Bottom panel (stats + compact actions)

struct NavBottomPanel: View {
    @Environment(AppEnvironment.self) private var app

    private var nav: NavigationSession { app.navigation }

    /// Figma NavCueCard: ~8pt side inset on a 393pt frame; top 16 / bottom 29 radii.
    private let panelShape = UnevenRoundedRectangle(
        topLeadingRadius: 16,
        bottomLeadingRadius: 29,
        bottomTrailingRadius: 29,
        topTrailingRadius: 16,
        style: .continuous
    )

    var body: some View {
        Group {
            if nav.phase == .prefetching {
                prefetchCard
            } else {
                activeCard
            }
        }
    }

    private var activeCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                HStack(spacing: 15) {
                    statBox(label: "km to go", value: String(format: "%.1f", nav.remainingMeters / 1000))
                    statBox(label: "travel time", value: travelTime)
                    statBox(label: "elevation:m", value: elevation)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DirtTheme.chrome)
            .clipShape(panelShape)
            .overlay(panelShape.stroke(DirtTheme.chromeBorder, lineWidth: 1))
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.left")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DirtTheme.orange)
                .rotationEffect(.degrees(90))
            Text(nav.currentSurfaceLabel ?? "On route")
                .font(.dirtUI(15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            compactActions
        }
    }

    private var compactActions: some View {
        HStack(spacing: 10) {
            Button {
                app.incidents.open()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("REPORT")
                        .font(.dirtUI(11, weight: .heavy))
                        .tracking(0.5)
                }
                .foregroundStyle(DirtTheme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DirtTheme.pavedMix)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Report a route incident")

            Button {
                app.planner.endNavigation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("END NAVIGATION")
                        .font(.dirtUI(11, weight: .heavy))
                        .tracking(0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DirtTheme.danger)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .accessibilityLabel("End navigation")
        }
    }

    private func statBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.dirtMono(6, weight: .semibold))
                .foregroundStyle(DirtTheme.orange)
            Text(value)
                .font(.dirtMono(14, weight: .semibold))
                .foregroundStyle(DirtTheme.panelValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
    }

    private var travelTime: String {
        guard nav.phase == .active else { return "0:00" }
        let seconds = Int(nav.etaSeconds ?? 0)
        if seconds <= 0 { return "0:00" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private var elevation: String {
        guard let altitude = app.location.lastLocation?.altitude else { return "—" }
        return String(format: "%.1f", altitude)
    }

    // MARK: Prefetch

    private var prefetchCard: some View {
        VStack(spacing: 10) {
            Text("PREPARING OFFLINE TILES")
                .font(.dirtUI(10, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.7))
            ProgressView(value: app.offline.progress)
                .tint(DirtTheme.orange)
            HStack {
                Text("\(Int(app.offline.progress * 100))%")
                    .font(.dirtMono(12, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Skip") { app.planner.skipPrefetch() }
                    .font(.dirtUI(11, weight: .bold))
                    .foregroundStyle(DirtTheme.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(DirtTheme.chrome)
        .clipShape(panelShape)
        .overlay(panelShape.stroke(DirtTheme.chromeBorder, lineWidth: 1))
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
