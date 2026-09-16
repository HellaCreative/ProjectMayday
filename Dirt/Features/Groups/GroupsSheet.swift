import SwiftUI
import CoreLocation

struct GroupsSheet: View {
    let onClose: () -> Void
    var onRoute: () -> Void = {}
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var newGroupName = ""
    @State private var joinCode = ""
    @State private var showCreateDialog = false
    @State private var showJoinDialog = false
    @State private var signInBusy = false
    @State private var signInError: String?

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
                    GroupDetailView(group: selected, onClose: onClose, onRoute: onRoute)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                } else {
                    groupList
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity.combined(with: .move(edge: .trailing))
                        ))
                }
            }
            .animation(DirtMotion.sheet, value: groups.selectedGroup?.id)
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
                handleSignIn(result)
            }
            .frame(minHeight: DirtHit.control)
            .padding(.horizontal, DirtSpace.section)
            .padding(.top, DirtSpace.tight)
            .disabled(signInBusy)
            .opacity(signInBusy ? 0.65 : 1)

            if signInBusy {
                ProgressView("Signing in…")
                    .tint(DirtTheme.orange)
                    .font(DirtType.helper)
            }

            if let signInError {
                Text(signInError)
                    .font(DirtType.helper)
                    .fontWeight(.semibold)
                    .foregroundStyle(DirtTheme.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DirtSpace.section)
                    .accessibilityLabel("Sign-in failed. \(signInError)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DirtSpace.section)
        .padding(.horizontal, DirtSpace.row)
        .dirtGroupingSurface(radius: DirtRadius.card)
        .padding(.horizontal, DirtSpace.group)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: DockSheetContentHeightKey.self, value: geo.size.height)
            }
        )
    }

    private func handleSignIn(_ result: Result<AppleCredential, Error>) {
        switch result {
        case let .success(credential):
            guard !signInBusy else { return }
            signInBusy = true
            signInError = nil
            Task {
                defer { signInBusy = false }
                do {
                    try await app.supabase.signInWithApple(
                        idToken: credential.idToken,
                        rawNonce: credential.rawNonce,
                        fullName: credential.fullName
                    )
                    await groups.refreshGroups()
                } catch {
                    signInError = AppleSignInFailure.message(from: error)
                }
            }
        case let .failure(error):
            signInError = AppleSignInFailure.message(from: error)
        }
    }

    private var groupList: some View {
        ScrollView {
            VStack(spacing: DirtSpace.tight) {
                Text("Share an invite code. Start sharing to put live positions on the map.")
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)

                if groups.isLoading && groups.groups.isEmpty {
                    ProgressView()
                        .tint(DirtTheme.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DirtSpace.inner)
                } else if groups.groups.isEmpty {
                    Text("No groups yet")
                        .font(DirtType.rowTitle)
                        .foregroundStyle(DirtTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DirtSpace.inner)
                        .dirtGroupingSurface(radius: DirtRadius.card)
                } else {
                    ForEach(Array(groups.groups.enumerated()), id: \.element.id) { index, group in
                        groupCard(group)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                            .animation(DirtMotion.island.delay(Double(min(index, 2)) * 0.05), value: groups.groups.count)
                    }
                }

                (dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: DirtSpace.inner))
                    : AnyLayout(HStackLayout(spacing: DirtSpace.inner))) {
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
                    .buttonStyle(DirtSecondaryButtonStyle())
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
            DirtMotion.light()
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
            .padding(.vertical, DirtSpace.tight)
            .frame(minHeight: DirtHit.min)
            .dirtGroupingSurface(radius: DirtRadius.card)
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
    var onRoute: () -> Void = {}
    @Environment(AppEnvironment.self) private var app
    @State private var expandedRider: String?
    @State private var locations: [String: String] = [:]
    @State private var locationKeys: [String: String] = [:]
    private var groups: GroupsViewModel { app.groups }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirtSpace.inner) {
                HStack {
                    Text("\(group.memberCount) riders · \(group.liveCount) sharing")
                        .font(DirtType.helper).foregroundStyle(DirtTheme.muted)
                    Spacer()
                }
                if let invite = group.inviteCode {
                    Button {
                        UIPasteboard.general.string = invite.lowercased()
                        app.planner.toast = "Invite code copied"
                    } label: {
                        HStack {
                            Label("Invite a rider", systemImage: "person.badge.plus")
                            Spacer()
                            Text(invite.lowercased()).monospaced()
                            Image(systemName: "doc.on.doc")
                        }.font(DirtType.rowTitle).frame(minHeight: DirtHit.min)
                    }
                    .buttonStyle(.plain).foregroundStyle(DirtTheme.action)
                    .padding(.horizontal, DirtSpace.row)
                    .dirtGroupingSurface()
                }

                ForEach(rosterMembers) { member in
                    riderRow(member)
                }

                if rosterMembers.isEmpty {
                    Text("No riders yet")
                        .font(DirtType.helper)
                        .foregroundStyle(DirtTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DirtSpace.group)
                        .dirtGroupingSurface(radius: DirtRadius.card)
                }

                if let error = groups.errorMessage {
                    Text(error).font(DirtType.helper).foregroundStyle(DirtTheme.danger)
                }

                Button(group.role == "owner" ? "Delete group" : "Leave group", role: .destructive) {
                    Task {
                        if group.role == "owner" { await groups.deleteGroup(group) }
                        else { await groups.leaveGroup(group) }
                    }
                }
                .disabled(groups.isMutatingGroup)
                .font(DirtType.helper)
                .frame(minHeight: DirtHit.min)
                .padding(.top, DirtSpace.tight)
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
        .task(id: groups.members.map { "\($0.id):\(locationKey($0)):\($0.isLive)" }.joined()) {
            // Resolve actual live locations serially. Offline rows never masquerade as current.
            for member in groups.members where member.isLive && locationKeys[member.id] != locationKey(member) {
                guard !Task.isCancelled, let lat = member.latitude, let lon = member.longitude else { continue }
                locations[member.id] = nil
                let key = locationKey(member)
                let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon))
                guard !Task.isCancelled else { return }
                locationKeys[member.id] = key
                if let mark = marks?.first {
                    locations[member.id] = mark.locality ?? mark.subAdministrativeArea ?? mark.name
                }
            }
        }
    }

    /// You first, then everyone else. If presence hasn't landed yet, still show a me-row
    /// so Start/Stop sharing isn't missing.
    private var rosterMembers: [GroupMemberRow] {
        let selfID = app.supabase.userID
        let others = groups.members.filter { $0.userID != selfID }
        if let own = groups.members.first(where: { $0.userID == selfID }) {
            return [own] + others
        }
        guard let selfID else { return others }
        return [
            GroupMemberRow(
                userID: selfID,
                role: group.role,
                displayName: ownDisplayName,
                isLive: groups.isSharing,
                latitude: nil,
                longitude: nil,
                status: groups.isSharing ? groups.status : "offline",
                lastSeenAt: nil,
                accuracyMeters: nil
            )
        ] + others
    }

    private var ownDisplayName: String {
        let name = app.supabase.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "You" : name
    }

    private func locationKey(_ member: GroupMemberRow) -> String {
        String(format: "%.3f,%.3f", member.latitude ?? 0, member.longitude ?? 0)
    }

    private func coordinateLabel(_ member: GroupMemberRow) -> String {
        guard let lat = member.latitude, let lon = member.longitude else { return "Unavailable" }
        return String(format: "%.3f, %.3f", lat, lon)
    }

    private func riderRow(_ member: GroupMemberRow) -> some View {
        let expanded = expandedRider == member.id
        let own = member.userID == app.supabase.userID
        let status = member.isLive ? (member.status ?? "riding") : "offline"
        let color: Color = !member.isLive
            ? DirtTheme.muted
            : (status == "riding"
                ? DirtTheme.navGreen
                : (status == "injured" || status == "unrepairable" ? DirtTheme.danger : DirtTheme.action))
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                DirtMotion.light()
                withAnimation(DirtMotion.affordance) { expandedRider = expanded ? nil : member.id }
            } label: {
                HStack(spacing: DirtSpace.inner) {
                    Circle()
                        .fill(member.isLive ? DirtTheme.navGreen : DirtTheme.muted.opacity(0.4))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(own ? ownDisplayName : member.displayName)
                            .font(DirtType.rowTitle)
                            .fontWeight(.bold)
                        if own {
                            Text("You")
                                .font(DirtType.helper)
                                .foregroundStyle(DirtTheme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current location")
                            .font(DirtType.helper)
                            .foregroundStyle(DirtTheme.muted)
                        Text(
                            member.isLive
                                ? (locationKeys[member.id] == locationKey(member)
                                    ? (locations[member.id] ?? coordinateLabel(member))
                                    : coordinateLabel(member))
                                : "Unavailable"
                        )
                        .font(DirtType.helper)
                        .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(member.isLive ? GroupsViewModel.statusLabel(status) : "Offline")
                        .font(DirtType.chip)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .foregroundStyle(DirtTheme.ink)
                .padding(.horizontal, DirtSpace.row)
                .padding(.vertical, DirtSpace.tight)
                .frame(minHeight: 62)
                .contentShape(RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(own ? "\(ownDisplayName), you" : member.displayName)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(own ? "Opens sharing and status" : "Opens rider actions")

            if expanded {
                riderRowActions(member, own: own)
            }
        }
        .background(expanded ? DirtTheme.wash : DirtTheme.groupingFill, in: RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                .stroke(own ? DirtTheme.orange.opacity(0.45) : DirtTheme.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func riderRowActions(_ member: GroupMemberRow, own: Bool) -> some View {
        VStack(alignment: .leading, spacing: DirtSpace.tight) {
            HStack(spacing: DirtSpace.inner) {
                if own {
                    Menu {
                        ForEach(GroupsViewModel.selectableStatuses, id: \.self) { status in
                            Button(GroupsViewModel.statusLabel(status)) { groups.setStatus(status) }
                        }
                    } label: {
                        Label("Status", systemImage: "slider.horizontal.3")
                    }
                    .dirtDropdownSurface()
                    .disabled(!groups.isSharing)
                    .accessibilityLabel("Share status")
                    .accessibilityHint(groups.isSharing ? "Choose the status your riders see" : "Start sharing to set status")
                    Spacer()
                    Button(groups.isSharing ? "Stop sharing" : "Start sharing") {
                        DirtMotion.medium()
                        withAnimation(DirtMotion.affordance) {
                            app.planner.toast = groups.toggleSharingFromUI()
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: DirtHit.min)
                    .foregroundStyle(groups.isSharing ? Color.white : DirtTheme.onOrange)
                    .background(
                        groups.isSharing ? DirtTheme.chrome : DirtTheme.orange,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityLabel(groups.isSharing ? "Stop sharing location" : "Start sharing location")
                } else {
                    Button {
                        if let lat = member.latitude, let lon = member.longitude {
                            app.mapState.fly(to: RouteCoordinate(longitude: lon, latitude: lat), zoom: 13)
                            onClose()
                        }
                    } label: {
                        Label("View on map", systemImage: "map")
                    }
                    Spacer()
                    Button {
                        guard let target = member.routeTarget(groupID: group.id) else { return }
                        app.planner.routeToMember(target)
                        onRoute()
                    } label: {
                        Label("Route to rider", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                }
            }
            .font(DirtType.chip)
            .fontWeight(.semibold)
            .buttonStyle(.plain)
            .tint(DirtTheme.action)
            .frame(minHeight: DirtHit.min)
            .disabled(!own && member.routeTarget(groupID: group.id) == nil)

            if own {
                Text(ownSharingHelper)
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let distress = groups.distressScopeCopy {
                    Text(distress)
                        .font(DirtType.helper)
                        .foregroundStyle(DirtTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, DirtSpace.row)
        .padding(.bottom, DirtSpace.inner)
    }

    private var ownSharingHelper: String {
        if groups.isSharing {
            return groups.isWaitingForLocation ? "Waiting for GPS" : groups.sharingScopeCopy
        }
        return "Share your position and status with this group."
    }
}
