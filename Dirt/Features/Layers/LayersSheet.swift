import SwiftUI

/// Layers legend + basemap picker + preference toggles.
/// @AppStorage prefs persist to UserDefaults.  Any toggle change bumps
/// `app.mapState.layerPrefsGeneration`, which wakes the Coordinator to
/// apply updated visibility to the live MapLibre style.
struct LayersSheet: View {
    @Environment(AppEnvironment.self) private var app

    @AppStorage(MapStyleCatalog.preferenceKey) private var styleIDRaw = MapStyleID.shortbread.rawValue
    @AppStorage("dirt.layers.fuel") private var showFuel = false
    @AppStorage("dirt.layers.camp") private var showCampgrounds = false
    @AppStorage("dirt.layers.lodging") private var showLodging = false
    @AppStorage("dirt.layers.liquor") private var showLiquor = false
    @AppStorage("dirt.layers.network.ns") private var showNSLines = false
    @AppStorage("dirt.layers.network.nb") private var showNBLines = false
    @AppStorage("dirt.layers.network.qc") private var showQCLines = false

    private var selectedStyle: MapStyleID {
        MapStyleID(rawValue: styleIDRaw) ?? .shortbread
    }

    var body: some View {
        NavigationStack {
            List {

                Section("Rider services") {
                    serviceToggle("Fuel", icon: "fuelpump.fill", isOn: $showFuel)
                    serviceToggle("Campgrounds", icon: "tent.fill", isOn: $showCampgrounds)
                    serviceToggle("Lodging", icon: "bed.double.fill", isOn: $showLodging)
                    serviceToggle("Liquor", icon: "wineglass.fill", isOn: $showLiquor)
                }
                .tint(DirtTheme.orange)

                Section {
                    Toggle("Show NS route lines", isOn: $showNSLines)
                    Toggle("Show NB route lines", isOn: $showNBLines)
                    Toggle("Show QC route lines", isOn: $showQCLines)
                } header: {
                    Text("Route data")
                } footer: {
                    Text("Viewport lens for provincial secondary networks (NS TDB, NB, QC). One province at a time. When off, purple/blue lines still appear as a corridor around an active route so you can manually route around trouble.")
                        .font(.dirtUI(11))
                }
                .tint(DirtTheme.orange)

                Section {
                    ForEach(MapStyleID.allCases) { style in
                        Button {
                            selectStyle(style)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.title)
                                        .font(.dirtUI(14, weight: .bold))
                                        .foregroundStyle(DirtTheme.ink)
                                    Text(style.subtitle)
                                        .font(.dirtUI(11))
                                        .foregroundStyle(DirtTheme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if selectedStyle == style {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DirtTheme.orange)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Basemap")
                } footer: {
                    Text("Basemap is visual only. Routes still calculate on OSM dual-sport data via /api/route.")
                        .font(.dirtUI(11))
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: showFuel)        { _, _ in app.mapState.bumpLayerPrefs() }
            .onChange(of: showCampgrounds) { _, _ in app.mapState.bumpLayerPrefs() }
            .onChange(of: showLodging)     { _, _ in app.mapState.bumpLayerPrefs() }
            .onChange(of: showLiquor)      { _, _ in app.mapState.bumpLayerPrefs() }
            .onChange(of: showNSLines) { _, on in
                if on { showNBLines = false; showQCLines = false }
                app.mapState.bumpLayerPrefs()
            }
            .onChange(of: showNBLines) { _, on in
                if on { showNSLines = false; showQCLines = false }
                app.mapState.bumpLayerPrefs()
            }
            .onChange(of: showQCLines) { _, on in
                if on { showNSLines = false; showNBLines = false }
                app.mapState.bumpLayerPrefs()
            }
        }
    }

    private func serviceToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DirtTheme.ink)
                    .frame(width: 22)
                Text(title)
            }
        }
    }

    private func selectStyle(_ style: MapStyleID) {
        styleIDRaw = style.rawValue
        MapStyleCatalog.selectedID = style
        app.mapState.applySelectedMapStyle()
    }
}
