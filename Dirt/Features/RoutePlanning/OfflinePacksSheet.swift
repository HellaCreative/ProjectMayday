import CoreLocation
import SwiftUI

/// Installed routing packs. Regions are acquired from waypoint coverage, not a browse catalog.
struct OfflinePacksSheet: View {
    static let allowsManualDownload = false

    @Environment(AppEnvironment.self) private var app
    @Binding var isPresented: Bool
    @State private var busyIDs: Set<String> = []
    @State private var actionError: String?

    private var packs: GraphPackStore { app.graphPacks }
    private var rows: [GraphPackStore.InstalledPackManagementRow] {
        packs.installedManagementRows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DirtSpace.group) {
                    intro
                    if let actionError {
                        Text(actionError).font(DirtType.helper).foregroundStyle(DirtTheme.danger)
                    }
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
                        .foregroundStyle(DirtTheme.action)
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
            Text("Packs are installed when a route needs them. Update installed packs here when a new version is available, or delete them to free space.")
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
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                Text(row.title)
                    .font(DirtType.rowTitle)
                    .foregroundStyle(DirtTheme.ink)
                Text(row.revisionLabel)
                    .font(DirtType.helper)
                    .foregroundStyle(row.revisionState == .stale ? DirtTheme.action : DirtTheme.muted)
                Text(sizeLabel(bytes: row.bytes))
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.muted)
            }
            HStack(spacing: DirtSpace.row) {
                if busyIDs.contains(row.id) || packs.managementInFlight.contains(row.id) {
                    ProgressView().tint(DirtTheme.orange)
                        .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
                        .accessibilityLabel("Updating pack")
                } else {
                    if row.revisionState == .stale {
                        Button("Update") { perform(row.id, update: true) }
                            .foregroundStyle(DirtTheme.action)
                            .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
                    }
                    Button("Delete", role: .destructive) { perform(row.id, update: false) }
                        .foregroundStyle(DirtTheme.danger)
                        .frame(minWidth: DirtHit.min, minHeight: DirtHit.min)
                }
            }
            .font(DirtType.rowTitle)
            .fontWeight(.semibold)
            .buttonStyle(.plain)

        }
        .padding(DirtSpace.inner)
        .frame(minHeight: DirtHit.control)
        .background(
            DirtTheme.rowFill,
            in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
    }

    private func perform(_ id: String, update: Bool) {
        guard busyIDs.insert(id).inserted else { return }
        actionError = nil
        Task {
            defer { busyIDs.remove(id) }
            do {
                if update { try await packs.updateRegion(id) }
                else { try await packs.deleteRegion(id) }
            } catch {
                actionError = "Could not \(update ? "update" : "delete") pack. \(error.localizedDescription)"
            }
        }
    }

    private func sizeLabel(bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        let size = mb >= 10 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
        return "\(size) on this phone"
    }
}
