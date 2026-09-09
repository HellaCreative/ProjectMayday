import SwiftUI

/// Map overlays and basemap — hosted in `DockSheetPanel`.
/// Toggle changes bump `app.mapState.layerPrefsGeneration` so the MapLibre
/// coordinator can apply visibility on the live style.
struct LayersSheet: View {
    @Environment(AppEnvironment.self) private var app
    @State private var offlinePacksOpen = false

    @AppStorage(MapStyleCatalog.preferenceKey) private var styleIDRaw = MapStyleID.shortbreadRich.rawValue
    @AppStorage("dirt.layers.fuel") private var showFuel = false
    @AppStorage("dirt.layers.camp") private var showCampgrounds = false
    @AppStorage("dirt.layers.lodging") private var showLodging = false
    @AppStorage("dirt.layers.liquor") private var showLiquor = false

    private var selectedStyle: MapStyleID {
        MapStyleID(rawValue: styleIDRaw) ?? .shortbreadRich
    }

    var body: some View {
        VStack(spacing: 0) {
            DirtSheetHeader(title: "Layers")
            layersList
        }
    }

    private var layersList: some View {
        List {
            legendSection
            servicesSection
            offlineRoutingSection
            basemapSection
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onChange(of: showFuel)        { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showCampgrounds) { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showLodging)     { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showLiquor)      { _, _ in app.mapState.bumpLayerPrefs() }
        .sheet(isPresented: $offlinePacksOpen) {
            OfflinePacksSheet(isPresented: $offlinePacksOpen)
                .environment(app)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var legendSection: some View {
        Section {
            legendRow(
                color: DirtTheme.routePaved,
                title: "Paved",
                detail: "Sealed surface"
            )
            legendRow(
                color: DirtTheme.routeGravel,
                title: "Gravel",
                detail: "Gravel, compacted, or generic unpaved"
            )
            legendRow(
                color: DirtTheme.routeLoose,
                title: "Loose",
                detail: "Dirt, earth, mud, sand, or natural surface"
            )
            legendRow(
                color: DirtTheme.routeUnknown,
                title: "Unknown surface",
                detail: "Surface is not identified in map data"
            )
            legendRow(
                color: DirtTheme.routeAccess,
                title: "Unknown access",
                detail: "Purple halo · motorcycle permission unproven"
            )
            legendRow(
                color: DirtTheme.routeFerry,
                title: "Ferry crossing",
                detail: "Scheduled transport · verify service before riding",
                dashed: true
            )
        } header: {
            Text("Route paint")
        } footer: {
            Text("Dirt includes gravel, loose, and unknown surface.")
                .font(DirtType.helper)
        }
        .listRowBackground(DirtTheme.rowFill)
    }

    private var servicesSection: some View {
        Section("Rider services") {
            serviceToggle("Fuel", icon: "fuelpump.fill", isOn: $showFuel)
            serviceToggle("Campgrounds", icon: "tent.fill", isOn: $showCampgrounds)
            serviceToggle("Lodging", icon: "bed.double.fill", isOn: $showLodging)
            serviceToggle("Liquor", icon: "wineglass.fill", isOn: $showLiquor)
        }
        .listRowBackground(DirtTheme.rowFill)
        .tint(DirtTheme.orange)
    }

    private var basemapSection: some View {
        Section {
            ForEach(MapStyleID.allCases) { style in
                basemapRow(style)
            }
        } header: {
            Text("Basemap")
        } footer: {
            Text("Looks only — routing still uses dual-sport data.")
                .font(DirtType.helper)
        }
        .listRowBackground(DirtTheme.rowFill)
    }

    private var offlineRoutingSection: some View {
        Section("Offline routing") {
            Button {
                offlinePacksOpen = true
            } label: {
                HStack(spacing: DirtSpace.inner) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DirtTheme.action)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                        Text("Downloaded maps")
                            .font(DirtType.rowTitle)
                            .fontWeight(.bold)
                            .foregroundStyle(DirtTheme.ink)
                        Text(downloadedMapsDetail)
                            .font(DirtType.helper)
                            .foregroundStyle(DirtTheme.muted)
                    }
                    Spacer(minLength: DirtSpace.tight)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DirtTheme.muted)
                }
                .frame(minHeight: DirtHit.min)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(DirtTheme.rowFill)
    }

    private var downloadedMapsDetail: String {
        let count = app.graphPacks.installedManagementRows.count
        if count == 0 { return "Installed automatically when a route needs them" }
        return count == 1 ? "1 region on this phone" : "\(count) regions on this phone"
    }

    private func basemapRow(_ style: MapStyleID) -> some View {
        Button {
            selectStyle(style)
        } label: {
            HStack(alignment: .center, spacing: DirtSpace.inner) {
                VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                    Text(style.title)
                        .font(DirtType.rowTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(DirtTheme.ink)
                    Text(style.shortSubtitle)
                        .font(DirtType.helper)
                        .foregroundStyle(DirtTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DirtSpace.tight)
                if selectedStyle == style {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DirtTheme.action)
                        .accessibilityLabel("Selected")
                }
            }
            .frame(minHeight: DirtHit.min)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func legendRow(
        color: Color,
        title: String,
        detail: String,
        dashed: Bool = false
    ) -> some View {
        HStack(spacing: DirtSpace.inner) {
            RoutePaintLegendSwatch(color: color, dashed: dashed)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                Text(title)
                    .font(DirtType.rowTitle)
                    .foregroundStyle(DirtTheme.ink)
                Text(detail)
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func serviceToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: DirtSpace.inner) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DirtTheme.ink)
                    .frame(width: 22)
                Text(title)
                    .font(DirtType.rowTitle)
            }
        }
    }

    private func selectStyle(_ style: MapStyleID) {
        styleIDRaw = style.rawValue
        MapStyleCatalog.selectedID = style
        app.mapState.applySelectedMapStyle()
    }
}

private struct RoutePaintLegendSwatch: View {
    let color: Color
    var dashed = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: 32, height: 10)
            if dashed {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(color)
                            .frame(width: 8, height: 6)
                    }
                }
            } else {
                Capsule()
                    .fill(color)
                    .frame(width: 30, height: 6)
            }
        }
        .frame(width: 32, height: 10)
    }
}

private extension MapStyleID {
    /// Shorter than `subtitle` — Layers list density.
    var shortSubtitle: String {
        switch self {
        case .shortbread:     "High-contrast Shortbread"
        case .shortbreadRich: "Default · deeper landcover"
        }
    }
}
