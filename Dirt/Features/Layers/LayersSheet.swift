import SwiftUI

/// Layers legend + basemap picker + preference toggles. Preferences persist like
/// the web POC; native POI / NSTDB overlays land in a later build.
struct LayersSheet: View {
    @Environment(AppEnvironment.self) private var app

    @AppStorage(MapStyleCatalog.preferenceKey) private var styleIDRaw = MapStyleCatalog.preferredDefault.rawValue
    @AppStorage(MapStyleCatalog.tokenKey) private var mapboxToken = ""
    @AppStorage("dirt.layers.fuel") private var showFuel = false
    @AppStorage("dirt.layers.camp") private var showCampgrounds = false
    @AppStorage("dirt.layers.lodging") private var showLodging = false
    @AppStorage("dirt.layers.liquor") private var showLiquor = false
    @AppStorage("dirt.layers.access") private var showAccess = true
    @AppStorage("dirt.layers.gravel") private var showGravel = true
    @AppStorage("dirt.layers.branches") private var showBranches = true
    @AppStorage("dirt.layers.bridge") private var showBridge = true
    @AppStorage("dirt.layers.tunnel") private var showTunnel = true
    @AppStorage("dirt.layers.restricted") private var showRestricted = true

    private var selectedStyle: MapStyleID {
        MapStyleID(rawValue: styleIDRaw) ?? .shortbread
    }

    var body: some View {
        NavigationStack {
            List {
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
                        .disabled(style.requiresMapboxToken && !MapStyleCatalog.hasMapboxToken)
                    }
                } header: {
                    Text("Basemap")
                } footer: {
                    Text("Basemap is visual only. Routes still calculate on OSM dual-sport data via /api/route. Mapbox styles need a public token (pk.…).")
                        .font(.dirtUI(11))
                }

                Section("Mapbox token") {
                    SecureField("pk.eyJ…", text: $mapboxToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.dirtMono(12))
                        .onChange(of: mapboxToken) { _, newValue in
                            MapStyleCatalog.setMapboxAccessToken(newValue)
                            // Refresh style file if a Mapbox basemap is active.
                            if selectedStyle.requiresMapboxToken {
                                app.mapState.applySelectedMapStyle()
                            }
                        }
                    if !MapStyleCatalog.hasMapboxToken {
                        Text("Paste a Mapbox public token to unlock Outdoors, Streets, and Satellite.")
                            .font(.dirtUI(11))
                            .foregroundStyle(DirtTheme.muted)
                    }
                }

                Section("Rider services") {
                    Toggle("Fuel", isOn: $showFuel)
                    Toggle("Campgrounds", isOn: $showCampgrounds)
                    Toggle("Lodging", isOn: $showLodging)
                    Toggle("Liquor", isOn: $showLiquor)
                }
                .tint(DirtTheme.orange)

                Section("Map visibility") {
                    legendToggle("Access roads", color: Color(dirtHex: 0x0A66C2), isOn: $showAccess)
                    legendToggle("Gravel", color: Color(dirtHex: 0x5D6874), isOn: $showGravel)
                    legendToggle("Branches / track", color: Color(dirtHex: 0x7C3AED), isOn: $showBranches)
                    legendToggle("Bridges", color: Color(dirtHex: 0x16875F), isOn: $showBridge)
                    legendToggle("Tunnels", color: Color(dirtHex: 0x94572B), isOn: $showTunnel)
                    legendToggle("Restricted", color: Color(dirtHex: 0xD22730), isOn: $showRestricted)
                }
                .tint(DirtTheme.orange)

                Section {
                    Text("Rider Services pins and provincial road overlays stream in on a coming build. Your choices here are already saved.")
                        .font(.dirtUI(12))
                        .foregroundStyle(DirtTheme.muted)
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func selectStyle(_ style: MapStyleID) {
        if style.requiresMapboxToken {
            MapStyleCatalog.setMapboxAccessToken(mapboxToken)
            guard MapStyleCatalog.hasMapboxToken else { return }
        }
        styleIDRaw = style.rawValue
        MapStyleCatalog.selectedID = style
        app.mapState.applySelectedMapStyle()
    }

    private func legendToggle(_ title: String, color: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Capsule().fill(color).frame(width: 22, height: 5)
                Text(title)
            }
        }
    }
}
