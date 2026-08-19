import SwiftUI

/// Map chrome stack:
/// Route overview (nav) · 3D/2D · Cues · Compass · Status · Recenter.
/// Planning (compact): fit whole route (when polyline exists) · Recenter.
/// (Layers stay on the dock — not during navigation.)
/// Portrait = vertical trailing stack; landscape primary = horizontal bottom strip.
struct MapControlStack: View {
    @Environment(AppEnvironment.self) private var app
    var compact: Bool = false
    /// Figma landscape-primary: controls run across the bottom of the open map.
    var horizontal: Bool = false

    @State private var cuesOpen = false
    @State private var sharingOpen = false

    private let statuses = ["available", "breakdown", "injured", "stuck"]

    private var showsNavigationOverviewButton: Bool {
        // Same window as the old PiP: active ride (prefetch has no coords yet).
        app.navigation.phase == .active && app.navigation.coordinates.count > 1
    }

    private var navigationOverviewActive: Bool {
        app.mapState.navigationCameraMode == .overview
    }

    var body: some View {
        Group {
            if horizontal {
                HStack(spacing: compact ? 0 : 10) {
                    controlButtons
                }
            } else {
                VStack(alignment: .trailing, spacing: compact ? 0 : 10) {
                    controlButtons
                }
            }
        }
        .overlay(alignment: horizontal ? .top : .trailing) {
            if cuesOpen {
                cuesPopover
                    .offset(x: horizontal ? 0 : -58, y: horizontal ? -96 : -36)
            }
            if sharingOpen {
                sharingPopover
                    .offset(x: horizontal ? 0 : -58, y: horizontal ? -150 : 40)
            }
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        if !compact {
            if showsNavigationOverviewButton {
                navigationOverviewButton
            }
            viewModeButton
            cuesButton
            compassButton
            riderStatusButton
        }
        if app.planner.canFocusEntirePlannedRoute {
            if horizontal {
                fitPlannedRouteButton
                recenterButton
            } else {
                HStack(spacing: 10) {
                    fitPlannedRouteButton
                    recenterButton
                }
            }
        } else {
            recenterButton
        }
    }

    // MARK: - Buttons

    private var navigationOverviewButton: some View {
        Button {
            closePopovers()
            let enteringOverview = app.mapState.navigationCameraMode == .detail
            app.mapState.toggleNavigationCameraMode(
                routeCoordinates: app.navigation.coordinates,
                userCoordinate: app.location.currentCoordinate
            )
            app.planner.toast = enteringOverview ? "Route overview" : "Navigation detail"
        } label: {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(navigationOverviewActive ? DirtTheme.orange : DirtTheme.chrome)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DirtTheme.chromeBorder, lineWidth: 1)
                )
        }
        .accessibilityLabel(
            navigationOverviewActive
                ? "Switch to navigation detail view"
                : "Switch to full route overview"
        )
    }

    private var viewModeButton: some View {
        Button {
            closePopovers()
            app.mapState.toggleView3D()
            app.planner.toast = app.mapState.view3D ? "3D tilt on" : "Top-down 2D"
        } label: {
            Text(app.mapState.view3D ? "2D" : "3D")
                .font(.dirtMono(12, weight: .bold))
                .frame(width: 50, height: 50)
                .foregroundStyle(.white)
                .background(app.mapState.view3D ? DirtTheme.orange : DirtTheme.chrome)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DirtTheme.chromeBorder, lineWidth: 1)
                )
        }
        .accessibilityLabel(app.mapState.view3D ? "Switch to top-down 2D" : "Toggle 3D view")
    }

    private var cuesButton: some View {
        Button {
            sharingOpen = false
            cuesOpen.toggle()
        } label: {
            VStack(spacing: 1) {
                Text("CUES")
                    .font(.dirtMono(7, weight: .bold))
                    .tracking(0.6)
                    .opacity(0.62)
                Text(app.cueSettings.mode.shortLabel)
                    .font(.dirtMono(11, weight: .bold))
                Text(app.cueSettings.audioEnabled ? "AUDIO ON" : "AUDIO OFF")
                    .font(.dirtMono(6.5, weight: .bold))
                    .opacity(0.72)
            }
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
            .background(cuesOpen ? DirtTheme.orange : DirtTheme.chrome)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DirtTheme.chromeBorder, lineWidth: 1)
            )
        }
        .accessibilityLabel(
            "Navigation cues: \(app.cueSettings.mode.menuLabel.lowercased()), audio \(app.cueSettings.audioEnabled ? "on" : "off")"
        )
    }

    private var compassButton: some View {
        Button {
            closePopovers()
            app.mapState.resetNorth()
            app.planner.toast = "North up"
        } label: {
            Image(systemName: "safari")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-app.mapState.mapBearing))
                .frame(width: 50, height: 50)
                .background(DirtTheme.chrome)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            app.mapState.isNorthUp ? Color(dirtHex: 0x0354A6).opacity(0.55) : DirtTheme.chromeBorder,
                            lineWidth: 1
                        )
                )
        }
        .accessibilityLabel("Compass, reset north")
    }

    private var riderStatusButton: some View {
        Button {
            cuesOpen = false
            sharingOpen.toggle()
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(sharingOpen || app.groups.isSharing ? DirtTheme.orange : DirtTheme.chrome)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DirtTheme.chromeBorder, lineWidth: 1)
                )
        }
        .accessibilityLabel("Open group sharing controls")
    }

    private var fitPlannedRouteButton: some View {
        Button {
            closePopovers()
            app.planner.focusEntirePlannedRoute()
        } label: {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(DirtTheme.chrome)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DirtTheme.chromeBorder, lineWidth: 1)
                )
        }
        .accessibilityLabel("Show entire planned route")
    }

    private var recenterButton: some View {
        Button {
            closePopovers()
            if let coordinate = app.location.currentCoordinate {
                app.location.requestWhenInUse()
                app.mapState.recenterOnUser(at: coordinate)
            } else {
                app.location.requestWhenInUse()
                app.planner.toast = "Waiting for GPS fix"
            }
        } label: {
            Image(systemName: "dot.scope")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(recenterHighlighted ? DirtTheme.orange : DirtTheme.chrome)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DirtTheme.chromeBorder, lineWidth: 1)
                )
        }
        .accessibilityLabel("Follow my location")
    }

    /// Orange when follow is locked, or while the Recenter chip is up during
    /// navigation (either control re-locks follow).
    private var recenterHighlighted: Bool {
        app.mapState.followUser
            || (app.navigation.phase == .active && !app.mapState.followUser)
    }

    // MARK: - Popovers

    private var cuesPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(NavigationCueMode.allCases) { mode in
                    Button {
                        app.setCueMode(mode)
                        app.planner.toast = mode.statusToast
                    } label: {
                        Text(mode.menuLabel)
                            .font(.dirtUI(11, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(app.cueSettings.mode == mode ? DirtTheme.orange : DirtTheme.wash)
                            .foregroundStyle(app.cueSettings.mode == mode ? .white : DirtTheme.ink)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            Button {
                let next = !app.cueSettings.audioEnabled
                app.setCueAudioEnabled(next)
                app.planner.toast = "Cue audio \(next ? "on" : "off")"
            } label: {
                HStack {
                    Text("Audio")
                        .font(.dirtUI(12, weight: .bold))
                    Spacer()
                    Text(app.cueSettings.audioEnabled ? "ON" : "OFF")
                        .font(.dirtMono(11, weight: .bold))
                        .foregroundStyle(app.cueSettings.audioEnabled ? DirtTheme.orange : DirtTheme.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(DirtTheme.wash)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(DirtTheme.ink)
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(DirtTheme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var sharingPopover: some View {
        @Bindable var groups = app.groups
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group sharing")
                        .font(.dirtUI(14, weight: .bold))
                        .foregroundStyle(DirtTheme.ink)
                    Text(sharingContext)
                        .font(.dirtUI(10))
                        .foregroundStyle(DirtTheme.muted)
                }
                Spacer()
                Button {
                    sharingOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DirtTheme.muted)
                        .frame(width: 28, height: 28)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status")
                        .font(.dirtUI(10, weight: .bold))
                        .foregroundStyle(DirtTheme.ink)
                    Picker("Status", selection: Binding(
                        get: { groups.status },
                        set: { groups.setStatus($0) }
                    )) {
                        ForEach(statuses, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(DirtTheme.ink)
                    .disabled(!groups.isSharing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    if groups.isSharing {
                        groups.stopSharing()
                        app.planner.toast = "Sharing stopped"
                    } else if app.supabase.userID == nil {
                        app.planner.toast = "Sign in from Profile to share"
                    } else if groups.groups.isEmpty {
                        app.planner.toast = "Join or create a group first"
                    } else {
                        groups.startSharing()
                        app.planner.toast = "Sharing on"
                    }
                } label: {
                    Text(groups.isSharing ? "Stop" : "Start sharing")
                        .font(.dirtUI(11, weight: .heavy))
                        .textCase(.uppercase)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(groups.isSharing ? DirtTheme.chrome : DirtTheme.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(DirtTheme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var sharingContext: String {
        if app.supabase.userID == nil {
            return "Sign in from Profile to share your status."
        }
        if let selected = app.groups.selectedGroup {
            return "Sharing with \(selected.name)."
        }
        if app.groups.groups.isEmpty {
            return "Choose a group in Group first."
        }
        return "Live for every group you’re in."
    }

    private func closePopovers() {
        cuesOpen = false
        sharingOpen = false
    }
}
