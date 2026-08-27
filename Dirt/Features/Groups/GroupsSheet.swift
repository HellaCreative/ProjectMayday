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
        VStack(spacing: 0) {
            DirtSheetHeader(
                title: groups.selectedGroup?.name ?? "Groups",
                onBack: groups.selectedGroup == nil ? nil : { groups.closeDetail() }
            )

            Group {
                if !app.supabase.isSignedIn {
                    signInPrompt
                } else if let selected = groups.selectedGroup {
                    GroupDetailView(group: selected, onClose: onClose)
                } else {
                    groupList
                }
            }
        }
        .task {
            if app.supabase.isSignedIn {
                await groups.refreshGroups()
            }
        }
        .onDisappear {
            // Closing the sheet resets to the list panel.
            groups.closeDetail()
        }
    }

    /// The rest of DIRT works signed out. Groups can't: riders have to be findable by
    /// each other, which needs an account. So the ask happens here, with the button in
    /// reach — sending riders off to Profile to hunt for it was the old behaviour.
    private var signInPrompt: some View {
        VStack(spacing: DirtSpace.inner) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(DirtTheme.muted)
            Text("Groups need an account")
                .font(DirtType.rowTitle)
                .fontWeight(.bold)
                .foregroundStyle(DirtTheme.ink)
            Text("Sign in so your riders can find you. The rest of DIRT works signed out.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DirtSpace.section)

            AppleSignInButton { result in
                guard case let .success(credential) = result else { return }
                Task {
                    try? await app.supabase.signInWithApple(
                        idToken: credential.idToken,
                        rawNonce: credential.rawNonce,
                        fullName: credential.fullName
                    )
                    await groups.refreshGroups()
                }
            }
            .frame(minHeight: DirtHit.control)
            .padding(.horizontal, DirtSpace.section)
            .padding(.top, DirtSpace.tight)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DirtSpace.section)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: DockSheetContentHeightKey.self, value: geo.size.height)
            }
        )
    }

    private var groupList: some View {
        ScrollView {
            VStack(spacing: DirtSpace.inner) {
                Text("Share an invite code. Start sharing to put live positions on the map.")
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if groups.isLoading && groups.groups.isEmpty {
                    ProgressView()
                        .tint(DirtTheme.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DirtSpace.group)
                } else if groups.groups.isEmpty {
                    Text("No groups yet")
                        .font(DirtType.rowTitle)
                        .foregroundStyle(DirtTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DirtSpace.group)
                        .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                                .stroke(DirtTheme.hairline, lineWidth: 1)
                        )
                } else {
                    ForEach(groups.groups) { group in
                        groupCard(group)
                    }
                }

                HStack(spacing: DirtSpace.inner) {
                    Button {
                        showCreateDialog = true
                    } label: {
                        Label("Create", systemImage: "person.2.badge.plus.fill")
                    }
                    .buttonStyle(DirtCTAStyle.brand())

                    Button {
                        showJoinDialog = true
                    } label: {
                        Label("Join", systemImage: "arrow.right.square.fill")
                    }
                    .buttonStyle(DirtCTAStyle(fill: DirtTheme.chrome))
                }
                .disabled(groups.isMutatingGroup)
                .padding(.top, DirtSpace.tight)

                if groups.isMutatingGroup {
                    HStack(spacing: DirtSpace.tight) {
                        ProgressView().tint(DirtTheme.orange)
                        Text("Updating your groups…")
                            .font(DirtType.helper)
                            .foregroundStyle(DirtTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }

                if let error = groups.errorMessage {
                    Text(error)
                        .font(DirtType.helper)
                        .fontWeight(.semibold)
                        .foregroundStyle(DirtTheme.danger)
                }
            }
            .padding(.horizontal, DirtSpace.group)
            .padding(.top, DirtSpace.inner)
            .padding(.bottom, DirtSpace.group)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: DockSheetContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
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
            HStack(spacing: DirtSpace.inner) {
                VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                    Text(group.name)
                        .font(DirtType.rowTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(DirtTheme.ink)
                    Text(groupMeta(group))
                        .font(DirtType.metricInline)
                        .foregroundStyle(DirtTheme.muted)
                }
                Spacer(minLength: DirtSpace.tight)
                if group.liveCount > 0 {
                    HStack(spacing: DirtSpace.tight) {
                        Circle().fill(DirtTheme.navGreen).frame(width: 7, height: 7)
                        Text("\(group.liveCount) live")
                            .font(DirtType.chip)
                            .fontWeight(.bold)
                            .foregroundStyle(DirtTheme.navGreen)
                    }
                    .padding(.horizontal, DirtSpace.inner)
                    .padding(.vertical, DirtSpace.tight)
                    .background(DirtTheme.navGreen.opacity(0.12), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DirtTheme.muted)
            }
            .padding(.horizontal, DirtSpace.row)
            .frame(minHeight: DirtHit.control)
            .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                    .stroke(DirtTheme.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens group details")
    }

    private func groupMeta(_ group: GroupSummary) -> String {
        var meta = "\(group.memberCount) members"
        if let code = group.inviteCode, !code.isEmpty {
            meta += " · \(code.lowercased())"
        }
        return meta
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
                    HStack(spacing: DirtSpace.inner) {
                        Text(invite)
                            .font(DirtType.metric)
                            .tracking(3)
                            .textCase(.uppercase)
                            .foregroundStyle(DirtTheme.ink)
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = invite
                            app.planner.toast = "Invite code copied"
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DirtTheme.orange)
                                .frame(width: DirtHit.min, height: DirtHit.min)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Copy invite code")
                    }
                }
                .listRowBackground(DirtTheme.rowFill)
            }

            Section("Live sharing") {
                if groups.isSharing {
                    if groups.isWaitingForLocation {
                        Label("Waiting for a current GPS position", systemImage: "location.magnifyingglass")
                            .font(DirtType.helper)
                            .foregroundStyle(DirtTheme.muted)
                    }
                    Picker("Status", selection: Binding(
                        get: { groups.status },
                        set: { groups.setStatus($0) }
                    )) {
                        ForEach(statuses, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .font(DirtType.rowTitle)
                    Button("Stop sharing") { groups.stopSharing() }
                        .buttonStyle(DirtCTAStyle(fill: DirtTheme.chrome))
                        .listRowBackground(Color.clear)
                } else {
                    Button("Start sharing") { groups.startSharing() }
                        .buttonStyle(DirtCTAStyle.brand())
                        .listRowBackground(Color.clear)
                }
            }
            .listRowBackground(DirtTheme.rowFill)

            Section("Riders") {
                if groups.members.isEmpty {
                    Text("No riders yet")
                        .font(DirtType.helper)
                        .foregroundStyle(DirtTheme.muted)
                } else {
                    ForEach(groups.members) { member in
                        riderRow(member)
                    }
                }
            }
            .listRowBackground(DirtTheme.rowFill)

            Section {
                if group.role == "owner" {
                    Button("Delete group", role: .destructive) {
                        Task { await groups.deleteGroup(group) }
                    }
                    .disabled(groups.isMutatingGroup)
                } else {
                    Button("Leave group", role: .destructive) {
                        Task { await groups.leaveGroup(group) }
                    }
                    .disabled(groups.isMutatingGroup)
                }
            }
            .listRowBackground(DirtTheme.rowFill)
        }
        // Detail needs the full sheet — report a large height so adaptive panel opens to max.
        .preference(key: DockSheetContentHeightKey.self, value: 10_000)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    private func riderRow(_ member: GroupMemberRow) -> some View {
        HStack(spacing: DirtSpace.inner) {
            Circle()
                .fill(member.isLive ? DirtTheme.navGreen : DirtTheme.muted.opacity(0.4))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                Text(member.displayName)
                    .font(DirtType.rowTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.ink)
                Text(memberDetail(member))
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DirtSpace.tight)
            if member.isLive, let lat = member.latitude, let lon = member.longitude,
               member.userID != app.supabase.userID {
                Button("Details") {
                    groups.selectPeer(member)
                }
                .buttonStyle(DirtChipStyle(isActive: true))

                Button {
                    app.mapState.fly(to: RouteCoordinate(longitude: lon, latitude: lat), zoom: 13)
                    onClose()
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DirtTheme.ink)
                        .frame(width: DirtHit.min, height: DirtHit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show on map")
            }
        }
        .frame(minHeight: DirtHit.min)
    }

    private func memberDetail(_ member: GroupMemberRow) -> String {
        if member.isLive {
            return "\(member.role.capitalized) · \(GroupsViewModel.statusLabel(member.status ?? "available"))"
        }
        let seen = GroupsViewModel.lastSeenLabel(member.lastSeenAt)
        return "\(member.role.capitalized) · Offline · Seen \(seen)"
    }
}
