import SwiftUI

/// Live-sharing controls as a bottom card over the map, sharing the incident
/// report's surface language. Full width so the status dropdown and the
/// start/stop CTA never truncate at large Dynamic Type.
struct GroupSharingCard: View {
    let onClose: () -> Void

    @Environment(AppEnvironment.self) private var app

    private let statuses = GroupsViewModel.selectableStatuses

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DirtRadius.sheet, style: .continuous)
    }

    var body: some View {
        @Bindable var groups = app.groups

        return VStack(alignment: .leading, spacing: DirtSpace.inner) {
            HStack(alignment: .firstTextBaseline) {
                Text("Group sharing")
                    .font(DirtType.rowTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.ink)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DirtTheme.muted)
                        .frame(width: DirtHit.min, height: DirtHit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close group sharing")
            }

            Text(sharingContext)
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            statusDropdown(groups: groups)

            Button {
                toggleSharing(groups: groups)
            } label: {
                Text(groups.isSharing ? "Stop sharing" : "Start sharing")
            }
            // Fill and foreground travel together — orange can't carry white text.
            .buttonStyle(
                groups.isSharing
                    ? DirtCTAStyle(fill: DirtTheme.chrome)
                    : DirtCTAStyle.brand()
            )
        }
        .padding(DirtSpace.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirtTheme.sheetMaterial, in: cardShape)
        .overlay(cardShape.stroke(DirtTheme.hairline, lineWidth: 1))
        .clipShape(cardShape)
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }

    private func statusDropdown(groups: GroupsViewModel) -> some View {
        VStack(alignment: .leading, spacing: DirtSpace.tight) {
            DirtSectionLabel(title: "Status")

            Menu {
                Picker("Status", selection: Binding(
                    get: { groups.status },
                    set: { groups.setStatus($0) }
                )) {
                    ForEach(statuses, id: \.self) { status in
                        Text(GroupsViewModel.statusLabel(status)).tag(status)
                    }
                }
            } label: {
                HStack(spacing: DirtSpace.inner) {
                    Text(GroupsViewModel.statusLabel(groups.status))
                        .font(DirtType.rowTitle)
                        .foregroundStyle(groups.isSharing ? DirtTheme.ink : DirtTheme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DirtTheme.muted)
                }
                .padding(.horizontal, DirtSpace.row)
                .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                        .stroke(DirtTheme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .disabled(!groups.isSharing)
            .accessibilityLabel("Riding status")
        }
    }

    private func toggleSharing(groups: GroupsViewModel) {
        if groups.isSharing {
            groups.stopSharing()
            app.planner.toast = "Sharing stopped"
        } else if app.supabase.userID == nil {
            app.planner.toast = "Sign in from Profile to share"
        } else if groups.groups.isEmpty {
            app.planner.toast = "Join or create a group first"
        } else {
            groups.startSharing()
            app.planner.toast = "Sharing on"
        }
    }

    private var sharingContext: String {
        if app.supabase.userID == nil {
            return "Sign in from Profile to share your status."
        }
        if let selected = app.groups.selectedGroup {
            return "Sharing with \(selected.name)."
        }
        if app.groups.groups.isEmpty {
            return "Choose a group in Group first."
        }
        return "Live for every group you’re in."
    }
}
