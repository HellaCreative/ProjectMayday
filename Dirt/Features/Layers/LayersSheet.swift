import SwiftUI

/// Map overlays, network lens, and basemap — hosted in `DockSheetPanel`.
/// Toggle changes bump `app.mapState.layerPrefsGeneration` so the MapLibre
/// coordinator can apply visibility on the live style.
struct LayersSheet: View {
    @Environment(AppEnvironment.self) private var app

    @AppStorage(MapStyleCatalog.preferenceKey) private var styleIDRaw = MapStyleID.shortbreadRich.rawValue
    @AppStorage("dirt.layers.fuel") private var showFuel = false
    @AppStorage("dirt.layers.camp") private var showCampgrounds = false
    @AppStorage("dirt.layers.lodging") private var showLodging = false
    @AppStorage("dirt.layers.liquor") private var showLiquor = false
    @AppStorage("dirt.layers.network.ns") private var showNSLines = false
    @AppStorage("dirt.layers.network.nb") private var showNBLines = false
    @AppStorage("dirt.layers.network.qc") private var showQCLines = false
    @AppStorage("dirt.layers.network.on") private var showONLines = false
    @AppStorage("dirt.layers.network.bc") private var showBCLines = false
    @AppStorage("dirt.layers.network.ab") private var showABLines = false
    @AppStorage("dirt.layers.bc.osmHierarchy") private var showBCOSMHierarchy = false

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
            networkSection
            parkedBCLayersKeptForReenable
            basemapSection
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onChange(of: showFuel)        { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showCampgrounds) { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showLodging)     { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showLiquor)      { _, _ in app.mapState.bumpLayerPrefs() }
        .onChange(of: showNSLines) { _, on in
            if on {
                clearOtherLenses(except: .ns)
                showBCOSMHierarchy = false
            }
            app.mapState.bumpLayerPrefs()
            app.bcOSMHierarchy.applyPrefs()
        }
        .onChange(of: showNBLines) { _, on in
            if on {
                clearOtherLenses(except: .nb)
                showBCOSMHierarchy = false
            }
            app.mapState.bumpLayerPrefs()
            app.bcOSMHierarchy.applyPrefs()
        }
        .onChange(of: showQCLines) { _, on in
            if on {
                clearOtherLenses(except: .qc)
                showBCOSMHierarchy = false
            }
            app.mapState.bumpLayerPrefs()
            app.bcOSMHierarchy.applyPrefs()
        }
        .onChange(of: showONLines) { _, on in
            if on {
                clearOtherLenses(except: .on)
                showBCOSMHierarchy = false
            }
            app.mapState.bumpLayerPrefs()
            app.bcOSMHierarchy.applyPrefs()
        }
        .onChange(of: showBCLines) { _, on in
            if on {
                clearOtherLenses(except: .bc)
                showBCOSMHierarchy = false
            }
            app.mapState.bumpLayerPrefs()
            app.bcOSMHierarchy.applyPrefs()
        }
        .onChange(of: showABLines) { _, on in
            if on {
                clearOtherLenses(except: .ab)
                showBCOSMHierarchy = false
            }
            app.mapState.bumpLayerPrefs()
            app.bcOSMHierarchy.applyPrefs()
        }
        .onChange(of: showBCOSMHierarchy) { _, on in
            if on {
                showNSLines = false
                showNBLines = false
                showQCLines = false
                showONLines = false
                showBCLines = false
                showABLines = false
            }
            app.mapState.bumpLayerPrefs()
            app.bcOSMHierarchy.applyPrefs()
        }
    }

    private var legendSection: some View {
        Section {
            legendRow(color: DirtTheme.routeGravel, title: "Dirt", detail: "Gravel, track, dual-sport")
            legendRow(color: DirtTheme.routePaved, title: "Paved", detail: "Highway and sealed road")
            legendRow(color: DirtTheme.routeAccess, title: "Unknown access", detail: "Motorcycle permission unproven · Allow unknown only")
        } header: {
            Text("Route paint")
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

    private var networkSection: some View {
        Section {
            Toggle("Nova Scotia", isOn: $showNSLines)
            Toggle("New Brunswick", isOn: $showNBLines)
            Toggle("Quebec", isOn: $showQCLines)
            Toggle("Ontario", isOn: $showONLines)
            // Toggle("British Columbia", isOn: $showBCLines)
            Toggle("Alberta", isOn: $showABLines)
        } header: {
            Text("Network lens")
        } footer: {
            Text("One province at a time. Shows ~20 km of secondary network the current Allow setting can route. Purple Access (unknown) hides until Allow unknown is on. BC lens is parked — OSM Shortbread (highway → ATV/track) is the BC visual.")
                .font(DirtType.helper)
        }
        .listRowBackground(DirtTheme.rowFill)
        .tint(DirtTheme.orange)
    }

    /// Parked 2026-08-13 — keep compiled, do not show.
    /// Re-enable by swapping this for `bcOsmExperimentSection` in `layersList`.
    @ViewBuilder
    private var parkedBCLayersKeptForReenable: some View {
        if false {
            bcOsmExperimentSection
        }
    }

    private var bcOsmExperimentSection: some View {
        Section {
            Toggle("BC OSM hierarchy (test)", isOn: $showBCOSMHierarchy)
            if let status = app.mapState.bcOSMStatusMessage, showBCOSMHierarchy {
                Text(status)
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
            }
        } header: {
            Text("OSM feasibility")
        } footer: {
            Text("Full OSM road stack for BC (no footway, no gov overlay). Visual only — does not change routing packs. Zoom ≥12 for tracks/paths.")
                .font(DirtType.helper)
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
                        .foregroundStyle(DirtTheme.orange)
                        .accessibilityLabel("Selected")
                }
            }
            .frame(minHeight: DirtHit.min)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private enum LensProvince { case ns, nb, qc, on, bc, ab }

    private func clearOtherLenses(except keep: LensProvince) {
        if keep != .ns { showNSLines = false }
        if keep != .nb { showNBLines = false }
        if keep != .qc { showQCLines = false }
        if keep != .on { showONLines = false }
        if keep != .bc { showBCLines = false }
        if keep != .ab { showABLines = false }
    }

    private func legendRow(color: Color, title: String, detail: String) -> some View {
        HStack(spacing: DirtSpace.inner) {
            Capsule()
                .fill(color)
                .frame(width: 28, height: 6)
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

private extension MapStyleID {
    /// Shorter than `subtitle` — Layers list density.
    var shortSubtitle: String {
        switch self {
        case .shortbread:     "High-contrast Shortbread"
        case .shortbreadRich: "Default · deeper landcover"
        }
    }
}
