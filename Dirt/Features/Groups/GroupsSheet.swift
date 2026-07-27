import SwiftUI

struct GroupsSheet: View {
    let onClose: () -> Void
    @Environment(AppEnvironment.self) private var app
    @State private var newGroupName = ""
    @State private var joinCode = ""
    @State private var showCreateDialog = false
    @State private var showJoinDialog = false

    private var groups: GroupsViewModel { app.groups }

    var body: some View {
        NavigationStack {
            Group {
                if !app.supabase.isSignedIn {
                    signInPrompt
                } else if let selected = groups.selectedGroup {
                    GroupDetailView(group: selected, onClose: onClose)
                } else {
                    groupList
                }
            }
            .navigationTitle(groups.selectedGroup?.name ?? "Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if groups.selectedGroup != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { groups.closeDetail() }
                    }
                }
            }
        }
        .task {
            if app.supabase.isSignedIn {
                await groups.refreshGroups()
            }
        }
        .onDisappear {
            // Web parity: closing the sheet resets to the list panel.
            groups.closeDetail()
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 34))
                .foregroundStyle(DirtTheme.muted)
            Text("Riding groups need an account")
                .font(.dirtUI(15, weight: .bold))
            Text("Sign in from the Profile tab, then create or join a group to ride together.")
                .font(.dirtUI(12))
                .foregroundStyle(DirtTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groupList: some View {
        ScrollView {
            VStack(spacing: 8) {
                if groups.groups.isEmpty && !groups.isLoading {
                    Text("No groups yet — create one or join with an invite code.")
                        .font(.dirtUI(12))
                        .foregroundStyle(DirtTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .background(DirtTheme.wash)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                ForEach(groups.groups) { group in
                    groupCard(group)
                }

                Button {
                    showCreateDialog = true
                } label: {
                    groupCTALabel("CREATE GROUP", icon: "person.2.badge.plus.fill")
                }
                .padding(.top, 8)

                Button {
                    showJoinDialog = true
                } label: {
                    groupCTALabel("JOIN WITH CODE", icon: "arrow.right.square.fill")
                }

                if let error = groups.errorMessage {
                    Text(error)
                        .font(.dirtUI(12, weight: .semibold))
                        .foregroundStyle(DirtTheme.danger)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .background(DirtTheme.sheet)
        .refreshable { await groups.refreshGroups() }
        .alert("Create a group", isPresented: $showCreateDialog) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                newGroupName = ""
                guard !name.isEmpty else { return }
                Task { await groups.createGroup(named: name) }
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
        .alert("Join with invite code", isPresented: $showJoinDialog) {
            TextField("6-character code", text: $joinCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Join") {
                let code = joinCode.trimmingCharacters(in: .whitespaces)
                joinCode = ""
                guard !code.isEmpty else { return }
                Task { await groups.joinGroup(code: code) }
            }
            Button("Cancel", role: .cancel) { joinCode = "" }
        }
    }

    private func groupCard(_ group: GroupSummary) -> some View {
        Button {
            groups.openDetail(group)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.dirtUI(15, weight: .bold))
                        .foregroundStyle(DirtTheme.ink)
                    Text(groupMeta(group))
                        .font(.dirtMono(11, weight: .semibold))
                        .foregroundStyle(DirtTheme.muted)
                }
                Spacer()
                if group.liveCount > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(DirtTheme.navGreen).frame(width: 7, height: 7)
                        Text("\(group.liveCount) LIVE")
                            .font(.dirtMono(9.5, weight: .bold))
                            .foregroundStyle(DirtTheme.navGreen)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DirtTheme.navGreen.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.black.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func groupMeta(_ group: GroupSummary) -> String {
        var meta = "\(group.memberCount) members"
        if let code = group.inviteCode, !code.isEmpty {
            meta += " · code \(code.lowercased())"
        }
        return meta
    }

    private func groupCTALabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
            Text(title)
                .font(.dirtUI(13, weight: .heavy))
                .tracking(0.8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(DirtTheme.orange)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct GroupDetailView: View {
    let group: GroupSummary
    let onClose: () -> Void
    @Environment(AppEnvironment.self) private var app

    private var groups: GroupsViewModel { app.groups }
    private let statuses = ["available", "breakdown", "injured", "stuck"]

    var body: some View {
        @Bindable var groups = app.groups
        List {
            if let invite = group.inviteCode {
                Section("Invite code") {
                    HStack {
                        Text(invite)
                            .font(.dirtMono(22, weight: .bold))
                            .tracking(4)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = invite
                            app.planner.toast = "Invite code copied"
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            }

            Section("Live sharing") {
                if groups.isSharing {
                    Picker("Status", selection: $groups.status) {
                        ForEach(statuses, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Button("Stop sharing") { groups.stopSharing() }
                        .buttonStyle(DirtCTAStyle(fill: DirtTheme.chrome))
                        .listRowBackground(Color.clear)
                } else {
                    Button("Start sharing my position") { groups.startSharing() }
                        .buttonStyle(DirtCTAStyle(fill: DirtTheme.orange))
                        .listRowBackground(Color.clear)
                }
            }

            Section("Riders") {
                ForEach(groups.members) { member in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(member.isLive ? DirtTheme.navGreen : DirtTheme.muted.opacity(0.4))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.displayName)
                                .font(.dirtUI(13, weight: .bold))
                            Text(member.role + (member.status.map { " · \($0)" } ?? ""))
                                .font(.dirtUI(11))
                                .foregroundStyle(DirtTheme.muted)
                        }
                        Spacer()
                        if member.isLive, let lat = member.latitude, let lon = member.longitude,
                           member.userID != app.supabase.userID {
                            Button("Route") {
                                app.planner.routeToMember(name: member.displayName, latitude: lat, longitude: lon)
                                onClose()
                            }
                            .buttonStyle(DirtChipStyle(isActive: true))
                            Button {
                                app.mapState.fly(to: RouteCoordinate(longitude: lon, latitude: lat), zoom: 13)
                                onClose()
                            } label: {
                                Image(systemName: "scope")
                                    .foregroundStyle(DirtTheme.ink)
                            }
                        }
                    }
                }
            }

            Section {
                if group.role == "owner" {
                    Button("Delete group", role: .destructive) {
                        Task { await groups.deleteGroup(group) }
                    }
                } else {
                    Button("Leave group", role: .destructive) {
                        Task { await groups.leaveGroup(group) }
                    }
                }
            }
        }
    }
}
