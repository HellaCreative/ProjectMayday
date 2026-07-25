import SwiftData
import SwiftUI

struct RoutePlannerCard: View {
    @Binding var isOpen: Bool
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var showSaveDialog = false
    @State private var saveName = ""
    @State private var showUnknownAck = false

    private var planner: RoutePlannerModel { app.planner }

    var body: some View {
        @Bindable var planner = app.planner
        VStack(spacing: 10) {
            Capsule()
                .fill(.black.opacity(0.15))
                .frame(width: 42, height: 5)
                .padding(.top, 8)
                .onTapGesture { isOpen = false }

            Picker("Mode", selection: $planner.mode) {
                ForEach(RoutePlannerModel.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch planner.mode {
            case .fromHere, .plan:
                profileRow
                allowUnknownRow
                if planner.mode == .plan {
                    planStages
                }
                statusRow
                if planner.hasRoute {
                    statsRow
                    ctaRow
                }
                if planner.hasRoute || (planner.mode == .plan && !planner.stages.isEmpty) {
                    Button("Clear route") { planner.clearRoute() }
                        .font(.dirtUI(11, weight: .bold))
                        .foregroundStyle(DirtTheme.danger)
                }
            case .saved:
                SavedRoutesList()
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .background(DirtTheme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .alert("Allow unknown access?", isPresented: $showUnknownAck) {
            Button("Allow", role: .destructive) { planner.allowUnknown = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unknown-access roads may cross land where motorized access is not confirmed. You are responsible for gates, signs, and local rules.")
        }
        .alert("Save route", isPresented: $showSaveDialog) {
            TextField("Route name", text: $saveName)
            Button("Save") {
                planner.saveRoute(named: saveName, context: modelContext)
                saveName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var profileRow: some View {
        HStack(spacing: 6) {
            ForEach(RouteProfile.allCases) { profile in
                Button(profile.title) {
                    planner.profile = profile
                }
                .buttonStyle(DirtChipStyle(isActive: planner.profile == profile))
            }
            Spacer()
        }
    }

    private var allowUnknownRow: some View {
        HStack {
            Text("Allow unknown access")
                .font(.dirtUI(12, weight: .semibold))
                .foregroundStyle(DirtTheme.ink)
            Spacer()
            Toggle("", isOn: Binding(
                get: { planner.allowUnknown },
                set: { newValue in
                    if newValue {
                        showUnknownAck = true
                    } else {
                        planner.allowUnknown = false
                    }
                }
            ))
            .labelsHidden()
            .tint(DirtTheme.orange)
            .disabled(planner.profile == .cleanest)
        }
        .opacity(planner.profile == .cleanest ? 0.45 : 1)
    }

    private var planStages: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(planner.stages.enumerated()), id: \.element.id) { index, stage in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.dirtMono(11, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(DirtTheme.chrome)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                    if stage.isRouting {
                        ProgressView().controlSize(.mini)
                        Text("Routing stage…").font(.dirtUI(11)).foregroundStyle(DirtTheme.muted)
                    } else if let error = stage.error {
                        Text(error).font(.dirtUI(11)).foregroundStyle(DirtTheme.danger).lineLimit(1)
                    } else if let response = stage.response {
                        Text(String(format: "%.1f km", (response.distanceMeters ?? 0) / 1000))
                            .font(.dirtMono(11, weight: .semibold))
                        Text("\(response.dirtPercent)% dirt")
                            .font(.dirtMono(11, weight: .semibold))
                            .foregroundStyle(DirtTheme.dirtMix)
                    } else {
                        Text(stage.end == nil ? "Tap the map to set the stage end" : "Waiting…")
                            .font(.dirtUI(11))
                            .foregroundStyle(DirtTheme.muted)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        Group {
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
            } else if !planner.hasRoute {
                Text(planner.mode == .fromHere
                     ? "Tap the map to set your destination. Your GPS position is A."
                     : "Tap the map to drop stage points. Long-press adds a stage.")
                    .font(.dirtUI(12))
                    .foregroundStyle(DirtTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(String(format: "%.1f", planner.totalMeters / 1000))
                    .font(.dirtMono(17, weight: .bold))
                Text("KM").font(.dirtUI(9, weight: .heavy)).foregroundStyle(DirtTheme.muted)
            }
            VStack(spacing: 1) {
                Text("\(planner.aggregateDirtPercent)%")
                    .font(.dirtMono(17, weight: .bold))
                    .foregroundStyle(DirtTheme.dirtMix)
                Text("DIRT").font(.dirtUI(9, weight: .heavy)).foregroundStyle(DirtTheme.muted)
            }
            VStack(spacing: 1) {
                Text("\(planner.aggregatePavedPercent)%")
                    .font(.dirtMono(17, weight: .bold))
                    .foregroundStyle(DirtTheme.pavedMix)
                Text("PAVED").font(.dirtUI(9, weight: .heavy)).foregroundStyle(DirtTheme.muted)
            }
            Spacer()
            mixBar
        }
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
        .frame(width: 110, height: 8)
        .clipShape(Capsule())
    }

    private var ctaRow: some View {
        HStack(spacing: 8) {
            Button("Save") { showSaveDialog = true }
                .buttonStyle(DirtCTAStyle(fill: DirtTheme.chrome))
            if let url = planner.gpxFileURL() {
                ShareLink(item: url) {
                    Text("Export GPX")
                        .font(.dirtUI(12, weight: .heavy))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(DirtTheme.exportGray)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Button("Start") {
                isOpen = false
                planner.startNavigation()
            }
            .buttonStyle(DirtCTAStyle(fill: DirtTheme.navGreen))
        }
    }
}

struct SavedRoutesList: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedRoute.createdAt, order: .reverse) private var routes: [SavedRoute]

    var body: some View {
        if routes.isEmpty {
            Text("No saved routes yet. Route somewhere and tap Save.")
                .font(.dirtUI(12))
                .foregroundStyle(DirtTheme.muted)
                .padding(.vertical, 12)
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
