import AuthenticationServices
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
    static func showsRideHUD(for phase: NavigationSession.Phase) -> Bool {
        phase == .active
    }

    static func showsDock(for phase: NavigationSession.Phase) -> Bool {
        phase == .idle
    }

    /// Compact = Recenter (+ fit-route when a planned polyline exists)
    /// while the route planner owns the lower chrome.
    static func mapStackCompact(routeCardOpen: Bool, phase: NavigationSession.Phase) -> Bool {
        routeCardOpen && phase == .idle
    }
}

enum POIActionPolicy {
    static func primaryTitle(mode: RoutePlannerModel.Mode, category: String) -> String {
        let isFuel = category == "fuel"
        if mode == .plan {
            return isFuel ? "Add as fuel waypoint" : "Add as waypoint"
        }
        return isFuel ? "Navigate to fuel station" : "Navigate here"
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var dockDestination: DockTab?
    @Namespace private var dockSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dockTransitionTask: Task<Void, Never>?

    @State private var activeSheet: ActiveSheet? = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DIRT_UI_TEST_PROFILE"] == "1" {
            return .profile
        }
        #endif
        return nil
    }()
    @State private var routeCardOpen = false
    /// Measured portrait planner sheet height so compact map controls sit just above it.
    @State private var portraitRouteSheetHeight: CGFloat = 0
    @State private var showRouteConfetti = false
    @State private var fuelControlsOpen = false
    @State private var ridePreferencesOpen = false
    @State private var mapFuelRangeKm = FuelRangePrefs.kilometers
    @State private var mapFuelReservePercent = FuelRangePrefs.reservePercent
    @State private var mapFuelNotificationsEnabled = FuelRangePrefs.notificationsEnabled
    @State private var coachStep: CoachStep? = OnboardingPrefs.coachComplete ? nil : .openRoute
    /// Left↔right landscape keeps the same size; this ticket forces chrome to re-read
    /// island-side safe-area insets when the device flips.
    @State private var landscapeEdgeTicket: String = ""
    /// GRAPH debug HUD starts collapsed so the map stays visible.
    @State private var routingGraphDebugPanelExpanded = false

    // OfflineMapPrepOverlay exclusively owns prefetch progress. Showing the ride
    // HUD during `.prefetching` duplicated the same loading state behind the modal.
    private var navActive: Bool { NavigationChrome.showsRideHUD(for: app.navigation.phase) }
    private var memberRouteReplacementPresented: Binding<Bool> {
        Binding(
            get: { app.planner.pendingMemberRouteReplacement != nil },
            set: { if !$0 { app.planner.cancelReplaceMemberRoute() } }
        )
    }
    private var selectedPeerPresented: Binding<SelectedGroupPeer?> {
        Binding(
            get: { app.groups.selectedPeer },
            set: { if $0 == nil { app.groups.clearSelectedPeer() } }
        )
    }

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

    private var profilePresented: Binding<Bool> {
        Binding(
            get: { activeSheet == .profile },
            set: { presented in
                if !presented, activeSheet == .profile {
                    activeSheet = nil
                }
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
            .sheet(item: selectedPeerPresented) { peer in
                GroupPeerDetailSheet(
                    peer: peer,
                    onRoute: {
                        app.planner.routeToMember(peer.routeTarget)
                        app.groups.clearSelectedPeer()
                        if app.planner.pendingMemberRouteReplacement == nil {
                            withAnimation(DockSheetMotion.spring) {
                                activeSheet = nil
                                routeCardOpen = true
                            }
                        }
                    },
                    onClose: { app.groups.clearSelectedPeer() }
                )
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
                .presentationBackground(DirtTheme.sheetMaterial)
            }
            .confirmationDialog(
                "Route to a different rider?",
                isPresented: memberRouteReplacementPresented,
                titleVisibility: .visible
            ) {
                if let name = app.planner.pendingMemberRouteReplacement?.displayName {
                    Button("Route to \(name)") {
                        app.planner.confirmReplaceMemberRoute()
                        withAnimation(DockSheetMotion.spring) {
                            activeSheet = nil
                            routeCardOpen = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    app.planner.cancelReplaceMemberRoute()
                }
            } message: {
                if let name = app.planner.pendingMemberRouteReplacement?.displayName {
                    Text("Ends the current ride and routes to \(name).")
                }
            }
            .sheet(isPresented: $ridePreferencesOpen) {
                RidePreferencesSheet(initial: app.planner.displayedRidePreferences) {
                    app.planner.applyRidePreferences($0)
                }
                .presentationDetents([.height(420)])
                .presentationBackground(DirtTheme.sheetMaterial)
            }
            .background { rootLifecycleHooks }
    }

    /// Map + chrome only — kept separate so the type checker can digest the overlays.
    private var mapShell: some View {
        ZStack(alignment: .bottom) {
            // Generations are stored inputs so MapLibre's UIViewRepresentable
            // actually gets updateUIView when Standard/Rich (or overlays) change.
            MapLibreCanvas(
                state: app.mapState,
                location: app.location,
                overlayInsetsGeneration: app.mapState.overlayInsetsGeneration,
                layerPrefsGeneration: app.mapState.layerPrefsGeneration,
                bcOSMOverlayGeneration: app.mapState.bcOSMOverlayGeneration,
                styleURL: app.mapState.styleURL,
                styleGeneration: app.mapState.styleGeneration
            )
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
            if sheet == .group {
                withAnimation(DirtMotion.affordance) {
                    fuelControlsOpen = false
                    ridePreferencesOpen = false
                }
            }
        }
        .onChange(of: app.planner.mode) { _, mode in
            if mode == .saved {
                withAnimation(DirtMotion.affordance) {
                    fuelControlsOpen = false
                    ridePreferencesOpen = false
                }
            }
        }
        .onChange(of: app.navigation.phase) { _, phase in
            handleNavigationPhaseChange(phase)
        }
        .modifier(KeepAwakeLifecycle())
        .overlay(alignment: .top) {
            if app.planner.showsWaypointPlacementConfirmation, !navActive {
                VStack(spacing: 12) {
                    Text("Is this where you want to place this waypoint?")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Button("No") { app.planner.keepMovingWaypoint() }
                            .buttonStyle(.bordered)
                        Button("Yes") { app.planner.confirmWaypointPlacement() }
                            .buttonStyle(.borderedProminent).tint(DirtTheme.orange)
                    }
                }
                .padding(16)
                .frame(maxWidth: 280)
                .dirtGroupingSurface(radius: 16)
                .padding(.top, 68)
            }
        }
        .overlay {
            if app.planner.activeRouteProgressMessage == nil,
               let toast = app.planner.toast {
                ToastView(text: toast)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.planner.toast)
        .animation(.easeInOut(duration: 0.2), value: app.planner.activeRouteProgressMessage)
        .overlay(alignment: .top) {
            GroupMapNoticesHost()
            .padding(.top, 56)
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
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
        .alert(packConsentTitle, isPresented: packConsentPresented) {
            Button(packConsentPrimaryTitle) {
                Task { await app.planner.acceptPackConsent() }
            }
            Button(packConsentCancelTitle, role: .cancel) {
                app.planner.declinePackConsent()
            }
        } message: {
            Text(packConsentMessage)
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
    }

    private var packConsentTitle: String {
        app.planner.packConsent?.title ?? "Routing pack"
    }

    private var packConsentMessage: String {
        app.planner.packConsent?.message ?? ""
    }

    private var packConsentPrimaryTitle: String {
        app.planner.packConsent?.kind == .update ? "Update" : "Download"
    }

    private var packConsentCancelTitle: String {
        app.planner.packConsent?.kind == .update ? "Keep installed" : "Not now"
    }

    private var packConsentPresented: Binding<Bool> {
        Binding(
            get: { app.planner.packConsent != nil },
            // Button actions own the choice. SwiftUI writes `false` while
            // dismissing the alert, before an async Download action necessarily
            // runs; interpreting that write as a decline cancels the download.
            set: { _ in }
        )
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
            if app.planner.mode == .plan {
                Button(POIActionPolicy.primaryTitle(
                    mode: app.planner.mode,
                    category: poi.category
                )) {
                    RoutingDebugLog.shared.event(
                        "ui poi action=add-waypoint category=\(poi.category) id=\(poi.id)"
                    )
                    app.planner.addPlanWaypoint(
                        latitude: poi.latitude,
                        longitude: poi.longitude
                    )
                    app.mapState.selectedPOI = nil
                }
            } else {
                Button(POIActionPolicy.primaryTitle(
                    mode: app.planner.mode,
                    category: poi.category
                )) {
                    RoutingDebugLog.shared.event(
                        "ui poi action=navigate category=\(poi.category) id=\(poi.id)"
                    )
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
                Task { await app.supabase.checkAppleCredential { app.groups.handleCredentialRevoked() } }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: ASAuthorizationAppleIDProvider.credentialRevokedNotification
            )) { _ in
                Task { await app.supabase.checkAppleCredential { app.groups.handleCredentialRevoked() } }
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
                await app.supabase.checkAppleCredential { app.groups.handleCredentialRevoked() }
                await app.rideIntelligence.flushPendingIncidents()
                if app.groups.groups.isEmpty {
                    await app.groups.refreshGroups()
                }
                app.trial.isSubscribed = effectiveSubscribed
                refreshLandscapeEdgeTicket()
            }
            .onChange(of: app.supabase.isSignedIn) { _, signedIn in
                if signedIn {
                    Task {
                        await app.supabase.checkAppleCredential { app.groups.handleCredentialRevoked() }
                        guard app.supabase.isSignedIn else { return }
                        await app.rideIntelligence.flushPendingIncidents()
                        await app.groups.refreshGroups()
                    }
                } else {
                    app.groups.handleSignedOut()
                }
            }
    }

    private var portraitChrome: some View {
        let showsDock = NavigationChrome.showsDock(for: app.navigation.phase)

        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topChrome
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
                    HStack(alignment: .bottom, spacing: 8) {
                        if navActive {
                            NavCueCard()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 12)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else {
                            Spacer(minLength: 0)
                        }
                        mapControlStack(showsZoom: !navActive)
                            .padding(.trailing, 12)
                    }
                    // Sit fully above the sticky dock (was 24pt — stack slid under the bar).
                    // The sharing card below supplies that clearance when it's open.
                    .padding(.bottom, navActive ? 8 : (showsDock ? DockSheetMotion.dockClearance + 8 : 24))
                    .transition(.opacity)
                }

                if navActive {
                    NavBottomPanel()
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

            // Fuel range (leading) + recenter / fit plan (trailing) above route sheet.
            if showsDock, (routeCardOpen || activeSheet != nil), activeSheet != .profile, activeSheet != .layers, activeSheet != .group, !navActive {
                HStack(alignment: .bottom, spacing: 10) {
                    if routeCardOpen, app.planner.mode != .saved {
                        fuelRangeButton
                        ridePreferencesButton
                    }
                    Spacer(minLength: 0)
                    mapControlStack()
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
                    .zIndex(2)

            }
        }
        .overlay(alignment: .top) {
            if hasDynamicIsland {
                islandBrandBar
            }
        }
        .ignoresSafeArea(edges: navActive ? .bottom : [])
        .animation(.easeInOut(duration: 0.2), value: app.mapState.followUser)
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

    @ViewBuilder
    private func dockSheet(
        _ sheet: ActiveSheet,
        landscapeDockLeading: Bool?,
        landscapeHasIslandColumn: Bool = false
    ) -> some View {
        switch sheet {
        case .layers:
            // Same top gap as Profile fully extended — sheet must not run under the DIRT logo.
            DockSheetPanel(
                heightFraction: 0.92,
                expandedHeightFraction: 0.92,
                landscapeDockLeading: landscapeDockLeading,
                landscapeHasIslandColumn: landscapeHasIslandColumn,
                material: .thinMaterial,
