import SwiftUI

/// Map overlays and basemap — hosted in `DockSheetPanel`.
/// Toggle changes bump `app.mapState.layerPrefsGeneration` so the MapLibre
/// coordinator can apply visibility on the live style.
struct LayersSheet: View {
    var onClose: (() -> Void)? = nil
    @Environment(AppEnvironment.self) private var app
    @State private var busyPacks: Set<String> = []
    @State private var packError: String?
    @State private var pendingDeleteID: String?
    @State private var confirmClearAll = false
    @State private var clearingAll = false

    @AppStorage(MapStyleCatalog.preferenceKey) private var styleIDRaw = MapStyleID.shortbreadRich.rawValue
    @AppStorage("dirt.layers.fuel") private var showFuel = false
    @AppStorage("dirt.layers.camp") private var showCampgrounds = false
    @AppStorage("dirt.layers.lodging") private var showLodging = false
    @AppStorage("dirt.layers.liquor") private var showLiquor = false
    @AppStorage("dirt.layers.attractions") private var showAttractions = true
    @AppStorage("dirt.layers.water-names") private var showWaterNames = true

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
        .onChange(of: showWaterNames)  { _, _ in app.mapState.bumpLayerPrefs() }
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
                serviceToggle("Lake names", icon: "drop.fill", color: RiderServiceDot.water, isOn: $showWaterNames)
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
            HStack {
                DirtSectionLabel(title: "Downloaded maps")
                Spacer(minLength: DirtSpace.inner)
                Button("Clear All", role: .destructive) { confirmClearAll = true }
                    .font(DirtType.chip.weight(.semibold))
                    .foregroundStyle(DirtTheme.danger)
                    .buttonStyle(.plain)
                    .frame(minHeight: DirtHit.min)
                    .disabled(app.graphPacks.installedManagementRows.isEmpty || clearingAll
                        || !busyPacks.isEmpty || !app.graphPacks.managementInFlight.isEmpty)
            }
            if clearingAll {
                ProgressView("Clearing downloaded maps…")
                    .font(DirtType.helper)
                    .tint(DirtTheme.orange)
            }
            Text("Maps download when a route needs them. Deleted maps can be downloaded again.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let packError {
                Text(packError)
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if app.graphPacks.installedManagementRows.isEmpty {
                Text("No maps downloaded yet")
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DirtSpace.tight)
            }
            ForEach(app.graphPacks.installedManagementRows) { row in
                HStack(alignment: .center, spacing: DirtSpace.tight) {
                    VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                        Text(row.title).font(DirtType.rowTitle)
                        Text("\(row.revisionLabel) · \(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))")
                            .font(DirtType.helper)
                            .foregroundStyle(
                                row.revisionState == .stale ? DirtTheme.action : DirtTheme.muted
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if busyPacks.contains(row.id) || app.graphPacks.managementInFlight.contains(row.id) {
                        ProgressView()
                            .tint(DirtTheme.orange)
                            .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
                            .accessibilityLabel(row.revisionState == .stale ? "Updating pack" : "Deleting pack")
                    } else {
                        HStack(spacing: DirtSpace.row) {
                            if row.revisionState == .stale {
                                Button("Update") {
                                    managePack(row.id, update: true)
                                }
                                .foregroundStyle(DirtTheme.action)
                                .buttonStyle(.plain)
                                .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
                                .contentShape(Rectangle())
                                .accessibilityLabel("Update \(row.title)")
                            }
                            Button("Delete", role: .destructive) {
                                pendingDeleteID = row.id
                            }
                            .foregroundStyle(DirtTheme.danger)
                            .buttonStyle(.plain)
                            .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Delete \(row.title)")
                        }
                        .font(DirtType.chip)
                        .disabled(clearingAll)
                    }
                }
            }
        }
        .padding(DirtSpace.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LayersGlass.groupingFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
        .confirmationDialog("Clear all downloaded maps?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { clearDownloadedMaps() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all \(app.graphPacks.installedManagementRows.count) downloaded maps from this phone. Your saved rides stay. Maps will need to download again before offline routing.")
        }
        .confirmationDialog(
            deleteConfirmTitle,
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete pack", role: .destructive) {
                if let id = pendingDeleteID {
                    pendingDeleteID = nil
                    managePack(id, update: false)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteID = nil
            }
        } message: {
            Text("Removes the installed routing pack from this phone. DIRT will ask again when a route needs it.")
        }
    }

    private var deleteConfirmTitle: String {
        guard let id = pendingDeleteID else { return "Delete pack?" }
        let title = app.graphPacks.displayTitle(forRegionId: id)
        return "Delete \(title)?"
    }

    private func clearDownloadedMaps() {
        guard !clearingAll, busyPacks.isEmpty, app.graphPacks.managementInFlight.isEmpty else { return }
        let ids = app.graphPacks.installedManagementRows.map(\.id)
        clearingAll = true
        packError = nil
        Task { @MainActor in
            defer { clearingAll = false }
            let failures = await DownloadedMapsRemoval.remove(ids) { id in
                try await app.graphPacks.deleteRegion(id)
            }
            if !failures.isEmpty {
                packError = "Could not clear \(failures.count) map(s). \(failures[0])"
            }
        }
    }

    private func managePack(_ id: String, update: Bool) {
        guard busyPacks.insert(id).inserted else { return }
        packError = nil
        Task { @MainActor in
            defer { busyPacks.remove(id) }
            do {
                if update {
                    try await app.graphPacks.updateRegion(id)
                } else {
                    try await app.graphPacks.deleteRegion(id)
                }
            } catch {
                packError = "Could not \(update ? "update" : "delete") pack. \(error.localizedDescription)"
            }
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
    static let water = Color(dirtHex: 0x0033CC)
}

/// Opaque islands on Layers’ thin glass. Local to this sheet — not a DirtTheme token change.
private enum LayersGlass {
    static let groupingFill = Color(dirtLight: 0xFFFFFF, dark: 0x2B3037, opacity: 0.94)
}

/// A batch uses the same guarded removal as an individual map. A failed map
/// remains installed; the rest of the requested batch can still finish.
@MainActor
enum DownloadedMapsRemoval {
    static func remove(_ ids: [String], using remove: (String) async throws -> Void) async -> [String] {
        var failures: [String] = []
        for id in ids {
            do { try await remove(id) }
            catch { failures.append("\(id): \(error.localizedDescription)") }
        }
        return failures
    }
}
