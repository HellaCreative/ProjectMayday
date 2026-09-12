import CoreLocation
import SwiftUI

/// Installed routing packs. Regions are acquired from waypoint coverage, not a browse catalog.
struct OfflinePacksSheet: View {
    static let allowsManualDownload = false

    @Environment(AppEnvironment.self) private var app
    @Binding var isPresented: Bool

    private var packs: GraphPackStore { app.graphPacks }
    private var rows: [GraphPackStore.InstalledPackManagementRow] {
        packs.installedManagementRows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DirtSpace.group) {
                    intro
                    if rows.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: DirtSpace.tight) {
                            ForEach(rows) { row in
                                installedRow(row)
                            }
                        }
                    }
                }
                .padding(DirtSpace.group)
            }
            .background(DirtTheme.sheetMaterial)
            .navigationTitle("Packs")
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
            Text("Installed routing packs")
                .font(DirtType.title)
                .foregroundStyle(DirtTheme.ink)
            Text("DIRT offers your current region after location access and asks before adding regions to a route. You can delete a pack here; you cannot browse or pre-download unrelated regions.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        Text("No routing packs on this phone yet. Place a route through Canada or the United States and DIRT will ask to install the required region.")
            .font(DirtType.helper)
            .foregroundStyle(DirtTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DirtSpace.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                    .stroke(DirtTheme.hairline, lineWidth: 1)
            )
    }

    private func installedRow(_ row: GraphPackStore.InstalledPackManagementRow) -> some View {
        HStack(alignment: .center, spacing: DirtSpace.inner) {
            VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                Text(row.title)
                    .font(DirtType.rowTitle)
                    .foregroundStyle(DirtTheme.ink)
                Text(row.revisionLabel)
                    .font(DirtType.helper)
                    .foregroundStyle(row.revisionState == .stale ? DirtTheme.orange : DirtTheme.muted)
                Text(sizeLabel(bytes: row.bytes))
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.muted.opacity(0.9))
            }
            Spacer(minLength: DirtSpace.tight)
            Button("Delete") {
                packs.deleteRegion(row.id)
            }
            .font(DirtType.rowTitle)
            .fontWeight(.semibold)
            .foregroundStyle(DirtTheme.danger)
            .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
            .contentShape(Rectangle())
        }
        .padding(DirtSpace.inner)
        .frame(minHeight: DirtHit.control)
        .background(
            DirtTheme.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private func sizeLabel(bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        let size = mb >= 10 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
        return "\(size) on this phone"
    }
}
