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
    @AppStorage("dirt.layers.attractions") private var showAttractions = true

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
            VStack(alignment: .leading, spacing: DirtSpace.group) {
                VStack(alignment: .leading, spacing: DirtSpace.inner) {
                    DirtSectionLabel(title: "Map styles")
                    HStack(spacing: 8) {
                        ForEach(MapStyleID.allCases) { style in
                            let selected = selectedStyle == style
                            Button { selectStyle(style) } label: {
                                Text(style.title)
                                    .font(DirtType.rowTitle)
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                                    .foregroundStyle(selected ? DirtTheme.onOrange : DirtTheme.ink)
                                    .background(
                                        selected ? DirtTheme.orange : LayersGlass.groupingFill,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(
                                                selected ? DirtTheme.onOrange.opacity(0.25) : DirtTheme.hairline,
                                                lineWidth: 1
                                            )
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .animation(DirtMotion.affordance, value: selected)
                            .accessibilityLabel(style.title)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }

                riderServicesCard
                downloadedMapsCard
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
        .onChange(of: showAttractions) { _, _ in app.mapState.bumpLayerPrefs() }
    }

    private var riderServicesCard: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            DirtSectionLabel(title: "Rider services")
            VStack(spacing: 0) {
                serviceToggle("Fuel", icon: "fuelpump.fill", color: RiderServiceDot.fuel, isOn: $showFuel)
                    .frame(minHeight: DirtHit.control)
                Divider()
                serviceToggle("Campgrounds", icon: "tent.fill", color: RiderServiceDot.camp, isOn: $showCampgrounds)
                    .frame(minHeight: DirtHit.control)
                Divider()
                serviceToggle("Attractions", icon: "binoculars.fill", color: RiderServiceDot.attraction, isOn: $showAttractions)
                    .frame(minHeight: DirtHit.control)
                Divider()
                serviceToggle("Lodging", icon: "bed.double.fill", color: RiderServiceDot.lodging, isOn: $showLodging)
                    .frame(minHeight: DirtHit.control)
                Divider()
                serviceToggle("Liquor", icon: "wineglass.fill", color: RiderServiceDot.liquor, isOn: $showLiquor)
                    .frame(minHeight: DirtHit.control)
            }
            .tint(DirtTheme.orange)
        }
        .padding(DirtSpace.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LayersGlass.groupingFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
    }

    private var downloadedMapsCard: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            DirtSectionLabel(title: "Downloaded maps")
            if app.graphPacks.installedManagementRows.isEmpty {
                Text("No maps downloaded yet")
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DirtSpace.tight)
            }
            ForEach(app.graphPacks.installedManagementRows) { row in
                HStack(spacing: DirtSpace.tight) {
                    VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                        Text(row.title).font(DirtType.rowTitle)
                        Text("\(row.revisionLabel) · \(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))")
                            .font(DirtType.helper)
                            .foregroundStyle(DirtTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if busyPacks.contains(row.id) || app.graphPacks.managementInFlight.contains(row.id) {
                        ProgressView()
                    } else {
                        if row.revisionState == .stale {
                            Button("Update") { managePack(row.id, update: true) }
                                .foregroundStyle(DirtTheme.action)
                                .frame(minHeight: DirtHit.min)
                        }
                        Button("Delete", role: .destructive) { managePack(row.id, update: false) }
                            .frame(minHeight: DirtHit.min)
                    }
                }
                .font(DirtType.chip)
                .buttonStyle(.plain)
            }
            if let packError {
                Text(packError)
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.danger)
            }
        }
        .padding(DirtSpace.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LayersGlass.groupingFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
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

    private func serviceToggle(_ title: String, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: DirtSpace.inner) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .font(DirtType.rowTitle)
            }
        }
    }

    private func selectStyle(_ style: MapStyleID) {
        DirtMotion.selection()
        styleIDRaw = style.rawValue
        MapStyleCatalog.selectedID = style
        app.mapState.applySelectedMapStyle(style)
    }
}

/// Map-dot colors from `MapLibreMapView.POILayer.categories` — icon matches the map, not brand orange.
private enum RiderServiceDot {
    static let fuel = Color(dirtHex: 0xE8730C)
    static let camp = Color(dirtHex: 0x2F9E44)
    static let lodging = Color(dirtHex: 0x8A5A2B)
    static let liquor = Color(dirtHex: 0x8E44C9)
    static let attraction = Color(dirtHex: 0x0E7C7B)
}

/// Opaque islands on Layers’ thin glass. Local to this sheet — not a DirtTheme token change.
private enum LayersGlass {
    static let groupingFill = Color(dirtLight: 0xFFFFFF, dark: 0x2B3037, opacity: 0.94)
}
