import Combine
import SwiftUI

enum DockTab: String, CaseIterable, Identifiable {
    case layers
    case profile
    case group
    case route

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layers: "Layers"
        case .profile: "Profile"
        case .group: "Group"
        case .route: "Route"
        }
    }

    var icon: String {
        switch self {
        case .layers: "square.3.layers.3d"
        case .profile: "person.crop.circle"
        case .group: "person.3"
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

enum ActiveSheet: String, Identifiable {
    case layers
    case profile
    case group

    var id: String { rawValue }
}

enum NavigationChrome {
    static func showsDock(for phase: NavigationSession.Phase) -> Bool {
        phase == .idle
    }

    /// Web `.stack` stays visible; only the recenter control remains when the
    /// route planner owns the lower-right (compact stack).
    static func mapStackCompact(routeCardOpen: Bool, phase: NavigationSession.Phase) -> Bool {
        routeCardOpen && phase == .idle
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSheet: ActiveSheet?
    @State private var routeCardOpen = false

    private let usageTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var navActive: Bool { app.navigation.phase != .idle }

    /// StoreKit entitlement, or pre-release / Debug tester unlock (no fake receipt).
    private var effectiveSubscribed: Bool {
        app.subscription.isSubscribed
            || (BuildChannel.showsTesterUnlock && app.debugBypassSubscription)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapLibreMapView(state: app.mapState, location: app.location)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topChrome
                Spacer(minLength: 0)

                if navActive, !app.mapState.followUser {
                    FollowChip {
                        app.mapState.recenterOnUser(at: app.location.currentCoordinate)
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Stack sits in the same column as sheets/dock so the Figma
                // 24pt clearance above the planner (or dock) is structural —
                // not a guessed absolute bottom inset.
                HStack(alignment: .bottom) {
                    if app.navigation.phase == .active {
                        NavigationPipView()
                            .padding(.leading, 12)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                    Spacer()
                    MapControlStack(
                        compact: NavigationChrome.mapStackCompact(
                            routeCardOpen: routeCardOpen,
                            phase: app.navigation.phase
                        )
                    )
                    .padding(.trailing, 12)
                }
                .padding(.bottom, 24)

                if navActive {
                    // Equal 8pt inset on left / right / bottom (into home-indicator zone).
                    NavBottomPanel()
                        .padding(8)
                        .ignoresSafeArea(edges: .bottom)
                } else if routeCardOpen {
                    RoutePlannerCard(isOpen: $routeCardOpen)
                }
                if NavigationChrome.showsDock(for: app.navigation.phase) {
                    dock
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: app.mapState.followUser)
        }
        .animation(.easeOut(duration: 0.2), value: navActive)
        .onChange(of: app.planner.presentRouteCard) { _, shouldOpen in
            guard shouldOpen else { return }
            activeSheet = nil
            routeCardOpen = true
            app.planner.presentRouteCard = false
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .layers:
                LayersSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(22)
            case .profile:
                ProfileSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(22)
            case .group:
                GroupsSheet(onClose: { activeSheet = nil })
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(22)
            }
        }
        .overlay {
            if let toast = app.planner.toast {
                ToastView(text: toast)
                    .transition(.opacity)
                    .task(id: toast) {
                        // Keep "Calculating route" up until routing finishes.
                        if toast == RoutePlannerModel.calculatingRouteToast {
                            return
                        }
                        try? await Task.sleep(for: .seconds(3.2))
                        if app.planner.toast == toast {
                            withAnimation(.easeOut(duration: 0.25)) {
                                app.planner.toast = nil
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.planner.toast)
        .overlay {
            if app.incidents.isPresented {
                IncidentFlowOverlay()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.incidents.isPresented)
        .overlay {
            if let presentation = app.trial.presentation {
                PaywallView(
                    presentation: presentation,
                    onClose: { app.trial.dismissSoft() },
                    onSubscribed: { app.trial.markSubscribed() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.trial.presentation)
        // POI tap → routing action sheet (web POC "Route to this" / "Use as waypoint")
        .confirmationDialog(
            app.mapState.selectedPOI.map { poi in
                var parts = [poi.displayName]
                if let brand = poi.brand, !brand.isEmpty, brand != poi.displayName {
                    parts.append(brand)
                }
                if let address = poi.address, !address.isEmpty {
                    parts.append(address)
                }
                // Always show category so a blank OSM name still reads clearly.
                if poi.name == nil || poi.name?.isEmpty == true {
                    parts = [poi.categoryLabel]
                } else if poi.displayName.caseInsensitiveCompare(poi.categoryLabel) != .orderedSame {
                    parts.append(poi.categoryLabel)
                }
                return parts.joined(separator: " · ")
            } ?? "",
            isPresented: Binding(
                get: { app.mapState.selectedPOI != nil },
                set: { if !$0 { app.mapState.selectedPOI = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let poi = app.mapState.selectedPOI {
                Button("Route to this") {
                    app.planner.routeToCoordinate(
                        name: poi.displayName,
                        latitude: poi.latitude,
                        longitude: poi.longitude
                    )
                    app.mapState.selectedPOI = nil
                    routeCardOpen = true
                }
                if app.planner.mode == .plan {
                    Button("Add as waypoint") {
                        app.planner.addPlanWaypoint(
                            latitude: poi.latitude,
                            longitude: poi.longitude
                        )
                        app.mapState.selectedPOI = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    app.mapState.selectedPOI = nil
                }
            }
        }
        .onReceive(usageTicker) { _ in
            app.trial.isSubscribed = effectiveSubscribed
            if scenePhase == .active {
                app.trial.tick(canPresent: !navActive)
            }
        }
        .task {
            app.location.requestWhenInUse()
            await app.supabase.bootstrap()
            if app.groups.groups.isEmpty {
                await app.groups.refreshGroups()
            }
            app.trial.isSubscribed = effectiveSubscribed
            if !navActive { app.trial.evaluate() }
        }
    }

    private var topChrome: some View {
        Group {
            if navActive {
                // 24pt gaps: logo · full-width cue · speed (3-digit stable width).
                HStack(alignment: .center, spacing: 24) {
                    BrandChip()
                    NavCueCard()
                        .frame(maxWidth: .infinity)
                    NavSpeedPill()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                HStack(alignment: .top) {
                    BrandChip()
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    /// Full-bleed bottom dock (Figma): 12pt top corners only, chrome extends
    /// under the home indicator. The large bottom curve is the device screen.
    private var dock: some View {
        HStack(spacing: 6) {
            ForEach(DockTab.allCases) { tab in
                dockButton(tab)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12,
                style: .continuous
            )
            .fill(DirtTheme.chrome)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func isActive(_ tab: DockTab) -> Bool {
        switch tab {
        case .layers: activeSheet == .layers
        case .profile: activeSheet == .profile
        case .group: activeSheet == .group
        case .route: routeCardOpen
        }
    }

    private func dockButton(_ tab: DockTab) -> some View {
        Button {
            // Web parity: only one sheet/tool open at a time.
            switch tab {
            case .route:
                activeSheet = nil
                routeCardOpen.toggle()
            case .layers:
                routeCardOpen = false
                activeSheet = activeSheet == .layers ? nil : .layers
            case .profile:
                routeCardOpen = false
                activeSheet = activeSheet == .profile ? nil : .profile
            case .group:
                routeCardOpen = false
                activeSheet = activeSheet == .group ? nil : .group
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(tab.title.uppercased())
                    .font(.dirtUI(9.5, weight: .heavy))
                    .tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isActive(tab) ? DirtTheme.orange : .clear)
            .foregroundStyle(isActive(tab) ? .white : .white.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive(tab) ? .white : .clear, lineWidth: 1)
            )
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.dirtUI(12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DirtTheme.chrome.opacity(0.95))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DirtTheme.chromeBorder, lineWidth: 1))
            .transition(.opacity)
    }
}
