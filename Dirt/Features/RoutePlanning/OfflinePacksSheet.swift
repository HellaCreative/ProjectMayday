import CoreLocation
import SwiftUI

/// Province / state routing packs for offline detours. Presented as a system sheet
/// (owns its own chrome — NavigationStack is correct here).
struct OfflinePacksSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Binding var isPresented: Bool

    @State private var canadaExpanded = true
    @State private var usExpanded = false

    private var packs: GraphPackStore { app.graphPacks }

    private var canadaRegions: [GraphPackStore.RegionInfo] {
        packs.regions.filter { $0.country == .canada }
    }

    private var usRegions: [GraphPackStore.RegionInfo] {
        packs.regions.filter { $0.country == .unitedStates }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DirtSpace.group) {
                    intro
                    autoToggle
                    countryDrawer(
                        title: "Canada",
                        subtitle: "Provinces & territories",
                        expanded: $canadaExpanded,
                        regions: canadaRegions
                    )
                    countryDrawer(
                        title: "United States",
                        subtitle: "States",
                        expanded: $usExpanded,
                        regions: usRegions
                    )
                }
                .padding(DirtSpace.group)
            }
            .background(DirtTheme.sheetMaterial)
            .navigationTitle("Offline packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                        .font(DirtType.rowTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(DirtTheme.orange)
                        .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
                }
            }
            .task {
                await packs.refreshCatalog()
            }
            .refreshable {
                await packs.refreshCatalog()
            }
        }
        .presentationBackground(DirtTheme.sheetMaterial)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: DirtSpace.tight) {
            Text("Download where you ride")
                .font(DirtType.title)
                .foregroundStyle(DirtTheme.ink)
            Text("Wi‑Fi once, then detour off-grid. Live routing works without a pack. Download only the regions you’ll ride without signal.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var autoToggle: some View {
        Toggle(isOn: Binding(
            get: { packs.autoDownloadNextRegion },
            set: { packs.autoDownloadNextRegion = $0 }
        )) {
            VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                Text("Auto-download next region")
                    .font(DirtType.rowTitle)
                    .foregroundStyle(DirtTheme.ink)
                Text("When on, quietly fetch the pack for a new region you enter while riding. Off by default — live covers you until you download.")
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
            }
        }
        .tint(DirtTheme.orange)
        .padding(DirtSpace.row)
        .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
    }

    private func countryDrawer(
        title: String,
        subtitle: String,
        expanded: Binding<Bool>,
        regions: [GraphPackStore.RegionInfo]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: DirtSpace.inner) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DirtTheme.muted)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                        Text(title)
                            .font(DirtType.rowTitle)
                            .fontWeight(.bold)
                            .foregroundStyle(DirtTheme.ink)
                        Text(subtitle)
                            .font(DirtType.helper)
                            .foregroundStyle(DirtTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Text("\(installedCount(in: regions))/\(regions.count)")
                        .font(DirtType.metricInline)
                        .foregroundStyle(DirtTheme.muted)
                }
                .padding(DirtSpace.row)
                .frame(minHeight: DirtHit.min)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded.wrappedValue ? "Collapse" : "Expand")

            if expanded.wrappedValue {
                VStack(alignment: .leading, spacing: DirtSpace.tight) {
                    ForEach(regions) { region in
                        regionRow(region)
                    }
                }
                .padding(.horizontal, DirtSpace.inner)
                .padding(.bottom, DirtSpace.inner)
            }
        }
        .background(DirtTheme.rowFill.opacity(0.55), in: RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
    }

    private func installedCount(in regions: [GraphPackStore.RegionInfo]) -> Int {
        regions.filter {
            if case .installed = $0.install { return true }
            return false
        }.count
    }

    private func regionRow(_ region: GraphPackStore.RegionInfo) -> some View {
        let installed: Bool = {
            if case .installed = region.install { return true }
            return false
        }()

        return HStack(alignment: .center, spacing: DirtSpace.inner) {
            VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                Text(region.title)
                    .font(DirtType.rowTitle)
                    .foregroundStyle(DirtTheme.ink)
                Text(region.subtitle)
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
                Text(sizeLabel(region))
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.muted.opacity(0.9))
            }
            Spacer(minLength: DirtSpace.tight)
            actionControl(region)
        }
        .padding(DirtSpace.inner)
        .frame(minHeight: DirtHit.control)
        .background(
            (installed ? DirtTheme.orange.opacity(0.08) : DirtTheme.rowFill),
            in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(installed ? DirtTheme.orange.opacity(0.35) : DirtTheme.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func actionControl(_ region: GraphPackStore.RegionInfo) -> some View {
        switch region.install {
        case .installed:
            Button("Remove") {
                packs.deleteRegion(region.id)
            }
            .font(DirtType.rowTitle)
            .fontWeight(.semibold)
            .foregroundStyle(DirtTheme.danger)
            .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
            .contentShape(Rectangle())
        case .available:
            Button("Download") {
                packs.downloadRegion(region.id)
            }
            .font(DirtType.chip)
            .fontWeight(.heavy)
            .foregroundStyle(DirtTheme.onOrange)
            .padding(.horizontal, DirtSpace.row)
            .frame(minHeight: DirtHit.min)
            .background(DirtTheme.orange, in: RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
        case .downloading(let p):
            ProgressView(value: max(p, 0.05))
                .frame(width: 72)
                .tint(DirtTheme.orange)
                .accessibilityLabel("Downloading")
        case .unavailable:
            Text("Soon")
                .font(DirtType.helper)
                .fontWeight(.semibold)
                .foregroundStyle(DirtTheme.muted)
                .frame(minHeight: DirtHit.min)
        }
    }

    private func sizeLabel(_ region: GraphPackStore.RegionInfo) -> String {
        let bytes = region.exactBytes ?? region.approxBytes
        let mb = Double(bytes) / 1_000_000
        let size = mb >= 10 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
        switch region.install {
        case .installed: return "\(size) · on this phone"
        case .unavailable: return "\(size) est. · not published yet"
        default: return "\(size) · routing pack"
        }
    }
}
