import CoreLocation
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

    /// Cells the first-ride tour rings. Layers is not part of the tour, so it
    /// publishes no anchor.
    var coachTarget: CoachTarget? {
        switch self {
        case .route: .routeDock
        case .group: .groupDock
        case .profile: .profileDock
        case .layers: nil
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

    /// Compact = Recenter (+ fit-route when a planned polyline exists)
    /// while the route planner owns the lower chrome.
    static func mapStackCompact(routeCardOpen: Bool, phase: NavigationSession.Phase) -> Bool {
        routeCardOpen && phase == .idle
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var activeSheet: ActiveSheet?
    @State private var routeCardOpen = false
    /// Measured portrait planner sheet height so compact map controls sit just above it.
    @State private var portraitRouteSheetHeight: CGFloat = 0
    @State private var showRouteConfetti = false
    @State private var offlinePacksOpen = false
    @State private var fuelControlsOpen = false
    @State private var mapFuelRangeKm = FuelRangePrefs.kilometers
    @State private var mapFuelReservePercent = FuelRangePrefs.reservePercent
    @State private var coachStep: CoachStep? = OnboardingPrefs.coachComplete ? nil : .openRoute
    /// Left↔right landscape keeps the same size; this ticket forces chrome to re-read
    /// island-side safe-area insets when the device flips.
    @State private var landscapeEdgeTicket: String = ""

    private var navActive: Bool { app.navigation.phase != .idle }

    /// iPhone landscape — Figma `Navigation — Landscape` packing while navigating.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    private var useLandscapeNavChrome: Bool { navActive && isLandscape }

    /// Figma `landscape-primary view` — idle map + vertical dock + side drawers.
    private var useLandscapePrimaryChrome: Bool { !navActive && isLandscape }

    /// Confirmation-dialog title for a tapped POI (kept out of `body` for the type checker).
    private var poiDialogTitle: String {
        guard let poi = app.mapState.selectedPOI else { return "" }
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
    }

    /// StoreKit entitlement, or pre-release / Debug tester unlock (no fake receipt).
    private var effectiveSubscribed: Bool {
        app.subscription.isSubscribed
            || (BuildChannel.showsTesterUnlock && app.debugBypassSubscription)
    }

    private var softPaywallPresented: Binding<Bool> {
        Binding(
            get: { app.trial.presentation == .soft },
            set: { presented in
                guard !presented else { return }
                dismissSoftPaywall()
            }
        )
    }

    /// The tour never competes with a paywall, a sheet or a live ride, and each step
    /// only shows while the state it describes is actually true — so a rider who
    /// wanders off the path sees the card again when they come back to it.
    private var visibleCoachStep: CoachStep? {
        guard let coachStep,
              app.trial.presentation == nil,
              app.offline.phase == .idle,
              // Step one talks about the rider's location, and on a fresh install the
              // system prompt is still up — it would sit right on top of the card.
              app.location.authorization != .notDetermined,
              !navActive,
              activeSheet == nil
        else { return nil }

        switch coachStep {
        case .openRoute:
            return routeCardOpen ? nil : .openRoute
        case .dropPin:
            return routeCardOpen && !app.planner.hasRoute ? .dropPin : nil
        case .ride:
            return routeCardOpen && app.planner.hasRoute ? .ride : nil
        case .crew, .account:
            return routeCardOpen ? nil : coachStep
        }
    }

    /// Advances the steps that end in a button rather than an action.
    private func advanceCoach() {
        switch coachStep {
        case .ride:
            // Hand the map back with the route still drawn — the armed Route cell is
            // the next thing the tour wants them to recognise anyway.
            withAnimation(DockSheetMotion.spring) { routeCardOpen = false }
            coachStep = .crew
        case .crew:
            coachStep = .account
        case .account:
            finishCoach()
        case .openRoute, .dropPin, nil:
            break
        }
    }

    private func finishCoach() {
        OnboardingPrefs.markCoachComplete()
        withAnimation(.easeInOut(duration: 0.2)) { coachStep = nil }
    }

    private func dismissSoftPaywall() {
        let message = app.trial.dismissMessage()
        app.trial.dismissSoft()
        if let message { app.planner.toast = message }
    }

    var body: some View {
        mapShell
            .background { rootLifecycleHooks }
    }

    /// Map + chrome only — kept separate so the type checker can digest the overlays.
    private var mapShell: some View {
        ZStack(alignment: .bottom) {
            // Observe overlay insets so MapLibre gets updateUIView when the
            // landscape route drawer opens/closes (camera centers in open map).
            let _ = app.mapState.overlayInsetsGeneration
            let _ = app.mapState.layerPrefsGeneration
            let _ = app.mapState.bcOSMOverlayGeneration
            MapLibreMapView(state: app.mapState, location: app.location)
                .ignoresSafeArea()

            if useLandscapeNavChrome {
                landscapeNavigationChrome
            } else if useLandscapePrimaryChrome {
                landscapePrimaryChrome
            } else {
                portraitChrome
            }
        }
        .animation(.easeOut(duration: 0.2), value: navActive)
        .animation(.easeInOut(duration: 0.2), value: useLandscapeNavChrome)
        .animation(.easeInOut(duration: 0.2), value: useLandscapePrimaryChrome)
        .onChange(of: app.planner.presentRouteCard) { _, shouldOpen in
            guard shouldOpen else { return }
            withAnimation(DockSheetMotion.spring) {
                activeSheet = nil
                routeCardOpen = true
            }
            app.planner.presentRouteCard = false
        }
        // The tour follows what the rider does: opening the planner, getting a line,
        // and reaching for the crew or account tools each move it along.
        .onChange(of: routeCardOpen) { _, open in
            guard open, coachStep == .openRoute else { return }
            coachStep = .dropPin
        }
        .onChange(of: app.planner.hasRoute) { _, has in
            guard has, coachStep == .dropPin else { return }
            coachStep = .ride
        }
        .onChange(of: activeSheet) { _, sheet in
            switch (sheet, coachStep) {
            case (.group, .crew): coachStep = .account
            case (.profile, .account): finishCoach()
            default: break
            }
        }
        // Consume a free taste when the live ride actually begins (not on prep cancel).
        .onChange(of: app.navigation.phase) { _, phase in
            if phase == .active {
                app.trial.consumeFreeStartIfNeeded()
            }
        }
        .overlay {
            if let toast = app.planner.toast {
                ToastView(text: toast)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.planner.toast)
        .overlay(alignment: .top) {
            if !app.groups.peerAlerts.isEmpty {
                PeerAlertStack(
                    alerts: app.groups.peerAlerts,
                    onFocus: { app.groups.focusPeerAlert($0) },
                    onDismiss: { app.groups.dismissPeerAlert($0) }
                )
                .padding(.top, 56)
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if fuelControlsOpen, routeCardOpen, !navActive, activeSheet == nil {
                fuelControlPanel
                    .padding(.top, isLandscape ? 12 : 72)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: fuelControlsOpen)
        .animation(.easeInOut(duration: 0.22), value: app.groups.peerAlerts.map(\.id))
        .overlay {
            if showRouteConfetti {
                RouteSuccessConfetti()
                    .transition(.opacity)
            }
        }
        .overlay {
            if app.offline.phase != .idle {
                OfflineMapPrepOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: app.offline.phase)
        .overlayPreferenceValue(CoachTargetKey.self) { anchors in
            GeometryReader { proxy in
                if let step = visibleCoachStep {
                    CoachMarksOverlay(
                        step: step,
                        targetRect: anchors[step.target].map { proxy[$0] },
                        onAdvance: advanceCoach,
                        onSkip: finishCoach
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: visibleCoachStep)
        }
        .overlay {
            if app.incidents.isPresented {
                IncidentFlowOverlay()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.incidents.isPresented)
        .sheet(isPresented: $offlinePacksOpen) {
            OfflinePacksSheet(isPresented: $offlinePacksOpen)
                .environment(app)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { app.pendingTrackContribution },
            set: { app.pendingTrackContribution = $0 }
        )) { candidate in
            ContributeTrackSheet(candidate: candidate) {
                app.pendingTrackContribution = nil
            }
            .environment(app)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(DirtTheme.sheetMaterial)
        }
        .sheet(isPresented: softPaywallPresented) {
            softPaywallSheet
        }
        .confirmationDialog(
            poiDialogTitle,
            isPresented: Binding(
                get: { app.mapState.selectedPOI != nil },
                set: { if !$0 { app.mapState.selectedPOI = nil } }
            ),
            titleVisibility: .visible
        ) {
            poiDialogButtons
        }
        .sheet(item: Binding(
            get: { app.groups.selectedPeer },
            set: { if $0 == nil { app.groups.clearSelectedPeer() } }
        )) { peer in
            GroupPeerDetailSheet(
                peer: peer,
                onRoute: {
                    app.planner.routeToMember(
                        name: peer.displayName,
                        latitude: peer.latitude,
                        longitude: peer.longitude
                    )
                    app.groups.clearSelectedPeer()
                    withAnimation(DockSheetMotion.spring) {
                        activeSheet = nil
                        routeCardOpen = true
                    }
                },
                onClose: { app.groups.clearSelectedPeer() }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
            .presentationBackground(DirtTheme.sheetMaterial)
        }
    }

    private var softPaywallSheet: some View {
        PaywallView(
            presentation: .soft,
            onClose: dismissSoftPaywall,
            onSubscribed: { app.trial.markSubscribed() }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DirtTheme.sheetMaterial)
    }

    @ViewBuilder
    private var poiDialogButtons: some View {
        if let poi = app.mapState.selectedPOI {
            Button("Route to this") {
                app.planner.routeToCoordinate(
                    name: poi.displayName,
                    latitude: poi.latitude,
                    longitude: poi.longitude
                )
                app.mapState.selectedPOI = nil
                withAnimation(DockSheetMotion.spring) {
                    activeSheet = nil
                    routeCardOpen = true
                }
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

    /// Side-effect hooks hung off an invisible background so they don't bloat `mapShell`.
    private var rootLifecycleHooks: some View {
        Color.clear
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                refreshLandscapeEdgeTicket()
                RoutingDebugLog.shared.event("app root appeared")
            }
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                RoutingDebugLog.shared.event("app root disappeared")
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIDevice.orientationDidChangeNotification
            )) { _ in
                // Window insets lag one run-loop behind the notification.
                DispatchQueue.main.async { refreshLandscapeEdgeTicket() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    refreshLandscapeEdgeTicket()
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIScene.didActivateNotification
            )) { _ in
                refreshLandscapeEdgeTicket()
                RoutingDebugLog.shared.event("lifecycle scene active")
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIScene.didEnterBackgroundNotification
            )) { _ in
                RoutingDebugLog.shared.event("lifecycle scene background")
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )) { _ in
                RoutingDebugLog.shared.event("system memory warning")
            }
            .onChange(of: isLandscape) { _, _ in
                refreshLandscapeEdgeTicket()
            }
            .onChange(of: app.planner.toast) { _, newValue in
                guard newValue == RoutePlannerModel.routeReadyToast else { return }
                showRouteConfetti = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(.easeOut(duration: 0.25)) {
                        showRouteConfetti = false
                    }
                }
            }
            .onChange(of: app.subscription.isSubscribed) { _, _ in
                app.trial.isSubscribed = effectiveSubscribed
            }
            .onChange(of: app.debugBypassSubscription) { _, _ in
                app.trial.isSubscribed = effectiveSubscribed
            }
            .task {
                app.location.requestWhenInUse()
                await app.supabase.bootstrap()
                await app.rideIntelligence.flushPendingIncidents()
                if app.groups.groups.isEmpty {
                    await app.groups.refreshGroups()
                }
                app.trial.isSubscribed = effectiveSubscribed
                refreshLandscapeEdgeTicket()
            }
            .onChange(of: app.supabase.isSignedIn) { _, signedIn in
                guard signedIn else { return }
                Task { await app.rideIntelligence.flushPendingIncidents() }
            }
    }

    private var portraitChrome: some View {
        let showsDock = NavigationChrome.showsDock(for: app.navigation.phase)

        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topChrome
                if BuildChannel.debugRoutingGraphOverlay, app.mapState.showRoutingGraphDebug {
                    routingGraphDebugHUD
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)

                if navActive,
                   !app.mapState.followUser,
                   app.mapState.navigationCameraMode == .detail {
                    FollowChip {
                        app.mapState.recenterOnUser(at: app.location.currentCoordinate)
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Hide map chrome (recenter, etc.) while a dock sheet is open —
                // the panel owns the lower screen.
                if showsMapControlStack {
                    HStack(alignment: .bottom) {
                        if navActive {
                            NavSpeedReadout()
                                .padding(.leading, 12)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                        Spacer()
                        mapControlStack
                            .padding(.trailing, 12)
                    }
                    // Sit fully above the sticky dock (was 24pt — stack slid under the bar).
                    // The sharing card below supplies that clearance when it's open.
                    .padding(.bottom, sharingCardOpen ? 8 : (showsDock ? DockSheetMotion.dockClearance + 8 : 24))
                    .transition(.opacity)
                }

                if sharingCardOpen {
                    GroupSharingCard { app.groups.sharingPanelOpen = false }
                        .padding(.horizontal, 8)
                        .padding(.bottom, navActive ? 8 : (showsDock ? DockSheetMotion.dockClearance + 8 : 24))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if navActive {
                    NavBottomPanel()
                        .padding(.horizontal, 8)
                        .padding(.bottom, 16)
                }
            }

            // Panels rise behind the dock so the sticky bar reads as “above” them.
            if showsDock, routeCardOpen, !navActive {
                RoutePlannerCard(isOpen: $routeCardOpen, sitsBehindDock: true)
                    .coachTarget(.routeCard)
                    .transition(DockSheetMotion.transition)
                    .zIndex(1)
            }

            if showsDock, let sheet = activeSheet, !navActive {
                dockSheet(sheet, landscapeDockLeading: nil)
                    .transition(DockSheetMotion.transition)
                    .zIndex(1)
            }

            // Offline packs (leading) + recenter / fit plan (trailing) above route sheet.
            if showsDock, routeCardOpen, activeSheet == nil, !navActive {
                HStack(alignment: .bottom, spacing: 10) {
                    offlinePacksButton
                    if BuildChannel.debugRoutingGraphOverlay {
                        routingGraphDebugButton
                    }
                    fuelRangeButton
                    Spacer(minLength: 0)
                    mapControlStack
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(
                    .bottom,
                    max(portraitRouteSheetHeight, 160) + DockSheetMotion.portraitRouteControlsGap
                )
                .transition(.opacity)
                .zIndex(1.5)
                .allowsHitTesting(true)
            }

            if showsDock {
                dock
                    .shadow(color: .black.opacity(0.32), radius: 18, y: -8)
                    .zIndex(2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(edges: navActive ? .bottom : [])
        .animation(.easeInOut(duration: 0.2), value: app.mapState.followUser)
        .animation(DockSheetMotion.spring, value: activeSheet)
        .animation(DockSheetMotion.spring, value: routeCardOpen)
        .animation(DockSheetMotion.spring, value: app.groups.sharingPanelOpen)
        .onPreferenceChange(PlannerSheetHeightKey.self) { height in
            portraitRouteSheetHeight = height
            syncPortraitMapInsets()
        }
        .onChange(of: routeCardOpen) { _, open in
            if !open { portraitRouteSheetHeight = 0 }
            syncPortraitMapInsets()
        }
        .onChange(of: activeSheet) { _, _ in
            syncPortraitMapInsets()
            // A dock panel owns the lower screen — don't leave the card armed behind it.
            if activeSheet != nil { app.groups.sharingPanelOpen = false }
        }
        .onDisappear {
            // Landscape chrome re-applies its own insets on appear.
            app.mapState.overlayContentInsets = .zero
        }
    }

    /// Bias the map camera into the open strip above the portrait route sheet
    /// so recenter + fit-route frame into available map space (not under the sheet).
    private func syncPortraitMapInsets() {
        guard routeCardOpen, activeSheet == nil, !navActive else {
            app.mapState.overlayContentInsets = .zero
            return
        }
        let bottom = max(portraitRouteSheetHeight, 160)
        app.mapState.overlayContentInsets = UIEdgeInsets(
            top: 0, left: 0, bottom: bottom, right: 0
        )
    }

    /// Recenter / map tools: visible in nav; hidden while any dock panel is open.
    private var showsMapControlStack: Bool {
        if navActive { return true }
        return activeSheet == nil && !routeCardOpen
    }

    /// Live-sharing card follows the map controls that open it.
    private var sharingCardOpen: Bool {
        app.groups.sharingPanelOpen && showsMapControlStack
    }

    @ViewBuilder
    private func dockSheet(_ sheet: ActiveSheet, landscapeDockLeading: Bool?) -> some View {
        switch sheet {
        case .layers:
            DockSheetPanel(
                heightFraction: 0.58,
                landscapeDockLeading: landscapeDockLeading,
                onDismiss: dismissDockSheet
            ) {
                LayersSheet()
            }
        case .profile:
            DockSheetPanel(
                heightFraction: 0.62,
                landscapeDockLeading: landscapeDockLeading,
                onDismiss: dismissDockSheet
            ) {
                ProfileSheet()
            }
        case .group:
            DockSheetPanel(
                heightFraction: 0.72,
                fitsContent: true,
                minContentHeight: 200,
                landscapeDockLeading: landscapeDockLeading,
                onDismiss: dismissDockSheet
            ) {
                GroupsSheet(onClose: dismissDockSheet)
            }
        }
    }

    private func dismissDockSheet() {
        withAnimation(DockSheetMotion.spring) {
            activeSheet = nil
        }
    }

    // MARK: - Landscape primary (Figma landscape-primary view)

    /// Dock always opposite the Dynamic Island, flush to that edge. Drawers slide
    /// horizontally (≤50% width). Map controls run as a bottom strip on the open map.
    private var landscapePrimaryChrome: some View {
        GeometryReader { geo in
            landscapePrimaryChromeContent(
                layoutTicket: geo.size,
                edgeTicket: landscapeEdgeTicket
            )
        }
        .ignoresSafeArea(edges: [.horizontal, .vertical])
        .animation(DockSheetMotion.spring, value: activeSheet)
        .animation(DockSheetMotion.spring, value: routeCardOpen)
        .animation(DockSheetMotion.spring, value: app.groups.sharingPanelOpen)
        .animation(.easeInOut(duration: 0.2), value: app.mapState.followUser)
        .animation(.easeInOut(duration: 0.2), value: landscapeEdgeTicket)
    }

    @ViewBuilder
    private func landscapePrimaryChromeContent(layoutTicket: CGSize, edgeTicket: String) -> some View {
        let _ = edgeTicket
        let screenW = layoutTicket.width
        let insets = Self.foregroundSafeAreaInsets
        let orientation = Self.foregroundInterfaceOrientation
        let islandOnLeading = Self.islandOnLeadingSide(insets: insets, orientation: orientation)
        let dockLeading = !islandOnLeading
        let dockW = DockSheetMotion.landscapeDockWidth
        let islandPad = islandOnLeading ? max(insets.left, 12) : max(insets.right, 12)
        let sheetW = screenW * DockSheetMotion.landscapeMaxDrawerFraction
        let routeSheetOpen = routeCardOpen

        ZStack {
            // Brand chip on the open-map corner opposite the dock (near island, cleared).
            VStack {
                HStack {
                    if dockLeading { Spacer(minLength: 0) }
                    BrandChip()
                    if !dockLeading { Spacer(minLength: 0) }
                }
                .padding(.top, max(insets.top, 12))
                .padding(.leading, dockLeading ? dockW + 12 : islandPad)
                .padding(.trailing, dockLeading ? islandPad : dockW + 12)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)

            // Side drawers behind the vertical dock (wash extends under the rail).
            if routeCardOpen {
                RoutePlannerCard(
                    isOpen: $routeCardOpen,
                    sitsBehindDock: false,
                    landscapeDockLeading: dockLeading
                )
                    .coachTarget(.routeCard)
                .transition(DockSheetMotion.transition(dockLeading: dockLeading))
                .zIndex(1)
            } else if let sheet = activeSheet {
                dockSheet(sheet, landscapeDockLeading: dockLeading)
                    .transition(DockSheetMotion.transition(dockLeading: dockLeading))
                    .zIndex(1)
            }

            // Idle: full bottom control strip. Route sheet: recenter (+ fit plan) outside the sheet.
            // Layers / Profile / Group: no map controls.
            if activeSheet == nil {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        if routeSheetOpen {
                            landscapeRouteMapControls(
                                dockLeading: dockLeading,
                                sheetWidth: sheetW
                            )
                        } else if dockLeading {
                            mapControlStrip(compact: false)
                                .padding(.leading, dockW + 12)
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            mapControlStrip(compact: false)
                                .padding(.trailing, dockW + 12)
                        }
                    }
                    // Keep the strip at control height — unconstrained Color.clear
                    // spacers otherwise expand the HStack and vertically center the button.
                    .fixedSize(horizontal: false, vertical: true)

                    if app.groups.sharingPanelOpen {
                        GroupSharingCard { app.groups.sharingPanelOpen = false }
                            .frame(maxWidth: 420)
                            .padding(.leading, dockLeading ? dockW + 12 : islandPad)
                            .padding(.trailing, dockLeading ? islandPad : dockW + 12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                // Figma MapControlStrip sits ~12pt above the bottom edge (y=331 in 393).
                .padding(.bottom, max(insets.bottom, 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(2)
            }

            // Vertical dock — full height, flush to the non-island edge.
            HStack(spacing: 0) {
                if dockLeading {
                    verticalDock(dockLeading: true)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    verticalDock(dockLeading: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(3)
        }
        .onAppear { syncLandscapeMapInsets(dockLeading: dockLeading, sheetWidth: sheetW) }
        .onChange(of: routeCardOpen) { _, _ in
            syncLandscapeMapInsets(dockLeading: dockLeading, sheetWidth: sheetW)
        }
        .onChange(of: activeSheet) { _, _ in
            syncLandscapeMapInsets(dockLeading: dockLeading, sheetWidth: sheetW)
        }
        .onChange(of: layoutTicket) { _, _ in
            syncLandscapeMapInsets(dockLeading: dockLeading, sheetWidth: sheetW)
        }
        .onChange(of: edgeTicket) { _, _ in
            syncLandscapeMapInsets(dockLeading: dockLeading, sheetWidth: sheetW)
        }
        .onDisappear {
            app.mapState.overlayContentInsets = .zero
        }
    }

    /// Recenter (+ fit whole plan when available) outside the route drawer, 24pt from
    /// its open edge, bottom-aligned with the idle map-control strip.
    private func landscapeRouteMapControls(
        dockLeading: Bool,
        sheetWidth: CGFloat
    ) -> some View {
        let gap = DockSheetMotion.landscapeRecenterGap
        // Width-only gutter: a plain Color.clear expands to the HStack’s offered
        // height and vertically centers the button mid-screen.
        let gutter = Color.clear.frame(width: sheetWidth + gap, height: 1)
        // Packs on the sheet-adjacent edge; fit + recenter on the far open-map edge.
        let controls = HStack(spacing: 10) {
            offlinePacksButton
            if BuildChannel.debugRoutingGraphOverlay {
                routingGraphDebugButton
            }
            fuelRangeButton
            Spacer(minLength: 8)
            if app.planner.canFocusEntirePlannedRoute {
                landscapeFitPlanButton
            }
            landscapeRecenterButton
        }
        .frame(maxWidth: .infinity)
        return HStack(spacing: 0) {
            if dockLeading {
                gutter
                controls
                    .padding(.trailing, 12)
            } else {
                controls
                    .padding(.leading, 12)
                gutter
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var landscapeFitPlanButton: some View {
        Button {
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

    private var landscapeRecenterButton: some View {
        Button {
            if let coordinate = app.location.currentCoordinate {
                app.location.requestWhenInUse()
                app.mapState.recenterOnUser(at: coordinate)
            } else {
                app.location.requestWhenInUse()
                app.mapState.recenterOnUser(at: nil)
            }
        } label: {
            Image(systemName: "dot.scope")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(DirtTheme.chrome)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DirtTheme.chromeBorder, lineWidth: 1)
                )
        }
        .accessibilityLabel("Follow my location")
    }

    private var offlinePacksButton: some View {
        Button {
            offlinePacksOpen = true
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 16, weight: .bold))
                Text("PACKS")
                    .font(.dirtMono(7, weight: .bold))
                    .tracking(0.5)
            }
            .foregroundStyle(app.graphPacks.loadedRegionIds.isEmpty ? .white : DirtTheme.onOrange)
            .frame(width: 50, height: 50)
            .background(app.graphPacks.loadedRegionIds.isEmpty ? DirtTheme.chrome : DirtTheme.orange)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DirtTheme.chromeBorder, lineWidth: 1)
            )
        }
        .accessibilityLabel("Offline map packs")
    }

    private var routingGraphDebugButton: some View {
        Button {
            app.mapState.showRoutingGraphDebug.toggle()
            if !app.mapState.showRoutingGraphDebug {
                app.mapState.debugGraphHit = nil
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 16, weight: .bold))
                Text("GRAPH")
                    .font(.dirtMono(7, weight: .bold))
                    .tracking(0.5)
            }
            .foregroundStyle(app.mapState.showRoutingGraphDebug ? DirtTheme.onOrange : .white)
            .frame(width: 50, height: 50)
            .background(app.mapState.showRoutingGraphDebug ? DirtTheme.orange : DirtTheme.chrome)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DirtTheme.chromeBorder, lineWidth: 1)
            )
        }
        .accessibilityLabel("Debug routing graph overlay")
    }

    private var fuelRangeButton: some View {
        Button {
            mapFuelRangeKm = FuelRangePrefs.kilometers
            mapFuelReservePercent = FuelRangePrefs.reservePercent
            withAnimation(.easeInOut(duration: 0.18)) {
                fuelControlsOpen.toggle()
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "fuelpump.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("\(Int(FuelRangePrefs.kilometers))")
                    .font(.dirtMono(8, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(fuelControlsOpen ? DirtTheme.onOrange : .white)
            .frame(width: 50, height: 50)
            .background(fuelControlsOpen ? DirtTheme.orange : DirtTheme.chrome)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DirtTheme.chromeBorder, lineWidth: 1)
            )
        }
        .accessibilityLabel("Fuel range")
        .accessibilityValue("\(Int(FuelRangePrefs.kilometers)) kilometers, \(Int(FuelRangePrefs.reservePercent)) percent reserve")
        .accessibilityHint("Opens fuel range controls")
    }

    private var fuelControlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "fuelpump.fill")
                    .foregroundStyle(DirtTheme.orange)
                Text("Fuel range")
                    .font(DirtType.rowTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.ink)
                Spacer(minLength: 0)
                Text("\(Int(mapFuelRangeKm)) km")
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.ink)
                    .monospacedDigit()
                Button("Done") {
                    withAnimation(.easeInOut(duration: 0.18)) { fuelControlsOpen = false }
                }
                .font(DirtType.chip)
                .fontWeight(.bold)
                .foregroundStyle(DirtTheme.orange)
                .frame(minHeight: DirtHit.min)
            }

            Slider(
                value: $mapFuelRangeKm,
                in: FuelRangePrefs.minimumKm...FuelRangePrefs.maximumKm,
                step: 10
            ) { editing in
                if editing {
                    app.planner.cancelFuelAssistForRangeEdit()
                    RoutingDebugLog.shared.event(
                        "ui fuel slider begin range=\(Int(mapFuelRangeKm))km"
                    )
                } else {
                    FuelRangePrefs.kilometers = mapFuelRangeKm
                    FuelRangePrefs.lastEnabledKilometers = mapFuelRangeKm
                    RoutingDebugLog.shared.event(
                        "ui fuel slider release range=\(Int(mapFuelRangeKm))km recalc=1"
                    )
                    app.planner.reapplyFuelAssist(rangeKm: mapFuelRangeKm)
                }
            }
            .tint(DirtTheme.orange)
            .accessibilityLabel("Kilometers per tank")

            HStack {
                Text("Usable \(Int(FuelRangePrefs.usableKilometers(for: mapFuelRangeKm, reservePercent: mapFuelReservePercent))) km")
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
                Spacer(minLength: 0)
                Menu {
                    ForEach([0, 5, 10, 15, 20, 25, 30], id: \.self) { percent in
                        Button("\(percent)%") {
                            mapFuelReservePercent = Double(percent)
                            FuelRangePrefs.reservePercent = Double(percent)
                            RoutingDebugLog.shared.event(
                                "ui fuel reserve selected=\(percent)% recalc=1"
                            )
                            app.planner.reapplyFuelAssist(rangeKm: mapFuelRangeKm)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(Int(mapFuelReservePercent))% reserve")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(DirtType.chip)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.ink)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .background(DirtTheme.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .accessibilityLabel("Fuel safety reserve")
                .accessibilityValue("\(Int(mapFuelReservePercent)) percent")
            }
        }
        .padding(14)
        .frame(maxWidth: 420)
        .background(DirtTheme.sheetMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
    }

    private func syncLandscapeMapInsets(dockLeading: Bool, sheetWidth: CGFloat) {
        // Only bias the map camera while the route drawer is open.
        guard routeCardOpen, activeSheet == nil else {
            app.mapState.overlayContentInsets = .zero
            return
        }
        if dockLeading {
            app.mapState.overlayContentInsets = UIEdgeInsets(top: 0, left: sheetWidth, bottom: 0, right: 0)
        } else {
            app.mapState.overlayContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: sheetWidth)
        }
    }

    private func mapControlStrip(compact: Bool) -> some View {
        MapControlStack(
            compact: compact,
            groupOnly: activeSheet == .group,
            horizontal: true
        )
    }

    private func verticalDock(dockLeading: Bool) -> some View {
        // Figma: VERTICAL + SPACE_BETWEEN, paddingTop/Bottom 47.
        VStack(spacing: 0) {
            ForEach(Array(DockTab.allCases.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { Spacer(minLength: 0) }
                dockButton(tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, DockSheetMotion.landscapeDockEndPadding)
        .padding(.bottom, DockSheetMotion.landscapeDockEndPadding)
        .frame(width: DockSheetMotion.landscapeDockWidth)
        .frame(maxHeight: .infinity)
        .dirtDenseChrome()
        .background {
            ZStack {
                Rectangle().fill(DirtTheme.chromeMaterial)
                Rectangle().fill(DirtTheme.chromeScrim)
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: dockLeading ? 0 : 12,
                bottomLeadingRadius: dockLeading ? 0 : 12,
                bottomTrailingRadius: dockLeading ? 12 : 0,
                topTrailingRadius: dockLeading ? 12 : 0,
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(0.28),
            radius: 16,
            x: dockLeading ? 4 : -4,
            y: 0
        )
    }

    /// Figma 65:6 — brand-width left rail, cue + speed in the open map, PiP top-right, controls on the trailing edge.
    ///
    /// Horizontal safe area is asymmetric in landscape (Dynamic Island on leading *or*
    /// trailing depending on rotation). We ignore the default inset on both sides, then
    /// clear each edge from live window insets — and mirror the rail/controls so the
    /// island side never eats the map-control stack.
    private var landscapeNavigationChrome: some View {
        GeometryReader { geo in
            landscapeNavigationChromeContent(
                layoutTicket: geo.size,
                edgeTicket: landscapeEdgeTicket
            )
        }
        .ignoresSafeArea(edges: .horizontal)
        .animation(.easeInOut(duration: 0.2), value: app.mapState.followUser)
        .animation(.easeInOut(duration: 0.2), value: landscapeEdgeTicket)
    }

    @ViewBuilder
    private func landscapeNavigationChromeContent(layoutTicket: CGSize, edgeTicket: String) -> some View {
        let _ = layoutTicket
        let _ = edgeTicket
        let insets = Self.foregroundSafeAreaInsets
        let orientation = Self.foregroundInterfaceOrientation
        let islandOnLeading = Self.islandOnLeadingSide(insets: insets, orientation: orientation)
        // Always honor live insets on both sides (fixes sticky leading-only pad).
        let leadingPad = max(insets.left, 12)
        let trailingPad = max(insets.right, 12)

        let rail = VStack(alignment: .leading, spacing: 8) {
            BrandChip(minHeight: 68, fillsWidth: true)
                .frame(width: NavChromeMetrics.landscapeBrandColumn)
            NavLandscapeRail()
            Spacer(minLength: 0)
        }

        let cueCluster = HStack(alignment: .top, spacing: 8) {
            NavCueCard()
                .frame(maxWidth: NavChromeMetrics.landscapeCueMaxWidth, alignment: .leading)
            NavSpeedReadout(compact: true)
        }

        ZStack {
            HStack(alignment: .top, spacing: 8) {
                if islandOnLeading {
                    // Island on leading → rail/cue clear the island; controls on open trailing.
                    rail
                    cueCluster
                    Spacer(minLength: 8)
                    mapControlStack
                } else {
                    // Island on trailing → flip so controls stay reachable on the open side.
                    mapControlStack
                    Spacer(minLength: 8)
                    cueCluster
                    rail
                }
            }
            .padding(.leading, leadingPad)
            .padding(.trailing, trailingPad)
            .padding(.top, max(insets.top, 6))
            .padding(.bottom, max(insets.bottom, 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if navActive,
               !app.mapState.followUser,
               app.mapState.navigationCameraMode == .detail {
                FollowChip {
                    app.mapState.recenterOnUser(at: app.location.currentCoordinate)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    /// Dynamic Island / sensor housing side in landscape. Prefer live window insets;
    /// fall back to interface orientation when insets are still symmetric.
    private static func islandOnLeadingSide(
        insets: UIEdgeInsets,
        orientation: UIInterfaceOrientation
    ) -> Bool {
        if abs(insets.left - insets.right) > 8 {
            return insets.left > insets.right
        }
        switch orientation {
        case .landscapeRight: return true  // device top (island) on leading
        case .landscapeLeft: return false // device top (island) on trailing
        default: return insets.left >= insets.right
        }
    }

    private func refreshLandscapeEdgeTicket() {
        let insets = Self.foregroundSafeAreaInsets
        let orientation = Self.foregroundInterfaceOrientation
        landscapeEdgeTicket =
            "\(orientation.rawValue)-\(Int(insets.left.rounded()))-\(Int(insets.right.rounded()))"
    }

    private static var foregroundWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static var foregroundInterfaceOrientation: UIInterfaceOrientation {
        foregroundWindowScene?.effectiveGeometry.interfaceOrientation ?? .unknown
    }

    private static var foregroundSafeAreaInsets: UIEdgeInsets {
        let scene = foregroundWindowScene
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        return window?.safeAreaInsets ?? .zero
    }

    private var mapControlStack: some View {
        MapControlStack(
            compact: NavigationChrome.mapStackCompact(
                routeCardOpen: routeCardOpen,
                phase: app.navigation.phase
            ),
            groupOnly: activeSheet == .group
        )
    }

    private var topChrome: some View {
        Group {
            if navActive {
                // Speed moved to the bottom-left block, so the cue takes the width it left
                // behind — the turn instruction is the second thing a rider looks at.
                HStack(alignment: .top, spacing: 8) {
                    BrandChip(minHeight: 68)
                    NavCueCard()
                        .frame(maxWidth: .infinity)
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

    private var routingGraphDebugHUD: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(app.mapState.debugGraphStatus ?? "DEBUG routing graph")
                .font(.dirtMono(11, weight: .semibold))
                .foregroundStyle(.white)
            Text("Green = permissive · amber = unknown/Allow · orange = restricted · red = excluded. OSM highway tag is not in the pack — road class shown on tap. Viewport-capped.")
                .font(.dirtMono(10))
                .foregroundStyle(.white.opacity(0.72))
            if let hit = app.mapState.debugGraphHit {
                VStack(alignment: .leading, spacing: 2) {
                    Text("tap \(hit.edgeId)")
                    Text("surface \(hit.surfaceClass)")
                    Text("access \(hit.accessClass)")
                    Text("roadClass \(hit.roadClass)  ·  highway (not packed)")
                    Text("source \(hit.source)")
                }
                .font(.dirtMono(11, weight: .medium))
                .foregroundStyle(DirtTheme.onOrange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirtTheme.chrome.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Floating dark-glass bar inside the safe area: the map runs past it on every side,
    /// so the chrome reads as sitting *on* the map instead of cropping it.
    private var dock: some View {
        HStack(spacing: 4) {
            ForEach(DockTab.allCases) { tab in
                dockButton(tab)
            }
        }
        .padding(5)
        .dirtChromeSurface(radius: 22)
        .padding(.horizontal, 12)
        // Measured from the physical bottom, not the safe-area edge: the bar hangs into
        // the home-indicator strip so the sheet behind it reaches the screen edge.
        .padding(.bottom, DockSheetMotion.dockBottomGap - homeIndicatorInset)
        .dirtDenseChrome()
    }

    /// Bottom safe-area inset, read from the window. The chrome stack has already been
    /// inset by the time the dock lays out, so `ignoresSafeArea` on the bar alone buys
    /// it no extra room — offsetting against the real inset does.
    private var homeIndicatorInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }

    private func isActive(_ tab: DockTab) -> Bool {
        switch tab {
        case .layers: activeSheet == .layers
        case .profile: activeSheet == .profile
        case .group: activeSheet == .group
        case .route: routeCardOpen
        }
    }

    /// A dock item is either closed, showing its panel, or — Route only — closed with a
    /// planned route still on the map, which is the state that has to invite a re-open.
    private enum DockItemState {
        case idle
        case open
        case armed

        /// `onOrange` is 6.80:1 on the orange fill; white is 2.61:1 and fails.
        var foreground: Color {
            switch self {
            case .open: DirtTheme.onOrange
            case .armed: DirtTheme.orangeSoft
            case .idle: .white.opacity(0.72)
            }
        }

        var fill: Color {
            switch self {
            case .open: DirtTheme.orange
            case .armed: DirtTheme.orange.opacity(0.16)
            case .idle: .clear
            }
        }

        var stroke: Color {
            switch self {
            case .open: .clear
            case .armed: DirtTheme.orange.opacity(0.65)
            case .idle: .clear
            }
        }

        var strokeWidth: CGFloat { self == .armed ? 1.5 : 0 }
    }

    private func dockState(_ tab: DockTab) -> DockItemState {
        if isActive(tab) { return .open }
        if tab == .route, app.planner.hasRoute { return .armed }
        return .idle
    }

    private func toggleDockTab(_ tab: DockTab) {
        withAnimation(DockSheetMotion.spring) {
            // One tool at a time; tap again to close. Route clears other sheets.
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
        }
    }

    private func dockAccessibilityHint(_ tab: DockTab, state: DockItemState) -> String {
        switch state {
        case .open: "Closes \(tab.title)"
        case .armed: "Reopens the route planner to edit your route"
        case .idle: "Opens \(tab.title)"
        }
    }

    private func dockButton(_ tab: DockTab) -> some View {
        let state = dockState(tab)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return Button {
            toggleDockTab(tab)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 23, weight: .semibold))
                Text(tab.title.uppercased())
                    .font(.dirtUI(12, weight: .heavy))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(state.foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DirtHit.min)
            .padding(.vertical, 6)
            .background(state.fill, in: shape)
            .overlay(shape.stroke(state.stroke, lineWidth: state.strokeWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .coachTarget(tab.coachTarget)
        .accessibilityLabel(tab.title)
        .accessibilityHint(dockAccessibilityHint(tab, state: state))
        .accessibilityAddTraits(state == .open ? [.isSelected] : [])
    }
}

struct ToastView: View {
    let text: String

    private var isCalculating: Bool {
        text == RoutePlannerModel.calculatingRouteToast
    }

    private var isSuccess: Bool {
        text == RoutePlannerModel.routeReadyToast
    }

    var body: some View {
        HStack(spacing: 8) {
            if isCalculating {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            Text(text)
                .font(.dirtUI(12, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            (isSuccess ? DirtTheme.navGreen : DirtTheme.chrome).opacity(0.95)
        )
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(
                isSuccess ? DirtTheme.navGreen.opacity(0.9) : DirtTheme.chromeBorder,
                lineWidth: 1
            )
        )
        .transition(.opacity)
    }
}

/// Peer distress banners while a group ride is live.
struct PeerAlertStack: View {
    let alerts: [PeerAlertBanner]
    let onFocus: (PeerAlertBanner) -> Void
    let onDismiss: (String) -> Void

    var body: some View {
        VStack(spacing: DirtSpace.tight) {
            ForEach(alerts.prefix(3)) { alert in
                let isBreakdown = alert.status == "breakdown"
                Button {
                    onFocus(alert)
                } label: {
                    HStack(alignment: .center, spacing: DirtSpace.inner) {
                        VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                            Text(alert.title)
                                .font(DirtType.rowTitle)
                                .fontWeight(.bold)
                                .foregroundStyle(isBreakdown ? .white : DirtTheme.ink)
                            Text(alert.subtitle)
                                .font(DirtType.helper)
                                .foregroundStyle(isBreakdown ? .white.opacity(0.9) : DirtTheme.muted)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Button {
                            onDismiss(alert.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(isBreakdown ? .white.opacity(0.85) : DirtTheme.muted)
                                .frame(width: DirtHit.min, height: DirtHit.min)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss alert")
                    }
                    .padding(.leading, DirtSpace.inner)
                    .padding(.trailing, DirtSpace.tight)
                    .padding(.vertical, DirtSpace.tight)
                    .frame(minHeight: DirtHit.control)
                    .background(background(for: alert.status), in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                            .stroke(border(for: alert.status), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func background(for status: String) -> Color {
        switch status {
        case "breakdown": return Color(dirtHex: 0xDC6803)
        case "injured": return Color(dirtHex: 0xC1122F).opacity(0.12)
        case "stuck": return Color(dirtHex: 0x7C3AED).opacity(0.12)
        default: return DirtTheme.rowFill
        }
    }

    private func border(for status: String) -> Color {
        switch status {
        case "breakdown": return Color(dirtHex: 0xDC6803)
        case "injured": return Color(dirtHex: 0xC1122F).opacity(0.35)
        case "stuck": return Color(dirtHex: 0x7C3AED).opacity(0.35)
        default: return DirtTheme.hairline
        }
    }
}

/// Group rider popup — details first, then explicit route CTA.
private struct GroupPeerDetailSheet: View {
    let peer: SelectedGroupPeer
    let onRoute: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DirtSpace.row) {
            HStack {
                Text("Rider")
                    .font(DirtType.sectionLabel)
                    .tracking(1.1)
                    .foregroundStyle(DirtTheme.muted)
                    .textCase(.uppercase)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DirtTheme.muted)
                        .frame(width: DirtHit.min, height: DirtHit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            Text(peer.displayName)
                .font(DirtType.title)
                .fontWeight(.bold)
                .foregroundStyle(DirtTheme.ink)

            detailRow(label: "Group", value: peer.groupName)
            detailRow(label: "Status", value: peer.statusText)
            detailRow(label: "Last seen", value: peer.lastSeenLabel)

            Spacer(minLength: 0)

            Button("Route to this member", action: onRoute)
                .buttonStyle(DirtCTAStyle.brand())
        }
        .padding(DirtSpace.group)
        .background(DirtTheme.sheetMaterial)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DirtSpace.inner) {
            Text(label)
                .font(DirtType.helper)
                .fontWeight(.semibold)
                .foregroundStyle(DirtTheme.muted)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(DirtType.rowTitle)
                .foregroundStyle(DirtTheme.ink)
            Spacer(minLength: 0)
        }
        .frame(minHeight: DirtHit.min * 0.7, alignment: .leading)
    }
}
