import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Route planner, redesigned to the Figma screens page:
/// orange tab bar → mode chips → numbered stage rows (per-stage mode +
/// unknown-access policy) → stat chips + mix bar → icon CTAs → Clear All.
/// The handle collapses the card down to a single tab pill (minimized state).
struct RoutePlannerCard: View {
    @Binding var isOpen: Bool
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var modelContext

    @State private var collapsed = false
    @State private var showSaveDialog = false
    @State private var saveName = ""
    /// Pending unknown-access confirmation. `nil` target = From-here (global).
    @State private var unknownAckStage: Int?
    @State private var showUnknownAck = false
    /// Stage whose mode the chips edit (Plan tab). Nil = default for new stages.
    @State private var selectedStage: Int?
    @State private var showFromHereToPlanConfirm = false
    @State private var showPlanToFromHereConfirm = false

    private var planner: RoutePlannerModel { app.planner }

    var body: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(.black.opacity(0.15))
                .frame(width: 42, height: 5)
                .padding(.top, 8)
                .contentShape(Rectangle().inset(by: -12))
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.22)) { collapsed.toggle() }
                }

            if collapsed {
                minimizedPill
            } else {
                tabBar

                switch planner.mode {
                case .fromHere:
                    fromHereContent
                case .plan:
                    planContent
                case .saved:
                    SavedRoutesList(showImport: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(DirtTheme.sheet)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 22,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: -2)
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
        .alert("Save route", isPresented: $showSaveDialog) {
            TextField("Route name", text: $saveName)
            Button("Save") {
                planner.saveRoute(named: saveName, context: modelContext)
                saveName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Switch to Plan a route?",
            isPresented: $showFromHereToPlanConfirm,
            titleVisibility: .visible
        ) {
            Button("Keep") {
                selectedStage = nil
                planner.switchToPlanKeepingFromHere()
            }
            Button("Clear", role: .destructive) {
                selectedStage = nil
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
                planner.switchToFromHereUsingLastPin()
            }
            Button("Start anew", role: .destructive) {
                selectedStage = nil
                planner.switchToFromHereClearing()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use the last pin as your destination, or clear the plan.")
        }
    }

    // MARK: - Minimized

    private var minimizedPill: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { collapsed = false }
        } label: {
            Text(planner.mode.rawValue)
                .font(.dirtUI(13, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .stroke(DirtTheme.orange, lineWidth: 1.5)
                )
        }
        .accessibilityLabel("Expand route planner")
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RoutePlannerModel.Mode.allCases) { mode in
                Button {
                    requestMode(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(.dirtUI(13, weight: .bold))
                        .foregroundStyle(planner.mode == mode ? DirtTheme.ink : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            planner.mode == mode
                                ? AnyShapeStyle(.white)
                                : AnyShapeStyle(.clear)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
            }
        }
        .padding(2)
        .background(DirtTheme.orange)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
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
        planner.selectMode(mode)
    }

    // MARK: - From here

    @ViewBuilder private var fromHereContent: some View {
        modeChips(active: planner.profile) { planner.profile = $0 }

        if planner.hasRoute {
            stageRow(
                number: 1,
                accent: true,
                km: planner.totalMeters / 1000,
                dirtPercent: planner.aggregateDirtPercent,
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
                unknownDisabled: planner.profile == .cleanest
            )
            routingStatus
            ctaRow
            clearAllButton
        } else {
            routingStatus
            if !planner.isRouting, planner.errorMessage == nil {
                helperBox("Tap the map on a single destination to create a route from your current location")
            }
        }
    }

    // MARK: - Plan

    @ViewBuilder private var planContent: some View {
        // Mode chips live per-stage (tap a stage to expand). Hide the top row
        // until the first stage exists so empty Plan stays clean.
        if planner.stages.isEmpty {
            VStack(spacing: 8) {
                helperBox("Add your first pin to the location where you would like your route to begin. Add a second pin to complete your first stage")
                GPXImportButton()
            }
        } else {
            stageList
        }

        routingStatus

        if planner.hasRoute {
            statsRow
            ctaRow
            clearAllButton
        } else if !planner.stages.isEmpty {
            clearAllButton
        }
    }

    @ViewBuilder private var stageList: some View {
        // Figma stages band ≈ 180pt — fits ~3 (eyebrow + row) units; 4+ scroll.
        let bandHeight: CGFloat = 180
        if planner.stages.count > 3 {
            ScrollView {
                stageListContent
            }
            .frame(maxHeight: bandHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
        } else {
            stageListContent
        }
    }

    private var stageListContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(planner.stages.enumerated()), id: \.element.id) { index, stage in
                stageBlock(index: index, stage: stage)
            }
        }
        .padding(.vertical, 2)
    }

    /// One stage unit: profile eyebrow *or* expanded chips above the row — never inside it.
    @ViewBuilder private func stageBlock(index: Int, stage: RoutePlannerModel.Stage) -> some View {
        let isActive = selectedStage == index
        VStack(alignment: .leading, spacing: 4) {
            if isActive {
                stageModeChips(for: index, active: stage.profile)
            } else {
                profileEyebrow(stage.profile) {
                    toggleStageSelection(index)
                }
            }
            planStageRow(index: index, stage: stage, isActive: isActive)
        }
    }

    private func stageModeChips(for index: Int, active: RouteProfile) -> some View {
        HStack(spacing: 6) {
            ForEach(RouteProfile.allCases) { profile in
                Button(profile.title) {
                    planner.setStageProfile(profile, at: index)
                    withAnimation(.easeInOut(duration: 0.18)) { selectedStage = nil }
                }
                .font(.dirtUI(12, weight: .bold))
                .foregroundStyle(active == profile ? .white : DirtTheme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(active == profile ? DirtTheme.orange : DirtTheme.wash)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        active == profile ? Color.white.opacity(0.9) : Color.black.opacity(0.08),
                        lineWidth: 1
                    )
                )
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedStage = nil
                    planner.deleteStage(at: index)
                }
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DirtTheme.danger)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Delete stage \(index + 1)")
        }
        .padding(.vertical, 4)
    }

    /// Collapsed profile label — pill sitting above the stage row (Figma eyebrow).
    private func profileEyebrow(_ profile: RouteProfile, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(profile.title)
                .font(.dirtUI(8, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DirtTheme.muted, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.title) mode. Tap to change.")
    }

    @ViewBuilder private func planStageRow(index: Int, stage: RoutePlannerModel.Stage, isActive: Bool) -> some View {
        if stage.isRouting {
            HStack(spacing: 8) {
                numberBadge(index + 1)
                ProgressView().controlSize(.mini)
                Text("Routing stage…").font(.dirtUI(11)).foregroundStyle(DirtTheme.muted)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DirtTheme.wash)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(stageBorder(isActive: isActive))
            .contentShape(Rectangle())
            .onTapGesture { toggleStageSelection(index) }
        } else if let error = stage.error {
            HStack(spacing: 8) {
                numberBadge(index + 1)
                Text(error).font(.dirtUI(11)).foregroundStyle(DirtTheme.danger).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DirtTheme.wash)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(stageBorder(isActive: isActive))
            .contentShape(Rectangle())
            .onTapGesture { toggleStageSelection(index) }
        } else if let response = stage.response {
            stageRow(
                number: index + 1,
                accent: isActive,
                km: (response.distanceMeters ?? 0) / 1000,
                dirtPercent: response.dirtPercent,
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
                unknownDisabled: stage.profile == .cleanest
            )
            .contentShape(Rectangle())
            .onTapGesture { toggleStageSelection(index) }
        } else {
            HStack(spacing: 8) {
                numberBadge(index + 1)
                Text(stage.end == nil
                      ? "Press and hold the map to set the stage end"
                      : "Waiting for route…")
                    .font(.dirtUI(11))
                    .foregroundStyle(DirtTheme.muted)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DirtTheme.wash)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(stageBorder(isActive: isActive))
            .contentShape(Rectangle())
            .onTapGesture { toggleStageSelection(index) }
        }
    }

    private func toggleStageSelection(_ index: Int) {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedStage = selectedStage == index ? nil : index
        }
        if selectedStage == index {
            planner.focusStage(at: index)
        }
    }

    private func stageBorder(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(isActive ? DirtTheme.routePaved : Color(white: 0.867), lineWidth: 1)
    }

    // MARK: - Shared rows

    private func modeChips(active: RouteProfile, select: @escaping (RouteProfile) -> Void) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(RouteProfile.allCases) { profile in
                Button(profile.title) { select(profile) }
                    .font(.dirtUI(13, weight: .bold))
                    .foregroundStyle(active == profile ? .white : DirtTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(active == profile ? DirtTheme.orange : DirtTheme.wash)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private func numberBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.dirtMono(11, weight: .bold))
            .frame(width: 22, height: 22)
            .background(DirtTheme.orange)
            .foregroundStyle(.white)
            .clipShape(Circle())
    }

    private func stageRow(
        number: Int,
        accent: Bool,
        km: Double,
        dirtPercent: Int,
        allowUnknown: Binding<Bool>,
        unknownDisabled: Bool
    ) -> some View {
        HStack(spacing: 8) {
            numberBadge(number)

            Text(String(format: "%.1f km", km))
                .font(.dirtMono(11, weight: .semibold))
                .foregroundStyle(DirtTheme.ink)
                .frame(minWidth: 72)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.white.opacity(0.97))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color(white: 0.867), lineWidth: 1)
                )
                .layoutPriority(1)

            Text("\(dirtPercent)% dirt")
                .font(.dirtMono(11, weight: .semibold))
                .foregroundStyle(DirtTheme.dirtMix)
                .frame(minWidth: 72)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.white.opacity(0.97))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color(white: 0.867), lineWidth: 1)
                )
                .layoutPriority(1)

            // Exact 4pt gap — do not rely on HStack spacing alone; scaleEffect on
            // the Toggle can visually eat padding/spacing into the label.
            HStack(spacing: 0) {
                Text("Allow unknown")
                    .font(.dirtUI(10, weight: .semibold))
                    .foregroundStyle(DirtTheme.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Color.clear
                    .frame(width: 4, height: 1)

                Toggle("", isOn: allowUnknown)
                    .labelsHidden()
                    .tint(DirtTheme.orange)
                    // Anchor leading so the shrink doesn't draw back into the 4pt gap.
                    .scaleEffect(0.72, anchor: .leading)
                    .frame(width: 36, height: 22, alignment: .leading)
                    .disabled(unknownDisabled)
                    .opacity(unknownDisabled ? 0.4 : 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirtTheme.wash)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(stageBorder(isActive: accent))
    }

    @ViewBuilder private var routingStatus: some View {
        if planner.isRouting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding your route…")
                    .font(.dirtUI(12, weight: .semibold))
                    .foregroundStyle(DirtTheme.muted)
            }
        } else if let error = planner.errorMessage {
            Text(error)
                .font(.dirtUI(12, weight: .semibold))
                .foregroundStyle(DirtTheme.danger)
                .multilineTextAlignment(.center)
        }
    }

    private func helperBox(_ text: String) -> some View {
        Text(text)
            .font(.dirtUI(12.5))
            .foregroundStyle(DirtTheme.ink.opacity(0.75))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(DirtTheme.wash)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 8) {
            statChip(String(format: "%.1f", planner.totalMeters / 1000), label: "KM", color: DirtTheme.ink)
            statChip("\(planner.aggregateDirtPercent)%", label: "DIRT", color: DirtTheme.dirtMix)
            statChip("\(planner.aggregatePavedPercent)%", label: "PAVED", color: DirtTheme.pavedMix)
            Spacer(minLength: 8)
            mixBar
        }
    }

    private func statChip(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.dirtMono(17, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.dirtUI(9, weight: .heavy))
                .foregroundStyle(DirtTheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DirtTheme.wash)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var mixBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(DirtTheme.dirtMix)
                    .frame(width: proxy.size.width * CGFloat(planner.aggregateDirtPercent) / 100)
                Rectangle().fill(DirtTheme.pavedMix)
            }
        }
        .frame(width: 100, height: 7)
        .clipShape(Capsule())
    }

    // MARK: - CTAs

    private var ctaRow: some View {
        // Figma: Save 103.5 · Export 142 · Start 103.5 on a 365pt row.
        // Equal thirds squish Export — pull 8pt from Save and Start each.
        GeometryReader { geo in
            let gap: CGFloat = 8
            let available = max(geo.size.width - gap * 2, 0)
            let unit = available / 3
            let saveWidth = max(unit - 8, 0)
            let exportWidth = max(unit + 16, 0)
            let startWidth = max(unit - 8, 0)

            HStack(spacing: gap) {
                Button {
                    showSaveDialog = true
                } label: {
                    ctaLabel("SAVE", icon: "square.and.arrow.down", fill: DirtTheme.chrome)
                }
                .frame(width: saveWidth)

                Group {
                    if let url = planner.gpxFileURL() {
                        ShareLink(item: url) {
                            ctaLabel("EXPORT GPX", icon: "doc.badge.arrow.up", fill: DirtTheme.exportGray)
                        }
                    } else {
                        ctaLabel("EXPORT GPX", icon: "doc.badge.arrow.up", fill: DirtTheme.exportGray)
                            .opacity(0.45)
                    }
                }
                .frame(width: exportWidth)

                Button {
                    isOpen = false
                    planner.startNavigation()
                } label: {
                    ctaLabel("START", icon: "play.fill", fill: DirtTheme.navGreen)
                }
                .frame(width: startWidth)
            }
        }
        .frame(height: 44)
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
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var clearAllButton: some View {
        Button("Clear All") {
            planner.clearRoute()
            selectedStage = nil
        }
        .font(.dirtUI(12, weight: .bold))
        .foregroundStyle(DirtTheme.danger)
        .padding(.top, 2)
    }
}

/// Document picker + share-sheet entry for GPX tracks (web `gpxImportBtn` parity).
struct GPXImportButton: View {
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
                Text("Import GPX track")
                    .font(.dirtUI(12, weight: .bold))
            }
            .foregroundStyle(DirtTheme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.black.opacity(0.12), lineWidth: 1)
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.gpx, .xml],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            app.planner.importGPX(from: url, context: modelContext)
        }
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
                                        .font(.system(size: 13))
                                        .foregroundStyle(DirtTheme.danger)
                                }
                            }
                            .padding(10)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }
}
