import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Route planner, redesigned to the Figma screens page:
/// orange tab bar → mode chips → numbered stage rows (per-stage mode +
/// unknown-access policy) → stat chips + mix bar → icon CTAs → Clear All.
/// Open/close via the dock Route tab (no grab handle).
struct RoutePlannerCard: View {
    @Binding var isOpen: Bool
    /// When true, wash chrome extends under the sticky dock (content clears it).
    var sitsBehindDock: Bool = false
    /// Figma landscape-primary side drawer. `true` = dock leading; `false` = dock trailing.
    var landscapeDockLeading: Bool? = nil
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var modelContext

    @State private var showSaveDialog = false
    @State private var saveName = ""
    /// GPX share sheet — only presented after the export gate allows it.
    @State private var exportShareURL: URL?
    /// Pending unknown-access confirmation. `nil` target = From-here (global).
    @State private var unknownAckStage: Int?
    @State private var showUnknownAck = false
    /// Stage whose mode the chips edit (Plan tab). Nil = chips collapsed.
    @State private var selectedStage: Int?
    /// From here: same expand/collapse as a single Plan stage (no delete).
    @State private var fromHereChipsOpen = false
    @State private var showFromHereToPlanConfirm = false
    @State private var showPlanToFromHereConfirm = false
    @State private var showClearConfirm = false
    @State private var showFuelGapStartConfirm = false

    private var planner: RoutePlannerModel { app.planner }

    private var isUpdatingSavedRoute: Bool {
        if case .update = planner.saveAffordance { return true }
        return false
    }

    /// Multi-stage or fuel-assisted plans — confirm before wipe.
    private var shouldConfirmClear: Bool {
        planner.stages.count > 1 || planner.stages.contains(where: \.endsAtFuelStop)
    }

    var body: some View {
        Group {
            if let dockLeading = landscapeDockLeading {
                landscapeShell(dockLeading: dockLeading)
            } else {
                portraitShell
            }
        }
        .alert("Unknown access is not permission", isPresented: $showUnknownAck) {
            Button("I understand — continue", role: .destructive) {
                if let index = unknownAckStage {
                    planner.setStageAllowUnknown(true, at: index)
                } else {
                    planner.allowUnknown = true
                }
                unknownAckStage = nil
            }
            Button("Cancel", role: .cancel) { unknownAckStage = nil }
        } message: {
            Text("Unknown-access routing may include branch lines that are unverified for motorcycles. That is not legal permission and may expose you to closures, private land, seasonal restrictions, or enforcement.")
        }
        .alert(isUpdatingSavedRoute ? "Update saved route" : "Save route", isPresented: $showSaveDialog) {
            TextField("Route name", text: $saveName)
            Button(isUpdatingSavedRoute ? "Update" : "Save") {
                planner.saveRoute(named: saveName, context: modelContext)
                saveName = ""
            }
            if isUpdatingSavedRoute {
                // Escape hatch: keep the original line and file today's edit separately.
                Button("Save as new") {
                    planner.saveRoute(named: saveName, context: modelContext, forceNew: true)
                    saveName = ""
                }
            }
            Button("Cancel", role: .cancel) { saveName = "" }
        } message: {
            if case .update(let name) = planner.saveAffordance {
                Text("Replaces “\(name)” with your edits.")
            }
        }
        .sheet(isPresented: Binding(
            get: { exportShareURL != nil },
            set: { if !$0 { exportShareURL = nil } }
        )) {
            if let url = exportShareURL {
                DirtShareSheet(items: [url])
            }
        }
        .onChange(of: app.trial.isSubscribed) { _, subscribed in
            guard subscribed, let reason = app.trial.takePendingReason() else { return }
            resumeAfterSubscribe(reason)
        }
        .confirmationDialog(
            "Switch to Plan a route?",
            isPresented: $showFromHereToPlanConfirm,
            titleVisibility: .visible
        ) {
            Button("Keep") {
                selectedStage = nil
                fromHereChipsOpen = false
                planner.switchToPlanKeepingFromHere()
            }
            Button("Clear", role: .destructive) {
                selectedStage = nil
                fromHereChipsOpen = false
                planner.switchToPlanClearing()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep this as stage 1, or clear it and start fresh.")
        }
        .confirmationDialog(
            "Switch to From here?",
            isPresented: $showPlanToFromHereConfirm,
            titleVisibility: .visible
        ) {
            Button("Use last pin") {
                selectedStage = nil
                fromHereChipsOpen = false
                planner.switchToFromHereUsingLastPin()
            }
            Button("Start anew", role: .destructive) {
                selectedStage = nil
                fromHereChipsOpen = false
                planner.switchToFromHereClearing()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use the last pin as your destination, or clear the plan.")
        }
        .confirmationDialog(
            "Clear this route?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { performClear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes pins, fuel stops, and the line on the map.")
        }
        .confirmationDialog(
            "Fuel gap on this route",
            isPresented: $showFuelGapStartConfirm,
            titleVisibility: .visible
        ) {
            Button("Review fuel gap") {
                if let gap = planner.unacknowledgedFuelGaps.first,
                   let legIndex = planner.itinerary.legs.firstIndex(where: { leg in
                       if case .gap(let candidate) = planner.built?.riderLegStatus[leg.id] {
                           return candidate.id == gap.id
                       }
                       return false
                   }) {
                    planner.focusStage(at: planner.stages.firstIndex(where: {
                        $0.riderLegID == planner.itinerary.legs[legIndex].id
                    }) ?? 0)
                }
            }
            Button("Continue without acknowledging", role: .destructive) {
                beginNavigation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(planner.unacknowledgedFuelGaps.first?.message ?? "Fuel continuity is not proven for part of this route.")
        }
    }

    private func performClear() {
        planner.clearRoute()
        selectedStage = nil
        fromHereChipsOpen = false
    }

    // MARK: - Portrait shell

    private var portraitShell: some View {
        VStack(spacing: 10) {
            expandedPlannerContent
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, sitsBehindDock ? DockSheetMotion.dockClearance : 14)
        .frame(maxWidth: .infinity)
        .clipShape(portraitSurfaceShape)
        // Surface only — the material runs past the home indicator so the sheet reads
        // as coming from the bottom edge, with the dock floating on top of it.
        .background(alignment: .top) {
            portraitSurfaceShape
                .fill(DirtTheme.sheetMaterial)
                .overlay(portraitSurfaceShape.stroke(DirtTheme.hairline, lineWidth: 1))
                .shadow(
                    color: sitsBehindDock ? .clear : .black.opacity(0.18),
                    radius: sitsBehindDock ? 0 : 14,
                    y: sitsBehindDock ? 0 : -2
                )
                .ignoresSafeArea(edges: sitsBehindDock ? .bottom : [])
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: PlannerSheetHeightKey.self, value: geo.size.height)
            }
        }
    }

    private var portraitSurfaceShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: DirtRadius.sheet,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: DirtRadius.sheet,
            style: .continuous
        )
    }

    // MARK: - Landscape shell (Figma landscape-primary)

    private func landscapeShell(dockLeading: Bool) -> some View {
        GeometryReader { geo in
            // Half screen including the strip under the dock.
            let panelW = geo.size.width * DockSheetMotion.landscapeMaxDrawerFraction
            let dockW = DockSheetMotion.landscapeDockWidth

            HStack(spacing: 0) {
                if dockLeading {
                    landscapeDrawer(dockLeading: true, width: panelW, dockClearance: dockW)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    landscapeDrawer(dockLeading: false, width: panelW, dockClearance: dockW)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func landscapeDrawer(dockLeading: Bool, width: CGFloat, dockClearance: CGFloat) -> some View {
        VStack(spacing: 10) {
            expandedPlannerContent
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.leading, dockLeading ? dockClearance + 10 : 14)
        .padding(.trailing, dockLeading ? 14 : dockClearance + 10)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(DirtTheme.sheetMaterial, in: landscapeSurfaceShape(dockLeading: dockLeading))
        .overlay(landscapeSurfaceShape(dockLeading: dockLeading).stroke(DirtTheme.hairline, lineWidth: 1))
        .clipShape(landscapeSurfaceShape(dockLeading: dockLeading))
        .shadow(color: .black.opacity(0.22), radius: 18, x: dockLeading ? 8 : -8, y: 0)
    }

    private func landscapeSurfaceShape(dockLeading: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: dockLeading ? 0 : DirtRadius.card,
            bottomLeadingRadius: dockLeading ? 0 : DirtRadius.card,
            bottomTrailingRadius: dockLeading ? DirtRadius.card : 0,
            topTrailingRadius: dockLeading ? DirtRadius.card : 0,
            style: .continuous
        )
    }

    @ViewBuilder
    private var expandedPlannerContent: some View {
        tabBar
        switch planner.mode {
        case .fromHere:
            fromHereContent
        case .plan:
            planContent
        case .saved:
            savedContent
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(RoutePlannerModel.Mode.allCases) { mode in
                Button {
                    requestMode(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(DirtType.rowTitle)
                        // Unselected labels sit straight on the orange track, so they
                        // carry ink too; the white pill and weight mark the selection.
                        .fontWeight(planner.mode == mode ? .bold : .semibold)
                        .foregroundStyle(planner.mode == mode ? DirtTheme.ink : DirtTheme.onOrange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: DirtHit.min)
                        .background(
                            planner.mode == mode
                                ? AnyShapeStyle(.white)
                                : AnyShapeStyle(.clear)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(
                            color: planner.mode == mode ? .black.opacity(0.12) : .clear,
                            radius: 1,
                            y: 1
                        )
                }
            }
        }
        .padding(2)
        .background(DirtTheme.orange)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Confirm before abandoning a From here pin or a multi-stage plan.
    private func requestMode(_ mode: RoutePlannerModel.Mode) {
        guard mode != planner.mode else { return }
        if planner.mode == .fromHere, mode == .plan, planner.hasFromHereDraft {
            showFromHereToPlanConfirm = true
            return
        }
        if planner.mode == .plan, mode == .fromHere, planner.hasPlanDraft {
            showPlanToFromHereConfirm = true
            return
        }
        selectedStage = nil
        fromHereChipsOpen = false
        planner.selectMode(mode)
    }

    // MARK: - From here

    @ViewBuilder private var fromHereContent: some View {
        if planner.hasRoute {
            if planner.hasFuelAssistedPlan {
                stageList
            } else {
                StageCard(
                    number: 1,
                    profileTitle: planner.profile.title,
                    isActive: fromHereChipsOpen,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.18)) { fromHereChipsOpen.toggle() }
                    },
                    headline: {
                        stageMetrics(
                            km: planner.totalMeters / 1000,
                            dirtPercent: planner.aggregateDirtPercent,
                            margin: nil,
                            showsWarning: false
                        )
                    },
                    detail: {
                        VStack(alignment: .leading, spacing: DirtSpace.inner) {
                            profileSegments(active: planner.profile) { profile in
                                planner.profile = profile
                                withAnimation(.easeInOut(duration: 0.18)) { fromHereChipsOpen = false }
                            }
                            profileGuidanceLine(planner.profile)
                            profilePolicyToggle(
                                profile: planner.profile,
                                allowUnknown: Binding(
                                    get: { planner.allowUnknown },
                                    set: { on in
                                        if on {
                                            unknownAckStage = nil
                                            showUnknownAck = true
                                        } else {
                                            planner.allowUnknown = false
                                        }
                                    }
                                ),
                                avoidMotorways: Binding(
                                    get: { planner.avoidMotorways },
                                    set: { planner.avoidMotorways = $0 }
                                )
                            )
                        }
                    }
                )
            }

            routingStatus
            ferryNotice
            statsRow
            ctaRow
            clearAllButton
        } else {
            fromHereProfileHeader
            if fromHereChipsOpen {
                profilePolicyToggle(
                    profile: planner.profile,
                    allowUnknown: Binding(
                        get: { planner.allowUnknown },
                        set: { on in
                            if on {
                                unknownAckStage = nil
                                showUnknownAck = true
                            } else {
                                planner.allowUnknown = false
                            }
                        }
                    ),
                    avoidMotorways: Binding(
                        get: { planner.avoidMotorways },
                        set: { planner.avoidMotorways = $0 }
                    )
                )
            }
            fromHereGuidanceAndRecovery
        }
    }

    @ViewBuilder private var fromHereProfileHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if fromHereChipsOpen {
                profileSegments(active: planner.profile) { profile in
                    planner.profile = profile
                    withAnimation(.easeInOut(duration: 0.18)) { fromHereChipsOpen = false }
                }
            } else {
                profileEyebrow(planner.profile) {
                    withAnimation(.easeInOut(duration: 0.18)) { fromHereChipsOpen = true }
                }
            }
            profileGuidanceLine(planner.profile)
        }
    }

    /// Empty / error From here — always leave a next step (never red text alone).
    @ViewBuilder private var fromHereGuidanceAndRecovery: some View {
        routingStatus
        if !planner.isRouting {
            if planner.fromHereNeedsStartPin {
                helperBox("Tap a mapped road near you for point 1. Point 2 stays where you put it.")
            } else if planner.errorMessage != nil {
                helperBox(fromHereRecoveryHint)
                if planner.destination != nil {
                    Button {
                        planner.retryFromHere()
                    } label: {
                        Text("Try again")
                            .font(DirtType.cta)
                            .foregroundStyle(DirtTheme.orange)
                            .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                            .background(DirtTheme.rowFill)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(DirtTheme.orange.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            } else {
                helperBox("Tap to drop point 2, or long-press a road to place/move point 2 (snaps to the nearest road).")
            }
        }
    }

    private var fromHereRecoveryHint: String {
        let msg = (planner.errorMessage ?? "").lowercased()
        if msg.contains("point b") || msg.contains("point 2") || msg.contains("nudge b") {
            return "Long-press a road to move point 2 onto the centerline, then try again."
        }
        if msg.contains("snap") || msg.contains("nudge") || msg.contains("centerline") || msg.contains("roadway") {
            return "Long-press a road to move point 2 onto the centerline, then try again."
        }
        if msg.contains("same junction") || msg.contains("farther along") {
            return "Move point 2 farther along the road, then try again."
        }
        if msg.contains("mapped road") || msg.contains("set a") || msg.contains("set point 1") || msg.contains("set your start") || msg.contains("your start") {
            return "Tap a mapped road near you for point 1. Point 2 stays where you put it."
        }
        if msg.contains("fuel-safe route") {
            return "Try again. If it repeats, choose Balanced for this leg or move point 2 closer."
        }
        return "Try another profile (tap Balanced), turn on Allow unknown, or long-press to move point 2."
    }

    // MARK: - Plan

    @ViewBuilder private var planContent: some View {
        // Mode chips live per-stage (tap a stage to expand). Hide the top row
        // until the first stage exists so empty Plan stays clean.
        if planner.stages.isEmpty {
            VStack(spacing: 8) {
                helperBox("Long-press the map for point 1, then again for point 2 to build your first leg.")
                GPXImportButton(continueAsPlan: true)
            }
        } else {
            stageList
        }

        routingStatus

        if planner.hasRoute {
            ferryNotice
            statsRow
            ctaRow
            clearAllButton
        } else if !planner.stages.isEmpty {
            clearAllButton
        }
    }

    // MARK: - Saved

    @ViewBuilder private var savedContent: some View {
        if planner.hasRoute {
            loadedTrackCard
            ferryNotice
            ctaRow
            continuePlanningButton
            clearAllButton
        } else {
            SavedRoutesList(showImport: true)
        }
    }

    /// The loaded track in one card: name, mix figures, and the bar — replacing the
    /// name line, the instructional paragraph, and the full stat-chip row.
    private var loadedTrackCard: some View {
        let dirt = max(0, min(100, planner.aggregateDirtPercent))
        return VStack(alignment: .leading, spacing: DirtSpace.tight) {
            HStack(spacing: DirtSpace.tight) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DirtTheme.orange)
                Text(loadedTrackName)
                    .font(DirtType.rowTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: DirtSpace.tight) {
                Text(String(format: "%.1f km", planner.totalMeters / 1000))
                    .foregroundStyle(DirtTheme.ink)
                Text("·").foregroundStyle(DirtTheme.muted)
                Text("\(dirt)% dirt")
                    .foregroundStyle(DirtTheme.dirtMix)
                Text("·").foregroundStyle(DirtTheme.muted)
                Text("\(planner.aggregatePavedPercent)% paved")
                    .foregroundStyle(DirtTheme.pavedMix)
                Spacer(minLength: 0)
            }
            .font(DirtType.metricInline)
            .fontWeight(.bold)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            // The text stays Dirt/Paved; the line preserves the honest
            // paved/gravel/loose/unknown composition.
            SurfaceMixBar(
                composition: planner.surfaceComposition,
                height: 6,
                showsLabels: false
            )
        }
        .padding(DirtSpace.inner)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(loadedTrackName), \(String(format: "%.1f", planner.totalMeters / 1000)) kilometers, \(dirt) percent dirt"
        )
    }

    private var loadedTrackName: String {
        if let name = planner.destinationName, !name.isEmpty { return name }
        return "Loaded track"
    }

    /// Secondary to Start: the button name carries what the old helper paragraph explained.
    private var continuePlanningButton: some View {
        Button {
            selectedStage = 0
            _ = planner.continuePlanningFromSavedTrack()
        } label: {
            Label("Continue planning", systemImage: "arrow.triangle.branch")
                .font(DirtType.cta)
                .foregroundStyle(DirtTheme.orange)
                .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DirtTheme.orange.opacity(0.45), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Keeps this line and lets you add more waypoints")
    }

    @ViewBuilder private var stageList: some View {
        // Native List owns horizontal gesture arbitration: a left swipe reveals
        // Delete without opening the profile disclosure or moving the map.
        let bandHeight: CGFloat = selectedStage == nil ? 210 : 280
        let visibleRows = planner.stages.count
        let collapsedHeight = min(
            bandHeight,
            max(62, CGFloat(max(1, visibleRows)) * 70)
        )
        ScrollViewReader { proxy in
            List {
                stageListContent
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowSpacing(10)
            .frame(height: selectedStage == nil ? collapsedHeight : bandHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            .onAppear {
                if let last = planner.itinerary.legs.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onChange(of: planner.itinerary.legs.count) {
                guard let last = planner.itinerary.legs.last?.id else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onChange(of: selectedStage) {
                guard let index = selectedStage, planner.stages.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(planner.stages[index].riderLegID, anchor: .bottom)
                }
            }
        }
    }

    private func scrollToNewestStage(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = planner.stages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    /// Keep an expanding stage in view — its detail is taller than the collapsed row.
    private func revealSelectedStage(_ proxy: ScrollViewProxy) {
        guard let index = selectedStage, planner.stages.indices.contains(index) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(planner.stages[index].id, anchor: .bottom)
        }
    }

    @ViewBuilder private var stageListContent: some View {
        ForEach(Array(planner.stages.enumerated()), id: \.element.id) { stageIndex, stage in
            stageBlock(index: stageIndex, stage: stage)
                .id(stage.id)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if planner.canDeleteStage(at: stageIndex),
                       let riderLegIndex = planner.itinerary.legs.firstIndex(where: {
                           $0.id == stage.riderLegID
                       }),
                       planner.itinerary.waypoints.indices.contains(riderLegIndex + 1) {
                        Button(role: .destructive) {
                            let waypointID = planner.itinerary.waypoints[riderLegIndex + 1].id
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedStage = nil
                                planner.apply(.delete(waypointID: waypointID), source: "swipe")
                            }
                        } label: {
                            Label("Delete", systemImage: "trash.fill")
                        }
                        .accessibilityLabel("Delete point \(riderLegIndex + 2)")
                    }
                }
        }
    }

    /// One self-contained stage: metrics + profile control on a single tappable row,
    /// with the profile options revealing *inside* the same card so the grouping reads.
    @ViewBuilder private func stageBlock(index: Int, stage: RoutePlannerModel.Stage) -> some View {
        let isActive = selectedStage == index
        StageCard(
            number: index + 1,
            profileTitle: stage.profile.title,
            isActive: isActive,
            onToggle: { toggleStageSelection(index) },
            endpointTitle: planner.stageEndpointTitle(at: index),
            endpointIsFuelStation: planner.stageEndpointIsFuelStation(at: index),
            viaSubtitle: planner.stageFuelStationSubtitle(at: index),
            headline: { stageHeadline(stage, at: index) },
            detail: {
                VStack(alignment: .leading, spacing: DirtSpace.inner) {
                    if let notice = planner.profileAvailabilityNotice(at: index) {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(DirtType.helper)
                            .foregroundStyle(DirtTheme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if stage.endsAtFuelStop, planner.canReplaceFuelStop(at: index) {
                        Button {
                            planner.selectFuelWaypoint(at: index)
                        } label: {
                            Label("Choose another pump", systemImage: "fuelpump.circle.fill")
                                .font(DirtType.chip)
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DirtTheme.orange)
                        .background(DirtTheme.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    profileSegments(active: stage.profile) { profile in
                        planner.setFuelHopProfile(profile, at: index)
                        withAnimation(.easeInOut(duration: 0.18)) { selectedStage = nil }
                    }
                    profileGuidanceLine(stage.profile)
                    profilePolicyToggle(
                        profile: stage.profile,
                        allowUnknown: Binding(
                            get: { stage.allowUnknown },
                            set: { on in
                                if on {
                                    unknownAckStage = index
                                    showUnknownAck = true
                                } else {
                                    planner.setStageAllowUnknown(false, at: index)
                                }
                            }
                        ),
                        avoidMotorways: Binding(
                            get: { stage.avoidMotorways },
                            set: { planner.setStageAvoidMotorways($0, at: index) }
                        )
                    )
                    if stage.error != nil, stage.profile != .cleanest {
                        Button {
                            planner.setFuelHopProfile(.cleanest, at: index)
                        } label: {
                            Label(
                                "Use Clean for this leg",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(DirtType.chip)
                            .fontWeight(.bold)
                            .foregroundStyle(DirtTheme.orange)
                            .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                            .background(DirtTheme.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        )
    }

    /// Left side of a stage row: metrics once routed, state text before that.
    @ViewBuilder private func stageHeadline(_ stage: RoutePlannerModel.Stage, at index: Int) -> some View {
        if stage.isRouting {
            Text("Pending…")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
        } else if let gap = stage.fuelGap {
            Label(gap.message, systemImage: "fuelpump.slash.fill")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.orange)
                .lineLimit(3)
        } else if let unknown = stage.fuelUnknown {
            Label(unknown, systemImage: "questionmark.circle.fill")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.orange)
                .lineLimit(3)
        } else if let error = stage.error {
            Text(error)
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.danger)
                .lineLimit(2)
        } else if let response = stage.response {
            stageMetrics(
                km: (response.distanceMeters ?? 0) / 1000,
                dirtPercent: response.dirtPercent,
                margin: planner.fuelMarginText(at: index),
                showsWarning: planner.profileAvailabilityNotice(at: index) != nil,
                includesFerry: RouteFerrySummary.from(responses: [response]).hasCrossing
            )
        } else {
            Text(stage.end == nil ? "Hold the map to set the end" : "Waiting for route…")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .lineLimit(2)
        }
    }

    /// One evidence line: distance, surface mix, reserve margin, then warning.
    private func stageMetrics(
        km: Double,
        dirtPercent: Int,
        margin: String?,
        showsWarning: Bool,
        includesFerry: Bool = false
    ) -> some View {
        HStack(spacing: DirtSpace.tight) {
            Text(String(format: "%.1f km", km))
                .font(DirtType.metricInline)
                .fontWeight(.bold)
                .foregroundStyle(DirtTheme.ink)
            Text("·")
                .font(DirtType.metricInline)
                .foregroundStyle(DirtTheme.muted)
            Text("\(dirtPercent)% dirt")
                .font(DirtType.metricInline)
                .fontWeight(.bold)
                .foregroundStyle(DirtTheme.dirtMix)
            if includesFerry {
                Text("·")
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.muted)
                Label("Ferry", systemImage: "ferry.fill")
                    .font(DirtType.metricInline)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.routeFerry)
            }
            if let margin {
                Text("·")
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.muted)
                Text(margin)
                    .font(DirtType.metricInline)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.muted)
            }
            if showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.orange)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }

    @ViewBuilder private var ferryNotice: some View {
        let summary = planner.ferrySummary
        if summary.hasCrossing {
            HStack(alignment: .top, spacing: DirtSpace.inner) {
                Image(systemName: "ferry.fill")
                    .font(.system(.headline, weight: .bold))
                    .foregroundStyle(DirtTheme.routeFerry)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                    Text(summary.crossingCount == 1
                         ? "Ferry crossing included"
                         : "\(summary.crossingCount) ferry crossings included")
                        .font(DirtType.rowTitle)
                        .foregroundStyle(DirtTheme.ink)
                    Text(ferryNoticeDetail(summary))
                        .font(DirtType.helper)
                        .foregroundStyle(DirtTheme.ink.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DirtSpace.inner)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DirtTheme.routeFerry.opacity(0.10),
                in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                    .stroke(DirtTheme.routeFerry.opacity(0.30), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ferry-route-notice")
        }
    }

    private func ferryNoticeDetail(_ summary: RouteFerrySummary) -> String {
        let crossingDistance = summary.distanceMeters / 1000
        let distanceText = crossingDistance >= 1
            ? "About \(Int(crossingDistance.rounded())) km by ferry. "
            : ""
        return distanceText
            + "Check departure times, seasonal service, and motorcycle boarding before you ride."
    }

    /// Equal-width profile segments. Reads as one control instead of three loose pills.
    private func profileSegments(
        active: RouteProfile,
        onSelect: @escaping (RouteProfile) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(RouteProfile.allCases) { profile in
                Button {
                    onSelect(profile)
                } label: {
                    Text(profile.title)
                        .font(DirtType.chip)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(active == profile ? DirtTheme.onOrange : DirtTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DirtHit.min)
                        .background(active == profile ? DirtTheme.orange : DirtTheme.wash)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(
                                    active == profile
                                        ? DirtTheme.onOrange.opacity(0.25)
                                        : DirtTheme.hairline,
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active == profile ? [.isSelected] : [])
            }
        }
    }

    /// Collapsed profile label — used only by the From here empty state, which has no stage row yet.
    private func profileEyebrow(_ profile: RouteProfile, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(profile.title)
                    .font(DirtType.rowTitle)
                    .fontWeight(.bold)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(DirtTheme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: DirtHit.min)
            .background(DirtTheme.rowFill)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(DirtTheme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.title) mode. Tap to change.")
        .accessibilityHint("Opens route mode options")
    }

    private func toggleStageSelection(_ index: Int) {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedStage = selectedStage == index ? nil : index
        }
        if selectedStage == index {
            planner.focusStage(at: index)
        }
    }

    // MARK: - Shared rows

    private func profileGuidanceLine(_ profile: RouteProfile) -> some View {
        Text(profile.guidance)
            .font(.dirtUI(11))
            .foregroundStyle(DirtTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    /// Lives in the expanded profile band — not on the dense stage metrics row.
    /// Fuel-leg details stay to two compact control rows: profile and access.
    /// The full legal explanation was already acknowledged when Allow was enabled.
    private func compactAllowUnknownControl(
        stage: RoutePlannerModel.Stage,
        index: Int
    ) -> some View {
        HStack(spacing: DirtSpace.tight) {
            Text(stage.profile == .cleanest ? "Unknown access off for Clean" : "Allow unknown access")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Toggle(
                "",
                isOn: Binding(
                    get: { stage.allowUnknown },
                    set: { on in
                        if on {
                            unknownAckStage = index
                            showUnknownAck = true
                        } else {
                            planner.setStageAllowUnknown(false, at: index)
                        }
                    }
                )
            )
            .labelsHidden()
            .tint(DirtTheme.orange)
            .disabled(stage.profile == .cleanest)
            .opacity(stage.profile == .cleanest ? 0.4 : 1)
        }
        .padding(.horizontal, DirtSpace.inner)
        .frame(maxWidth: .infinity, minHeight: DirtHit.min)
        .background(DirtTheme.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func allowUnknownControl(
        binding: Binding<Bool>,
        disabled: Bool,
        profile: RouteProfile
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Allow unknown")
                    .font(.dirtUI(13, weight: .semibold))
                    .foregroundStyle(DirtTheme.ink)
                Spacer(minLength: 0)
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .tint(DirtTheme.orange)
                    .disabled(disabled)
                    .opacity(disabled ? 0.4 : 1)
            }
            Text(allowUnknownFootnote(disabled: disabled, profile: profile))
                .font(.dirtUI(11))
                .foregroundStyle(DirtTheme.muted)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirtTheme.rowFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
    }

    /// Exactly one rider toggle per profile.
    /// Clean: allow motorway/trunk/primary at ordinary paved-road cost.
    /// Dirt / Balanced: Allow unknown.
    @ViewBuilder
    private func profilePolicyToggle(
        profile: RouteProfile,
        allowUnknown: Binding<Bool>,
        avoidMotorways: Binding<Bool>
    ) -> some View {
        if profile == .cleanest {
            e4ToggleRow(
                title: "Allow major highways",
                footnote: "Off favours secondary roads and avoids major highways and cities.",
                binding: Binding(
                    get: { !avoidMotorways.wrappedValue },
                    set: { avoidMotorways.wrappedValue = !$0 }
                )
            )
        } else {
            allowUnknownControl(
                binding: allowUnknown,
                disabled: false,
                profile: profile
            )
        }
    }

    private func e4ToggleRow(
        title: String,
        footnote: String,
        binding: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.dirtUI(13, weight: .semibold))
                    .foregroundStyle(DirtTheme.ink)
                Spacer(minLength: 0)
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .tint(DirtTheme.orange)
            }
            Text(footnote)
                .font(.dirtUI(11))
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirtTheme.rowFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
    }

    private func allowUnknownFootnote(disabled: Bool, profile: RouteProfile) -> String {
        if disabled || profile == .cleanest {
            return "Off for Clean — pavement-first routing."
        }
        return "OSM dirt and track stay on. This only opens unproven paths (purple Access) — not a legal permission."
    }

    @ViewBuilder private var routingStatus: some View {
        if planner.fuelPlanningStatus != nil || planner.isRouting {
            EmptyView()
        } else if let error = planner.errorMessage {
            Text(error)
                .font(.dirtUI(12, weight: .semibold))
                .foregroundStyle(DirtTheme.danger)
                .multilineTextAlignment(.center)
        } else if !planner.packRoutingWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(planner.packRoutingWarnings) { warning in
                    Text(warning.message)
                        .font(.dirtUI(12, weight: .semibold))
                        .foregroundStyle(DirtTheme.muted)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func helperBox(_ text: String) -> some View {
        Text(text)
            .font(.dirtUI(12.5))
            .foregroundStyle(DirtTheme.ink.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(DirtTheme.rowFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DirtTheme.hairline, lineWidth: 1)
            )
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 14) {
            statChip(String(format: "%.1f", planner.totalMeters / 1000), label: "KM", color: DirtTheme.ink)
            statChip("\(planner.aggregateDirtPercent)%", label: "DIRT", color: DirtTheme.dirtMix)
            statChip("\(planner.aggregatePavedPercent)%", label: "PAVED", color: DirtTheme.pavedMix)
            mixBar
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statChip(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                // +30% over prior 17pt mono values.
                .font(.dirtMono(22, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.dirtUI(9, weight: .heavy))
                .foregroundStyle(DirtTheme.muted)
        }
        .padding(8)
        .background(DirtTheme.rowFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var mixBar: some View {
        SurfaceMixBar(composition: planner.surfaceComposition)
    }

    // MARK: - CTAs

    private var ctaRow: some View {
        // Figma: Save 103.5 · Export 142 · Start 103.5 on a 365pt row.
        // Equal thirds squish Export — pull 8pt from Save and Start each.
        GeometryReader { geo in
            let gap: CGFloat = 8
            let affordance = planner.saveAffordance
            let showsSave = affordance != .alreadySaved
            let unit = max(geo.size.width - gap * 2, 0) / 3
            // A route opened from the library is already saved, so the row drops to
            // Export + a wider Start rather than offering a duplicate.
            let pair = max(geo.size.width - gap, 0)

            HStack(spacing: gap) {
                if showsSave {
                    Button {
                        beginSave(affordance)
                    } label: {
                        ctaLabel(
                            affordance == .create ? "SAVE" : "UPDATE",
                            icon: "square.and.arrow.down",
                            fill: DirtTheme.chrome
                        )
                    }
                    .frame(width: max(unit - 8, 0))
                }

                exportCTA
                    .frame(width: showsSave ? max(unit + 16, 0) : pair * 0.42)

                Button {
                    requestStart()
                } label: {
                    ctaLabel("START", icon: "play.fill", fill: DirtTheme.navGreen)
                }
                .frame(width: showsSave ? max(unit - 8, 0) : pair * 0.58)
            }
        }
        .frame(height: 44)
    }

    @ViewBuilder private var exportCTA: some View {
        Button {
            requestExport()
        } label: {
            ctaLabel("EXPORT GPX", icon: "doc.badge.arrow.up", fill: DirtTheme.exportGray)
                .opacity(planner.hasRoute ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!planner.hasRoute)
    }

    /// Prefill the field when updating so the rider can see — and rename — the record
    /// they're about to overwrite.
    private func beginSave(_ affordance: RoutePlannerModel.SaveAffordance) {
        guard app.trial.requestSave() else { return }
        if case .update(let name) = affordance, saveName.isEmpty {
            saveName = name
        }
        showSaveDialog = true
    }

    private func requestExport() {
        guard app.trial.requestExport() else { return }
        guard let url = planner.gpxFileURL() else { return }
        exportShareURL = url
    }

    private func requestStart() {
        guard app.trial.requestStart() else { return }
        if !planner.unacknowledgedFuelGaps.isEmpty {
            showFuelGapStartConfirm = true
            return
        }
        beginNavigation()
    }

    private func beginNavigation() {
        isOpen = false
        planner.startNavigation()
    }

    private func resumeAfterSubscribe(_ reason: PaywallReason) {
        switch reason {
        case .save:
            beginSave(planner.saveAffordance)
        case .export:
            requestExport()
        case .start:
            requestStart()
        }
    }

    private func ctaLabel(_ title: String, icon: String, fill: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
            Text(title)
                .font(.dirtUI(12, weight: .heavy))
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var clearAllButton: some View {
        Button {
            if shouldConfirmClear {
                showClearConfirm = true
            } else {
                performClear()
            }
        } label: {
            Text("Clear route")
                .font(DirtType.cta)
                .foregroundStyle(DirtTheme.danger)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DirtTheme.danger, lineWidth: 1.5)
                )
                // Outline-only, so nothing fills the box: without this the tap
                // target collapses to the glyphs of "Clear All".
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // 16pt below Save / Export / Start; sheet height grows with content.
        .padding(.top, 16)
        .accessibilityLabel("Clear route")
    }
}

/// Document picker + share-sheet entry for GPX tracks.
struct GPXImportButton: View {
    /// When true (Plan empty state), import lands as Plan stage 1 so the rider
    /// can keep adding waypoints. Otherwise opens Saved overview.
    var continueAsPlan = false
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var showImporter = false

    var body: some View {
        Button {
            showImporter = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 12, weight: .bold))
                Text(continueAsPlan ? "Import GPX & continue planning" : "Import GPX track")
                    .font(DirtType.rowTitle)
                    .fontWeight(.bold)
            }
            .foregroundStyle(DirtTheme.ink)
            .frame(maxWidth: .infinity, minHeight: DirtHit.min)
            .background(DirtTheme.rowFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DirtTheme.hairline, lineWidth: 1)
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.gpx, .xml],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            app.planner.importGPX(from: url, context: modelContext, continueAsPlan: continueAsPlan)
        }
    }
}

/// One stage as a single self-contained card. The always-visible row carries the number,
/// the metrics, and the current profile; options reveal inside the same border, so the
/// profile never reads as a detached eyebrow and collapsed stages cost one row each.
struct StageCard<Headline: View, Detail: View>: View {
    let number: Int
    let profileTitle: String
    let isActive: Bool
    let onToggle: () -> Void
    var endpointTitle: String? = nil
    var endpointIsFuelStation = false
    var viaSubtitle: String? = nil
    @ViewBuilder var headline: () -> Headline
    @ViewBuilder var detail: () -> Detail

    static func riderLegRows(in itinerary: RiderItinerary) -> [RiderLeg] {
        itinerary.legs
    }

    static func viaSubtitle(for stages: [RoutePlannerModel.Stage]) -> String? {
        var ordinal = 0
        let names = stages.compactMap { stage -> String? in
            guard stage.endsAtFuelStop else { return nil }
            ordinal += 1
            if let name = stage.fuelStopName, !name.isEmpty { return name }
            return "Fuel stop \(ordinal)"
        }
        return names.isEmpty ? nil : "via \(names.joined(separator: ", "))"
    }

    static func fuelHopTitle(
        riderLegIndex: Int,
        hopIndex: Int,
        hopCount: Int
    ) -> String {
        let from = hopIndex == 0 ? "Point \(riderLegIndex + 1)" : "F\(hopIndex)"
        let to = hopIndex == hopCount - 1
            ? "Point \(riderLegIndex + 2)"
            : "F\(hopIndex + 1)"
        return "\(from) → \(to)"
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DirtSpace.tight) {
                Text("\(number)")
                    .font(.dirtMono(14, weight: .bold))
                    .foregroundStyle(isActive ? DirtTheme.onOrange : .white)
                    .frame(width: 24, height: 24)
                    .background(isActive ? DirtTheme.orange : DirtTheme.chrome)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                if let endpointTitle {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            if endpointIsFuelStation {
                                Image(systemName: "fuelpump.fill")
                                    .foregroundStyle(DirtTheme.orange)
                            }
                            Text(endpointTitle)
                                .font(.dirtUI(10.5, weight: .bold))
                                .foregroundStyle(DirtTheme.ink)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            if let viaSubtitle {
                                Text(viaSubtitle)
                                    .font(.dirtUI(10.5, weight: .semibold))
                                    .foregroundStyle(DirtTheme.muted)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        headline()
                    }
                } else {
                    headline()
                }

                Spacer(minLength: DirtSpace.tight)

                Button(action: onToggle) {
                    profileTag
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(profileTitle) route options for leg \(number)")
                .accessibilityHint(isActive ? "Hides leg options" : "Shows leg options")
            }
            .padding(.horizontal, DirtSpace.inner)
            .frame(maxWidth: .infinity, minHeight: DirtHit.control)

            if isActive {
                Rectangle()
                    .fill(DirtTheme.hairline)
                    .frame(height: 1)
                detail()
                    .padding(DirtSpace.inner)
            }
        }
        .background(DirtTheme.rowFill)
        .clipShape(shape)
        .overlay(shape.stroke(isActive ? DirtTheme.orange : DirtTheme.hairline, lineWidth: 1))
    }

    /// Current profile lives inside the row, filling the space the metrics leave behind.
    private var profileTag: some View {
        HStack(spacing: 4) {
            Text(profileTitle)
                .font(DirtType.chip)
                .fontWeight(.bold)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .black))
                .rotationEffect(.degrees(isActive ? 180 : 0))
        }
        .foregroundStyle(isActive ? DirtTheme.onOrange : DirtTheme.ink)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? DirtTheme.orange : DirtTheme.wash)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(
                    isActive ? DirtTheme.onOrange.opacity(0.25) : DirtTheme.hairline,
                    lineWidth: 1
                )
        )
    }
}

/// `swipeActions` only receives native row behavior inside a List. Route rows
/// intentionally live in the compact planner stack, so this supplies the same
/// deliberate left-swipe reveal without turning the whole row into a button.
private struct SwipeRevealDelete<Content: View>: View {
    let isEnabled: Bool
    let accessibilityLabel: String
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    private let actionWidth: CGFloat = 88

    var body: some View {
        ZStack(alignment: .trailing) {
            if isEnabled {
                Button(role: .destructive) {
                    offset = 0
                    onDelete()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Delete")
                            .font(DirtType.chip)
                            .fontWeight(.bold)
                    }
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(height: DirtHit.control)
                    .background(DirtTheme.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
            }

            content()
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard isEnabled,
                                  abs(value.translation.width) > abs(value.translation.height)
                            else { return }
                            offset = min(0, max(-actionWidth, value.translation.width))
                        }
                        .onEnded { value in
                            guard isEnabled,
                                  abs(value.translation.width) > abs(value.translation.height)
                            else { return }
                            withAnimation(.easeOut(duration: 0.18)) {
                                offset = value.translation.width < -actionWidth * 0.42
                                    ? -actionWidth
                                    : 0
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SavedRoutesList: View {
    var showImport = false
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedRoute.createdAt, order: .reverse) private var routes: [SavedRoute]

    var body: some View {
        VStack(spacing: 8) {
            if showImport {
                GPXImportButton()
                Text("Edit and export tracks from Gaia, Garmin, or another app.")
                    .font(.dirtUI(11))
                    .foregroundStyle(DirtTheme.muted)
                    .multilineTextAlignment(.center)
            }

            if routes.isEmpty {
                Text("No saved routes yet. Route somewhere and tap Save, or import a GPX track.")
                    .font(.dirtUI(12))
                    .foregroundStyle(DirtTheme.muted)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(routes) { route in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(route.name)
                                        .font(.dirtUI(13, weight: .bold))
                                        .foregroundStyle(DirtTheme.ink)
                                    HStack(spacing: 8) {
                                        Text(String(format: "%.1f km", route.distanceMeters / 1000))
                                            .font(.dirtMono(11, weight: .semibold))
                                            .foregroundStyle(DirtTheme.muted)
                                        Text("\(route.dirtPercent)% dirt")
                                            .font(.dirtMono(11, weight: .semibold))
                                            .foregroundStyle(DirtTheme.dirtMix)
                                        Text(route.profile.title)
                                            .font(.dirtUI(11, weight: .semibold))
                                            .foregroundStyle(DirtTheme.muted)
                                    }
                                }
                                Spacer()
                                Button("View") {
                                    app.planner.loadSavedRoute(route)
                                }
                                .buttonStyle(DirtChipStyle(isActive: true))
                                Button {
                                    modelContext.delete(route)
                                    try? modelContext.save()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 14))
                                        .foregroundStyle(DirtTheme.danger)
                                        .frame(width: DirtHit.min, height: DirtHit.min)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete saved route")
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: DirtHit.control)
                            .background(DirtTheme.rowFill)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(DirtTheme.hairline, lineWidth: 1)
                            )
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }
}

/// Thin wrapper so Export can go through the paywall gate before the system share sheet.
private struct DirtShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
