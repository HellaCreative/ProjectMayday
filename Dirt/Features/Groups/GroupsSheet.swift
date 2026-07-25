import SwiftUI

struct GroupsSheet: View {
    let onClose: () -> Void
    @Environment(AppEnvironment.self) private var app
    @State private var newGroupName = ""
    @State private var joinCode = ""

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
        List {
            Section("Your groups") {
                if groups.groups.isEmpty && !groups.isLoading {
                    Text("No groups yet — create one or join with an invite code.")
                        .font(.dirtUI(12))
                        .foregroundStyle(DirtTheme.muted)
                }
                ForEach(groups.groups) { group in
                    Button {
                        groups.openDetail(group)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                    .font(.dirtUI(14, weight: .bold))
                                    .foregroundStyle(DirtTheme.ink)
                                Text("\(group.memberCount) riders · \(group.liveCount) live")
                                    .font(.dirtMono(11, weight: .semibold))
                                    .foregroundStyle(group.liveCount > 0 ? DirtTheme.navGreen : DirtTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DirtTheme.muted)
                        }
                    }
                }
            }

            Section("Create a group") {
                TextField("Group name", text: $newGroupName)
                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    newGroupName = ""
                    Task { await groups.createGroup(named: name) }
                }
                .buttonStyle(DirtCTAStyle(fill: DirtTheme.orange))
                .listRowBackground(Color.clear)
            }

            Section("Join with invite code") {
                TextField("6-character code", text: $joinCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.dirtMono(15, weight: .bold))
                Button("Join") {
                    let code = joinCode
                    joinCode = ""
                    Task { await groups.joinGroup(code: code) }
                }
                .buttonStyle(DirtCTAStyle(fill: DirtTheme.orange))
                .listRowBackground(Color.clear)
            }

            if let error = groups.errorMessage {
                Section {
                    Text(error)
                        .font(.dirtUI(12, weight: .semibold))
                        .foregroundStyle(DirtTheme.danger)
                }
            }
        }
        .refreshable { await groups.refreshGroups() }
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
