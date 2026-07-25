import SwiftUI

/// Layers legend + preference toggles. Preferences persist like the web POC;
/// the native POI / NSTDB overlay streams land in a later build (documented
/// gap in README_TESTFLIGHT.md).
struct LayersSheet: View {
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

    var body: some View {
        NavigationStack {
            List {
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

    private func legendToggle(_ title: String, color: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Capsule().fill(color).frame(width: 22, height: 5)
                Text(title)
            }
        }
    }
}
