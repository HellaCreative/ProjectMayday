import SwiftUI

/// Map overlays and basemap — hosted in `DockSheetPanel`.
/// Toggle changes bump `app.mapState.layerPrefsGeneration` so the MapLibre
/// coordinator can apply visibility on the live style.
struct LayersSheet: View {
    var onClose: (() -> Void)? = nil
    @Environment(AppEnvironment.self) private var app
    @State private var busyPacks: Set<String> = []
    @State private var packError: String?

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
            DirtSheetHeader(title: "Layers", onClose: onClose)
            layersList
        }
    }

    private var layersList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(MapStyleID.allCases) { style in
                        Button { selectStyle(style) } label: {
                            Text(style == .shortbread ? "Standard" : "Rich")
                                .font(DirtType.rowTitle)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(selectedStyle == style ? DirtTheme.action : DirtTheme.ink)
                                .background(selectedStyle == style ? Color.white.opacity(0.75) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                Text("Rider services").font(DirtType.rowTitle).foregroundStyle(DirtTheme.muted)
                VStack(spacing: 0) {
                    serviceToggle("Fuel", category: "fuel", isOn: $showFuel).frame(minHeight: 50)
                    Divider()
                    serviceToggle("Campgrounds", category: "campground", isOn: $showCampgrounds).frame(minHeight: 50)
                    Divider()
                    serviceToggle("Lodging", category: "lodging", isOn: $showLodging).frame(minHeight: 50)
                    Divider()
                    serviceToggle("Liquor", category: "liquor", isOn: $showLiquor).frame(minHeight: 50)
                }.tint(DirtTheme.orange)
                Text("Downloaded maps").font(DirtType.rowTitle).foregroundStyle(DirtTheme.muted)
                if app.graphPacks.installedManagementRows.isEmpty {
                    Text("No maps downloaded yet").font(DirtType.helper).foregroundStyle(DirtTheme.muted)
                }
                ForEach(app.graphPacks.installedManagementRows) { row in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(DirtType.rowTitle)
                            Text("\(row.revisionLabel) · \(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(DirtTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if busyPacks.contains(row.id) || app.graphPacks.managementInFlight.contains(row.id) {
                            ProgressView()
                        } else {
                            if row.revisionState == .stale {
                                Button("Update") { managePack(row.id, update: true) }.foregroundStyle(DirtTheme.action).frame(minHeight: 44)
                            }
                            Button("Delete", role: .destructive) { managePack(row.id, update: false) }.frame(minHeight: 44)
                        }
                    }.font(.caption.weight(.semibold)).buttonStyle(.plain)
                    Divider()
                }
                if let packError { Text(packError).font(DirtType.helper).foregroundStyle(DirtTheme.danger) }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            .background(GeometryReader { geo in
                Color.clear.preference(key: DockSheetContentHeightKey.self, value: geo.size.height)
            })
        }
        .task { await app.graphPacks.refreshCatalog() }
        .onChange(of: showFuel)        { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showCampgrounds) { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showLodging)     { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showLiquor)      { _, _ in app.mapState.bumpLayerPrefs() }
    }

    private func managePack(_ id: String, update: Bool) {
        guard busyPacks.insert(id).inserted else { return }
        packError = nil
        Task {
            defer { busyPacks.remove(id) }
            do {
                if update { try await app.graphPacks.updateRegion(id) }
                else { try await app.graphPacks.deleteRegion(id) }
            } catch { packError = error.localizedDescription }
        }
    }

    private func serviceToggle(_ title: String, category: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: DirtSpace.inner) {
                Image(systemName: MapLibreMapView.POILayer.systemSymbolName(for: category))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DirtTheme.poiColor(for: category))
                    .frame(width: 22)
                    .accessibilityHidden(true)
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
