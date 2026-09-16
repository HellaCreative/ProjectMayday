import CoreLocation
import SwiftUI
import UIKit

/// Map chrome stack:
/// Route overview (nav) · 3D/2D · Cues · Compass · Status · Recenter.
/// Planning (compact): 3D/2D · Compass · Status · fit whole route (only when
/// a polyline is painted) · Recenter. Cues remain navigation-only.
/// (Layers stay on the dock — not during navigation.)
/// Portrait = vertical trailing stack; landscape primary = horizontal bottom strip.
struct MapControlStack: View {
    @Environment(AppEnvironment.self) private var app
    var compact: Bool = false
    /// Figma landscape-primary: controls run across the bottom of the open map.
    var horizontal: Bool = false
    /// Groups owns 3D while its sheet is open — hide the map chip.
    var hidesViewMode: Bool = false
    /// Sharing lives on the Groups Your-location card while that sheet is open.
    var hidesSharing: Bool = false

    @State private var cuesOpen = false
    @State private var sharingOpen = false
    @State private var locationRecovery: LocationRecovery?

    private enum LocationRecovery: Identifiable, Equatable {
        case denied
        case approximate

        var id: Int { self == .denied ? 0 : 1 }
        var title: String { self == .denied ? "Location is off" : "Precise Location is off" }
        var message: String {
            switch self {
            case .denied:
                "Open Settings and allow location access so DIRT can place you on the map and navigate from where you are."
            case .approximate:
                "DIRT can show an approximate position, but turn on Precise Location in Settings for dependable navigation and Group sharing."
            }
        }
    }

    private let statuses = GroupsViewModel.selectableStatuses

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
                HStack(spacing: 10) {
                    controlButtons
                }
            } else {
                VStack(alignment: .trailing, spacing: 10) {
                    controlButtons
                }
            }
        }
        .alert(item: $locationRecovery) { recovery in
            Alert(
                title: Text(recovery.title),
                message: Text(recovery.message),
                primaryButton: .default(Text("Open Settings")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                },
                secondaryButton: .cancel(Text("Not now"))
            )
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
        Group {
            zoomButton(increase: true)
            zoomButton(increase: false)
                .padding(horizontal ? .trailing : .bottom, 10)
        }
        if app.navigation.phase == .active {
            if showsNavigationOverviewButton {
                navigationOverviewButton
            }
            viewModeButton
            cuesButton
            compassButton
            riderStatusButton
            recenterButton

        } else {
            // Primary map: view mode and rider status remain available before
            // navigation. Cues are ride-only.
            if !hidesViewMode {
                viewModeButton
            }
            compassButton
            if !hidesSharing {
                riderStatusButton
            }
            if app.mapState.hasDisplayedRoute,
               app.planner.canFocusEntirePlannedRoute {
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
    }

    // MARK: - Buttons

    private func zoomButton(increase: Bool) -> some View {
        Button {
            closePopovers()
            DirtMotion.light()
            app.mapState.zoomBy(increase ? 1 : -1)
        } label: {
            Image(systemName: increase ? "plus" : "minus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DirtTheme.ink)
                .frame(width: 50, height: 50)
                .background(DirtTheme.sheetMaterial, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                        .stroke(DirtTheme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(DirtPressStyle())
        .accessibilityLabel(increase ? "Zoom in" : "Zoom out")
        .accessibilityIdentifier(increase ? "map-zoom-in" : "map-zoom-out")
    }

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
        .accessibilityIdentifier("map-view-mode")
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
        .accessibilityIdentifier("navigation-cues")
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
        .accessibilityIdentifier("rider-status")
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
        .accessibilityIdentifier("planned-route-overview")
    }

    private var recenterButton: some View {
        Button {
            closePopovers()
            if app.location.authorization == .denied || app.location.authorization == .restricted {
                locationRecovery = .denied
                return
            }
            if let coordinate = app.location.currentCoordinate {
                app.location.requestWhenInUse()
                app.mapState.recenterOnUser(at: coordinate)
                if app.location.accuracyAuthorization == .reducedAccuracy {
                    locationRecovery = .approximate
                }
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
        .accessibilityHint(
            app.location.authorization == .denied || app.location.authorization == .restricted
                ? "Opens location access help"
                : "Centers the map on your current location"
        )
    }

    /// Orange when follow is locked, or while the Recenter chip is up during
    /// navigation (either control re-locks follow).
    private var recenterHighlighted: Bool {
        app.mapState.followUser
            || (app.navigation.phase == .active && !app.mapState.followUser)
    }

    // MARK: - Popovers

    private var cuesPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CUES")
                .font(.dirtMono(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(DirtTheme.muted)

            HStack(spacing: 6) {
                ForEach(NavigationCueMode.allCases) { mode in
                    let selected = app.cueSettings.mode == mode
                    Button {
                        app.setCueMode(mode)
                        app.planner.toast = mode.statusToast
                    } label: {
                        VStack(spacing: 3) {
                            HStack(spacing: 4) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11, weight: .bold))
                                Text(mode.menuLabel)
                                    .font(.dirtUI(11, weight: .bold))
                            }
                            Text(mode.detailLabel)
                                .font(.dirtUI(9, weight: .semibold))
                                .opacity(selected ? 0.9 : 0.66)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .padding(.horizontal, 6)
                        .background(selected ? DirtTheme.orange : DirtTheme.wash)
                        .foregroundStyle(selected ? .white : DirtTheme.ink)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(mode.menuLabel), \(mode.detailLabel) cues")
                    .accessibilityIdentifier("cue-mode-\(mode.rawValue)")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            Text("AUDIO")
                .font(.dirtMono(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(DirtTheme.muted)

            HStack(spacing: 6) {
                ForEach([true, false], id: \.self) { enabled in
                    let selected = app.cueSettings.audioEnabled == enabled
                    Button {
                        app.setCueAudioEnabled(enabled)
                        app.planner.toast = "Cue audio \(enabled ? "on" : "off")"
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11, weight: .bold))
                            Text(enabled ? "On" : "Off")
                                .font(.dirtUI(11, weight: .bold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(selected ? DirtTheme.orange : DirtTheme.wash)
                        .foregroundStyle(selected ? .white : DirtTheme.ink)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Cue audio \(enabled ? "on" : "off")")
                    .accessibilityIdentifier(enabled ? "cue-audio-on" : "cue-audio-off")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(10)
        .frame(width: 246)
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
                        ForEach(statuses, id: \.self) { Text(GroupsViewModel.statusLabel($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .dirtDropdownSurface()
                    .tint(DirtTheme.ink)
                    .disabled(!groups.isSharing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    app.planner.toast = groups.toggleSharingFromUI()
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

            if groups.isWaitingForLocation {
                Text("Waiting for GPS")
                    .font(.dirtUI(10, weight: .semibold))
                    .foregroundStyle(DirtTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("group-sharing-waiting-gps")
            }

            if let distress = groups.distressScopeCopy {
                Text(distress)
                    .font(.dirtUI(10))
                    .foregroundStyle(DirtTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
        app.groups.sharingScopeCopy
    }

    private func closePopovers() {
        cuesOpen = false
        sharingOpen = false
    }
}
