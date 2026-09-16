import SwiftUI
import CoreLocation
import MapKit

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
    var onRoute: () -> Void = {}
    @Environment(AppEnvironment.self) private var app
    @State private var expandedRider: String?
    @State private var locations: [String: String] = [:]
    @State private var locationKeys: [String: String] = [:]
    private var groups: GroupsViewModel { app.groups }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    }.font(DirtType.rowTitle).frame(minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(DirtTheme.action)
            }
            ScrollView {
                VStack(spacing: DirtSpace.inner) {
                    ForEach(rosterMembers) { member in riderRow(member) }
                    if rosterMembers.isEmpty {
                        Text("No riders yet")
                            .font(DirtType.helper)
                            .foregroundStyle(DirtTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DirtSpace.group)
                            .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                                    .stroke(DirtTheme.hairline, lineWidth: 1)
                            )
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
                    .font(DirtType.helper).frame(minHeight: DirtHit.min).padding(.top, DirtSpace.tight)
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: DockSheetContentHeightKey.self, value: geo.size.height + 88)
                })
            }
        }
        .padding(.horizontal, DirtSpace.group)
        .task(id: groups.members.map { "\($0.id):\(locationKey($0)):\($0.isLive)" }.joined()) {
            // Resolve actual live locations serially. Offline rows never masquerade as current.
            for member in groups.members where member.isLive && locationKeys[member.id] != locationKey(member) {
                guard !Task.isCancelled, let lat = member.latitude, let lon = member.longitude else { continue }
                locations[member.id] = nil
                let key = locationKey(member)
                let marks = try? await MKReverseGeocodingRequest(location: CLLocation(latitude: lat, longitude: lon))?.mapItems
                guard !Task.isCancelled else { return }
                locationKeys[member.id] = key
                if let mark = marks?.first {
                    let representations = mark.addressRepresentations
                    locations[member.id] = representations?.cityName
                        ?? representations?.cityWithContext
                        ?? mark.name
                }
            }
        }
    }

    private var rosterMembers: [GroupMemberRow] {
        let selfID = app.supabase.userID
        let others = groups.members.filter { $0.userID != selfID }
        if let own = groups.members.first(where: { $0.userID == selfID }) {
            return [own] + others
        }
        return others
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
        let color: Color = !member.isLive ? DirtTheme.muted : (status == "riding" ? DirtTheme.navGreen : (status == "injured" || status == "unrepairable" ? DirtTheme.danger : DirtTheme.action))
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                DirtMotion.light()
                withAnimation(DirtMotion.affordance) { expandedRider = expanded ? nil : member.id }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(member.isLive ? DirtTheme.navGreen : DirtTheme.muted.opacity(0.4))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName).font(DirtType.rowTitle).fontWeight(.bold)
                        if own { Text("You").font(.caption2).foregroundStyle(DirtTheme.muted) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current location").font(.caption2).foregroundStyle(DirtTheme.muted)
                        Text(member.isLive ? (locationKeys[member.id] == locationKey(member) ? (locations[member.id] ?? coordinateLabel(member)) : coordinateLabel(member)) : "Unavailable")
                            .font(.caption).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(member.isLive ? GroupsViewModel.statusLabel(status) : "Offline")
                        .font(.caption.weight(.semibold)).foregroundStyle(color)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .foregroundStyle(DirtTheme.ink)
                .padding(.horizontal, 8).frame(minHeight: 62)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                HStack(spacing: 8) {
                    if own {
                        Menu {
                            ForEach(GroupsViewModel.selectableStatuses, id: \.self) { status in
                                Button(GroupsViewModel.statusLabel(status)) { groups.setStatus(status) }
                            }
                        } label: { Label("Status", systemImage: "slider.horizontal.3") }
                        .dirtDropdownSurface()
                        .disabled(!groups.isSharing)
                        Spacer()
                        Button(groups.isSharing ? "Stop sharing" : "Start sharing") {
                            if groups.isSharing { groups.stopSharing() } else { groups.startSharing() }
                        }
                        .padding(.horizontal, 10).frame(minHeight: 44)
                        .foregroundStyle(groups.isSharing ? Color.white : DirtTheme.onOrange)
                        .background(groups.isSharing ? DirtTheme.chrome : DirtTheme.orange, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        Button {
                            if let lat = member.latitude, let lon = member.longitude {
                                app.mapState.fly(to: RouteCoordinate(longitude: lon, latitude: lat), zoom: 13)
                                onClose()
                            }
                        } label: { Label("View on map", systemImage: "map") }
                        Spacer()
                        Button {
                            guard let lat = member.latitude, let lon = member.longitude, let seen = member.lastSeenAt else { return }
                            app.planner.routeToMember(GroupMemberRouteTarget(groupID: group.id, userID: member.userID, displayName: member.displayName, coordinate: RouteCoordinate(longitude: lon, latitude: lat), lastSeenAt: seen, accuracyMeters: member.accuracyMeters, isLive: member.isLive))
                            onRoute()
                        } label: { Label("Route to rider", systemImage: "arrow.triangle.turn.up.right.diamond") }
                    }
                }
                .font(.caption.weight(.semibold)).buttonStyle(.plain).tint(DirtTheme.action)
                .frame(minHeight: 44).padding(.horizontal, 10).padding(.bottom, 6)
                .disabled(!own && (!member.isLive || member.latitude == nil || member.longitude == nil))
                if own && groups.isWaitingForLocation {
                    Text("Waiting for GPS").font(DirtType.helper).padding(8)
                }
            }
        }
        .padding(.vertical, DirtSpace.tight)
        .background(expanded ? DirtTheme.wash : DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                .stroke(own ? DirtTheme.orange.opacity(0.45) : DirtTheme.hairline, lineWidth: 1)
        }
    }
}
