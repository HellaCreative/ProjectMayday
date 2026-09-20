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
    /// The ride-settings panel must cover the dock and map controls while it is
    /// open, so its parent route card is promoted above those sibling layers.
    @State private var routeRideSettingsPresented = false
    /// Measured portrait planner sheet height so compact map controls sit just above it.
    @State private var portraitRouteSheetHeight: CGFloat = 0
    @State private var showRouteConfetti = false
    @State private var routeConfettiTask: Task<Void, Never>?
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
                routeConfettiTask?.cancel()
                routeConfettiTask = nil
                showRouteConfetti = false
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
            .onChange(of: app.planner.routeCompletionID) { _, completionID in
                guard completionID != nil else { return }
                routeConfettiTask?.cancel()
                showRouteConfetti = false
                routeConfettiTask = Task { @MainActor in
                    // Let the completed leg list establish the map's insets.
                    await Task.yield()
                    guard !Task.isCancelled,
                          app.planner.routeCompletionID == completionID else { return }
                    app.planner.frameCompletedRouteForCelebration()
                }
            }
            .onChange(of: app.mapState.completedRouteOverviewID) { _, overviewID in
                guard overviewID != nil else { return }
                routeConfettiTask?.cancel()
                showRouteConfetti = true
                routeConfettiTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    guard !Task.isCancelled else { return }
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
                RoutePlannerCard(
                    isOpen: $routeCardOpen,
                    sitsBehindDock: true,
                    onRideSettingsPresentationChanged: { routeRideSettingsPresented = $0 }
                )
                    .coachTarget(.routeCard)
                    .transition(DockSheetMotion.transition)
                    .zIndex(routeRideSettingsPresented ? 3 : 1)
            }

            if showsDock, let sheet = activeSheet, !navActive {
                dockSheet(sheet, landscapeDockLeading: nil)
                    .transition(DockSheetMotion.transition)
                    .zIndex(1)
            }

            // Recenter / fit plan controls above the route sheet.
            if showsDock, (routeCardOpen || activeSheet != nil), activeSheet != .profile, activeSheet != .layers, activeSheet != .group, !navActive {
                HStack(alignment: .bottom, spacing: 10) {
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
                showsDragIndicator: true,
                landscapeDockLeading: landscapeDockLeading,
                landscapeHasIslandColumn: landscapeHasIslandColumn,
                material: .thinMaterial,
                onDismiss: dismissDockSheet
            ) {
                LayersSheet(onClose: dismissDockSheet)
            }
        case .group:
            DockSheetPanel(
                heightFraction: 0.60,
                expandedHeightFraction: 0.92,
                showsDragIndicator: true,
                landscapeDockLeading: landscapeDockLeading,
                landscapeHasIslandColumn: landscapeHasIslandColumn,
                onDismiss: dismissDockSheet
            ) {
                GroupsSheet(onClose: dismissDockSheet, onRoute: {
                    activeSheet = nil
                    routeCardOpen = true
                })
            }
        case .profile:
            DockSheetPanel(
                heightFraction: 0.72,
                fitsContent: true,
                minContentHeight: 340,
                contentBreathing: DirtSpace.section,
                expandedHeightFraction: 0.92,
                showsDragIndicator: true,
                landscapeDockLeading: landscapeDockLeading,
                landscapeHasIslandColumn: landscapeHasIslandColumn,
                onDismiss: dismissDockSheet
            ) {
                ProfileSheet(onClose: dismissDockSheet)
            }
        }
    }

    private func dismissDockSheet() {
        dockTransitionTask?.cancel()
        dockDestination = nil
        withAnimation(reduceMotion ? nil : DirtMotion.sheetExit) {
            activeSheet = nil
        }
    }

    // MARK: - Landscape primary (Figma landscape-primary view)

    /// Dock always on the Dynamic Island edge. Drawers slide horizontally
    /// (≤50% width) under the rail. Map controls run as a bottom strip on the open map.
    private var landscapePrimaryChrome: some View {
        GeometryReader { geo in
            landscapePrimaryChromeContent(
                layoutTicket: geo.size,
                edgeTicket: landscapeEdgeTicket
            )
        }
        .ignoresSafeArea(edges: [.horizontal, .vertical])
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
        let dockLeading = islandOnLeading
        let hasIslandColumn = DirtIsland.hasHardwareCutout(insets: insets)
        let dockW = DockSheetMotion.landscapeDockWidth(hasIslandColumn: hasIslandColumn)
        let sheetW = screenW * DockSheetMotion.landscapeMaxDrawerFraction
        let routeSheetOpen = routeCardOpen

        ZStack {
            // Wordmark lives in the dock. Build/debug toasts stay on the open map.
            if islandTickerHasContent {
                VStack {
                    HStack {
                        if dockLeading { Spacer(minLength: 0) }
                        landscapeMapStatusStack
                        if !dockLeading { Spacer(minLength: 0) }
                    }
                    .padding(.top, max(insets.top, 12))
                    .padding(.leading, dockLeading ? dockW + 12 : 12)
                    .padding(.trailing, dockLeading ? 12 : dockW + 12)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            // Side drawers behind the vertical dock (wash extends under the rail).
            if routeCardOpen {
                RoutePlannerCard(
                    isOpen: $routeCardOpen,
                    sitsBehindDock: false,
                    landscapeDockLeading: dockLeading,
                    landscapeHasIslandColumn: hasIslandColumn,
                    onRideSettingsPresentationChanged: { routeRideSettingsPresented = $0 }
                )
                    .coachTarget(.routeCard)
                .transition(DockSheetMotion.transition(dockLeading: dockLeading))
                .zIndex(routeRideSettingsPresented ? 4 : 1)
            } else if let sheet = activeSheet {
                dockSheet(
                    sheet,
                    landscapeDockLeading: dockLeading,
                    landscapeHasIslandColumn: hasIslandColumn
                )
                    .transition(DockSheetMotion.transition(dockLeading: dockLeading))
                    .zIndex(1)
            }

            // Idle: full bottom control strip. Route sheet: recenter (+ fit plan) outside the sheet.
            // Layers / Group: no map controls. Profile owns a full-screen cover.
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
                }
                // Figma MapControlStrip sits ~12pt above the bottom edge (y=331 in 393).
                .padding(.bottom, max(insets.bottom, 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(2)
            }

            // Vertical dock — full height, flush to the Island edge.
            HStack(spacing: 0) {
                if dockLeading {
                    verticalDock(dockLeading: true, hasIslandColumn: hasIslandColumn)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    verticalDock(dockLeading: false, hasIslandColumn: hasIslandColumn)
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

    private func toggleRoutingGraphDebug() {
        withAnimation(.easeInOut(duration: 0.22)) {
            app.mapState.showRoutingGraphDebug.toggle()
            if app.mapState.showRoutingGraphDebug {
                app.mapState.debugGraphPaintMode = .access
            } else {
                app.mapState.debugGraphHit = nil
                routingGraphDebugPanelExpanded = false
            }
        }
    }

    private func graphBrandButton(fillsWidth: Bool = false) -> some View {
        Button(action: toggleRoutingGraphDebug) {
            BrandChip(minHeight: 48, fillsWidth: fillsWidth)
            .overlay(
                RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous)
                    .stroke(
                        app.mapState.showRoutingGraphDebug ? DirtTheme.orange : Color.clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.mapState.showRoutingGraphDebug ? "Hide surface network" : "Show surface network")
        .accessibilityHint("Shows or hides nearby road surfaces")
    }

    /// Portrait Island phones: hardware cutout on top, wordmark under it, one
    /// black rounded wrapper around both. Nothing is drawn into the cutout.
    private var islandBrandBar: some View {
        IslandBrandBar(
            graphDebugVisible: app.mapState.showRoutingGraphDebug,
            onToggleGraph: toggleRoutingGraphDebug
        )
    }

    /// Portrait top chrome sits in the safe area with this inset. Island overlay
    /// ignores the top inset, so ticker clearance subtracts it.
    private var portraitTopChromeInset: CGFloat { 6 }

    /// Push the progress ticker below the Island wrapper by the same gap as
    /// minus→3D on the map control stack. Does not move the wrapper.
    private var islandTickerClearance: CGFloat {
        guard hasDynamicIsland else { return 0 }
        let barBottom = DirtIsland.cutoutTop + DirtIsland.restingHeight
        let safeTop = Self.foregroundSafeAreaInsets.top
        return max(0, barBottom + MapControlStack.afterZoomGap - safeTop - portraitTopChromeInset)
    }

    private var islandTickerHasContent: Bool {
        app.planner.activeRouteProgressMessage != nil
            || (BuildChannel.debugRoutingGraphOverlay && app.mapState.showRoutingGraphDebug)
    }

    @ViewBuilder
    private var idleBrandStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hasDynamicIsland {
                graphBrandButton()
            }

            if let progress = app.planner.activeRouteProgressMessage {
                ToastView(text: progress, isBuildingRoute: true)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if BuildChannel.debugRoutingGraphOverlay, app.mapState.showRoutingGraphDebug {
                routingGraphDebugHUD
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .padding(.top, hasDynamicIsland && islandTickerHasContent ? islandTickerClearance : 0)
        .frame(maxWidth: 300, alignment: .leading)
    }

    /// Landscape map toasts only — the wordmark is in the vertical dock.
    @ViewBuilder
    private var landscapeMapStatusStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = app.planner.activeRouteProgressMessage {
                ToastView(text: progress, isBuildingRoute: true)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if BuildChannel.debugRoutingGraphOverlay, app.mapState.showRoutingGraphDebug {
                routingGraphDebugHUD
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
    }

    /// Consume a free taste when the live ride actually begins (not on prep cancel).
    private func handleNavigationPhaseChange(_ phase: NavigationSession.Phase) {
        if phase == .active {
            app.trial.consumeFreeStartIfNeeded()
        }
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
            savedOnly: routeCardOpen && app.planner.mode == .saved && !app.planner.showingLoop,
            horizontal: true
        )
    }

    private func verticalDock(dockLeading: Bool, hasIslandColumn: Bool) -> some View {
        let islandCol = DockSheetMotion.landscapeIslandColumn
        let tabs = VStack(spacing: 0) {
            ForEach(Array(DockTab.allCases.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { Spacer(minLength: 0) }
                dockButton(tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, DockSheetMotion.landscapeDockEndPadding)
        .frame(width: DockSheetMotion.landscapeDockRailWidth)
        .frame(maxHeight: .infinity)

        return VStack(spacing: 0) {
            graphBrandButton(fillsWidth: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.top, 16)
                .padding(.bottom, 8)

            HStack(spacing: 0) {
                if hasIslandColumn, dockLeading {
                    Color.clear.frame(width: islandCol)
                    tabs
                } else if hasIslandColumn {
                    tabs
                    Color.clear.frame(width: islandCol)
                } else {
                    tabs
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: DockSheetMotion.landscapeDockWidth(hasIslandColumn: hasIslandColumn))
        .frame(maxHeight: .infinity)
        .dirtDenseChrome()
        .background {
            ZStack {
                Rectangle().fill(DirtTheme.navigationSurface)
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

    /// Ride chrome clusters on the side opposite the Dynamic Island so that
    /// edge stays open map. +/− sit at the top of the island-side map.
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
        let islandPad = max(islandOnLeading ? insets.left : insets.right, 12)
        let clusterPad = NavChromeMetrics.landscapeClusterEdgePad

        let band = NavChromeMetrics.landscapeTopBandHeight
        let rail = VStack(alignment: .leading, spacing: 8) {
            BrandChip(minHeight: band, fillsWidth: true)
                .frame(width: NavChromeMetrics.landscapeBrandColumn, height: band)
            NavLandscapeRail()
            Spacer(minLength: 0)
        }

        let cueCluster = HStack(alignment: .top, spacing: 8) {
            NavCueCard(bandHeight: band)
                .frame(maxWidth: NavChromeMetrics.landscapeCueMaxWidth, alignment: .leading)
            NavSpeedReadout(compact: true)
        }

        let islandZoom = MapZoomControls()

        let rideChips = MapControlStack(
            compact: NavigationChrome.mapStackCompact(
                routeCardOpen: routeCardOpen,
                phase: app.navigation.phase
            ),
            groupOnly: activeSheet == .group,
            savedOnly: routeCardOpen && app.planner.mode == .saved && !app.planner.showingLoop,
            showsZoom: false,
            landscapeChipsOnTrailing: islandOnLeading
        )

        ZStack {
            HStack(alignment: .top, spacing: 8) {
                if islandOnLeading {
                    islandZoom
                    Spacer(minLength: 8)
                    cueCluster
                    rail
                    rideChips
                } else {
                    rideChips
                    rail
                    cueCluster
                    Spacer(minLength: 8)
                    islandZoom
                }
            }
            .padding(.leading, islandOnLeading ? islandPad : clusterPad)
            .padding(.trailing, islandOnLeading ? clusterPad : islandPad)
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

    private var hasDynamicIsland: Bool {
        DirtIsland.isPresent(
            topInset: Self.foregroundSafeAreaInsets.top,
            isLandscape: isLandscape
        )
    }

    private func mapControlStack(showsZoom: Bool = true) -> some View {
        MapControlStack(
            compact: NavigationChrome.mapStackCompact(
                routeCardOpen: routeCardOpen,
                phase: app.navigation.phase
            ),
            groupOnly: activeSheet == .group,
            savedOnly: routeCardOpen && app.planner.mode == .saved && !app.planner.showingLoop,
            showsZoom: showsZoom
        )
    }

    private var topChrome: some View {
        Group {
            if navActive {
                HStack(alignment: .top, spacing: 8) {
                    if !hasDynamicIsland {
                        BrandChip(minHeight: 68)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: MapControlStack.itemSpacing) {
                        NavSpeedReadout(compact: true)
                        MapZoomControls(axis: .vertical)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                HStack(alignment: .top, spacing: 8) {
                    idleBrandStack
                    Spacer(minLength: 8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, portraitTopChromeInset)
    }

    private var routingGraphDebugHUD: some View {
        VStack(alignment: .leading, spacing: routingGraphDebugPanelExpanded ? 8 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    routingGraphDebugPanelExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("GRAPH")
                        .font(.dirtMono(8, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(DirtTheme.onOrange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DirtTheme.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Text(compactDebugGraphSummary)
                        .font(.dirtMono(10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)

                    Image(systemName: routingGraphDebugPanelExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: routingGraphDebugPanelExpanded ? .infinity : nil, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Graph debug panel")
            .accessibilityHint(routingGraphDebugPanelExpanded ? "Collapse graph debug controls" : "Expand graph debug controls")

            if routingGraphDebugPanelExpanded {
                Text(app.mapState.debugGraphStatus ?? "DEBUG routing graph")
                    .font(.dirtMono(10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    ForEach(availableDebugGraphPaintModes, id: \.self) { mode in
                        Button {
                            app.mapState.debugGraphPaintMode = mode
                        } label: {
                            Text(mode.title)
                                .font(.dirtMono(10, weight: .bold))
                                .foregroundStyle(
                                    app.mapState.debugGraphPaintMode == mode
                                        ? DirtTheme.onOrange : .white.opacity(0.85)
                                )
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    app.mapState.debugGraphPaintMode == mode
                                        ? DirtTheme.orange : DirtTheme.chrome.opacity(0.55)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                ScrollView(.vertical, showsIndicators: false) {
                    debugGraphLegend(for: app.mapState.debugGraphPaintMode)
                }
                .frame(maxHeight: 96)

                if let hit = app.mapState.debugGraphHit {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("tap \(hit.edgeId)")
                        Text("surfaceLeaf \(hit.surfaceLeaf.isEmpty ? "—" : hit.surfaceLeaf) · family \(hit.surfaceFamily)")
                        Text("roadClassLeaf \(hit.roadClassLeaf.isEmpty ? "—" : hit.roadClassLeaf) · tier \(hit.roadTier)")
                        Text("access \(hit.accessClass) · leaf \(hit.accessLeaf.isEmpty ? "—" : hit.accessLeaf)\(hit.atvDesignated ? " · ATV" : "")")
                        Text("coarse \(hit.surfaceClass) / \(hit.roadClass) · \(hit.source)")
                    }
                    .font(.dirtMono(10, weight: .medium))
                    .foregroundStyle(DirtTheme.onOrange)
                }
            }
        }
        .padding(routingGraphDebugPanelExpanded ? 10 : 8)
        .frame(maxWidth: routingGraphDebugPanelExpanded ? 300 : 260, alignment: .leading)
        .background(DirtTheme.chrome.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
    }

    private var compactDebugGraphSummary: String {
        var parts: [String] = [app.mapState.debugGraphPaintMode.title]
        if let hit = app.mapState.debugGraphHit {
            parts.append(hit.edgeId)
        } else if app.mapState.debugGraphCapped {
            parts.append("capped")
        }
        return parts.joined(separator: " · ")
    }

    /// Live graph responses expose only coarse access. Surface-family and road-tier
    /// controls appear only when the map is backed by an installed v3 pack.
    private var availableDebugGraphPaintModes: [DebugGraphPaintMode] {
        guard let region = GraphPackStore.primaryRegionId(containing: app.mapState.mapCenter),
              let pack = app.graphPacks.packIfInstalled(region.uppercased()),
              pack.hasLeaves
        else { return [.access] }
        return DebugGraphPaintMode.allCases
    }

    private func debugGraphLegend(for mode: DebugGraphPaintMode) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(PackDebugPaint.legend(for: mode), id: \.key) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(item.color))
                        .frame(width: 14, height: 4)
                        .overlay {
                            if item.dashed {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                            }
                        }
                    Text(item.label)
                        .font(.dirtMono(10))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
        }
    }

    /// Floating dark-glass bar inside the safe area: the map runs past it on every side,
    /// so the chrome reads as sitting *on* the map instead of cropping it.
    private var dock: some View {
        HStack(spacing: 4) {
            ForEach(DockTab.allCases) { tab in
                dockButton(tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, max(homeIndicatorInset, 10))
        .background(DirtTheme.navigationSurface)
        .shadow(color: .black.opacity(0.14), radius: 16, y: -4)
        .padding(.bottom, -homeIndicatorInset)

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
            case .open: .white
            case .armed: DirtTheme.orange
            case .idle: .white
            }
        }

        var fill: Color {
            switch self {
            case .open: DirtTheme.orange
            case .armed: .clear
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
        if let dockDestination {
            if dockDestination == tab { return .open }
        } else if isActive(tab) { return .open }
        if tab == .route, app.planner.hasRoute { return .armed }
        return .idle
    }

    private func toggleDockTab(_ tab: DockTab) {
        let closing = dockDestination == tab || isActive(tab)
        let hadSheet = routeCardOpen || activeSheet != nil
        dockTransitionTask?.cancel()
        withAnimation(reduceMotion ? nil : DirtMotion.dock) {
            dockDestination = closing ? nil : tab
        }
        withAnimation(reduceMotion ? nil : DirtMotion.sheetExit) {
            activeSheet = nil
            routeCardOpen = false
        }
        guard !closing else { return }
        dockTransitionTask = Task { @MainActor in
            if hadSheet && !reduceMotion {
                try? await Task.sleep(for: .milliseconds(210))
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : DirtMotion.sheet) {
                dockDestination = nil
                switch tab {
                case .route: routeCardOpen = true
                case .layers: activeSheet = .layers
                case .profile: activeSheet = .profile
                case .group: activeSheet = .group
                }
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
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return Button {
            toggleDockTab(tab)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 23, weight: .semibold))
                Text(tab.title)
                    .font(.dirtUI(12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(state.foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DirtHit.min)
            .padding(.vertical, 6)
            .background {
                if state == .open {
                    shape.fill(DirtTheme.orange).matchedGeometryEffect(id: "dock-selection", in: dockSelection)
                }
            }
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

/// Stored generation counters so MapLibre's UIViewRepresentable receives
/// `updateUIView` when Standard/Rich or overlay prefs change. Class-typed
/// `MapState` alone does not.
private struct MapLibreCanvas: View {
    var state: MapState
    var location: LocationService
    var overlayInsetsGeneration: Int
    var layerPrefsGeneration: Int
    var bcOSMOverlayGeneration: Int
    var styleURL: URL
    var styleGeneration: Int

    var body: some View {
        let _ = overlayInsetsGeneration
        let _ = layerPrefsGeneration
        let _ = bcOSMOverlayGeneration
        let _ = styleURL
        let _ = styleGeneration
        MapLibreMapView(state: state, location: location)
    }
}

/// Load entrance: wrapper grows down from the hardware Island, then `DIRT.` plops
/// into the settled bar. Reduce Motion fades; the wrapper never bounces off the cutout.
private struct IslandBrandBar: View {
    let graphDebugVisible: Bool
    let onToggleGraph: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wrapperRevealed = false
    @State private var wordmarkLanded = false

    private var wrapperShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DirtIsland.wrapperRadius, style: .continuous)
    }

    private var wrapperScale: CGFloat {
        if reduceMotion { return 1 }
        return wrapperRevealed ? 1 : DirtIsland.collapsedScaleY
    }

    private var barOpacity: Double {
        reduceMotion ? (wrapperRevealed ? 1 : 0) : 1
    }

    private var wordmarkOpacity: Double {
        if reduceMotion { return wrapperRevealed ? 1 : 0 }
        return wordmarkLanded ? 1 : 0
    }

    private var wordmarkScale: CGFloat {
        if reduceMotion { return 1 }
        return wordmarkLanded ? 1 : 0.88
    }

    private var wordmarkOffset: CGFloat {
        if reduceMotion { return 0 }
        return wordmarkLanded ? 0 : -10
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: DirtIsland.cutoutWidth, height: DirtIsland.cutoutHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Button(action: onToggleGraph) {
                BrandChip(sitsInIslandStack: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(graphDebugVisible ? "Hide surface network" : "Show surface network")
            .accessibilityHint("Shows or hides nearby road surfaces")
            .opacity(wordmarkOpacity)
            .scaleEffect(wordmarkScale, anchor: .top)
            .offset(y: wordmarkOffset)
            .allowsHitTesting(wordmarkLanded || reduceMotion)
        }
        .frame(minWidth: DirtIsland.cutoutWidth)
        .background(Color.black, in: wrapperShape)
        .clipShape(wrapperShape)
        .scaleEffect(x: 1, y: wrapperScale, anchor: .top)
        .opacity(barOpacity)
        .padding(.top, DirtIsland.cutoutTop)
        .ignoresSafeArea(edges: .top)
        .onAppear(perform: playEntrance)
    }

    private func playEntrance() {
        if reduceMotion {
            withAnimation(DirtMotion.islandFade) {
                wrapperRevealed = true
                wordmarkLanded = true
            }
            return
        }

        withAnimation(DirtMotion.islandGrow) {
            wrapperRevealed = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(DirtMotion.islandPlop) {
                wordmarkLanded = true
            }
        }
    }
}

private struct KeepAwakeLifecycle: ViewModifier {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { sync(scenePhase) }
            .onChange(of: scenePhase) { _, phase in sync(phase) }
            .onChange(of: app.navigation.phase) { _, _ in sync(scenePhase) }
    }

    private func sync(_ phase: ScenePhase) {
        KeepAwakePrefs.sync(
            sceneActive: phase == .active,
            navigating: app.navigation.phase == .active
        )
    }
}

struct ToastView: View {
    let text: String
    var isBuildingRoute = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hypeLineIndex = 0
    @State private var elapsedTwentySeconds = false
    private let waitingAccent = Color(dirtHex: 0xF3CF54)

    private var longBuildNotice: String? {
        isBuildingRoute && elapsedTwentySeconds
            ? RoutePlannerModel.longRouteBuildNotice : nil
    }

    private var rotatesHype: Bool {
        isBuildingRoute && RoutePlannerModel.usesRotatingBuildHype(for: text)
    }

    private var progress: RoutePlannerModel.ProgressToastContent? {
        if rotatesHype {
            let lines = RoutePlannerModel.routeBuildHypeLines
            guard !lines.isEmpty else { return nil }
            return lines[hypeLineIndex % lines.count]
        }
        return RoutePlannerModel.progressToastContent(for: text)
            ?? (isBuildingRoute ? RoutePlannerModel.routeBuildHypeLines.first : nil)
    }

    private var isSuccess: Bool {
        text == RoutePlannerModel.routeReadyToast
    }

    var body: some View {
        Group {
            if let progress {
                VStack(alignment: .leading, spacing: DirtSpace.tight) {
                    Text(progress.title)
                        .font(DirtType.rowTitle)
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                    Text(progress.detail)
                        .font(DirtType.helper)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    RouteBuildPistonIndicator()
                        .accessibilityHidden(true)
                    if let longBuildNotice {
                        Text(longBuildNotice)
                            .font(DirtType.helper)
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minWidth: 200, maxWidth: 240, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("route-progress-toast")
                .accessibilityLabel(progress.title)
                .accessibilityValue("\(progress.detail). In progress.\(longBuildNotice.map { " " + $0 } ?? "")")
                .accessibilityAddTraits(.updatesFrequently)
                .task(id: isBuildingRoute) {
                    elapsedTwentySeconds = false
                    guard isBuildingRoute else { return }
                    do { try await Task.sleep(for: .seconds(20)) }
                    catch { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        elapsedTwentySeconds = true
                    }
                }
                .task(id: "\(text)-\(rotatesHype)-\(reduceMotion)") {
                    hypeLineIndex = 0
                    guard rotatesHype, !reduceMotion else { return }
                    let lineCount = RoutePlannerModel.routeBuildHypeLines.count
                    guard lineCount > 1 else { return }
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(2_400))
                        } catch {
                            return
                        }
                        withAnimation(.easeInOut(duration: 0.28)) {
                            hypeLineIndex = (hypeLineIndex + 1) % lineCount
                        }
                    }
                }
            } else {
                Text(text)
                    .font(.dirtUI(12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, progress == nil ? 10 : 12)
        .background {
            (isSuccess ? DirtTheme.navGreen : DirtTheme.chrome).opacity(0.95)
                .overlay(waitingAccent.opacity(longBuildNotice == nil ? 0 : 0.10))
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: progress == nil ? 100 : DirtRadius.card,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: progress == nil ? 100 : DirtRadius.card,
                style: .continuous
            )
            .stroke(
                longBuildNotice != nil ? waitingAccent
                    : isSuccess ? DirtTheme.navGreen.opacity(0.9) : DirtTheme.chromeBorder,
                lineWidth: longBuildNotice == nil ? 1 : 2
            )
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .transition(.opacity)
    }
}

/// Brand motion for route construction. This deliberately communicates activity,
/// not measured completion: a quick power stroke followed by a slower return.
private struct RouteBuildPistonIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: CGFloat = 0.16

    var body: some View {
        Capsule(style: .continuous)
            .fill(.white.opacity(0.12))
            .frame(height: 6)
            .overlay {
                Capsule(style: .continuous)
                    .fill(DirtTheme.orange)
                    .scaleEffect(x: fill, y: 1, anchor: .leading)
            }
            .clipShape(Capsule(style: .continuous))
            .task(id: reduceMotion) {
                fill = reduceMotion ? 0.58 : 0.16
                guard !reduceMotion else { return }

                while !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.30)) {
                        fill = 1
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(360))
                    } catch {
                        return
                    }

                    withAnimation(.easeInOut(duration: 0.92)) {
                        fill = 0.16
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(980))
                    } catch {
                        return
                    }
                }
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
            detailRow(label: "Location", value: peer.placeLabel)

            Spacer(minLength: 0)

            Button("Route to rider", action: onRoute)
                .buttonStyle(DirtCTAStyle.brand())
        }
        .padding(DirtSpace.group)
        .dirtGroupingSurface(radius: DirtRadius.card)
        .padding(DirtSpace.inner)
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
