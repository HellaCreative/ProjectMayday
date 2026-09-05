import CoreLocation
import Foundation
import Observation
import Supabase

struct GroupSummary: Identifiable {
    let id: String
    let name: String
    let ownerID: String
    let inviteCode: String?
    var role: String
    var memberCount: Int
    var liveCount: Int
}

struct GroupMemberRow: Identifiable {
    let userID: String
    let role: String
    let displayName: String
    var isLive: Bool
    var latitude: Double?
    var longitude: Double?
    var status: String?
    var lastSeenAt: Date?
    var accuracyMeters: Double?

    var id: String { userID }
}

/// Map / roster selection for a live peer.
struct SelectedGroupPeer: Identifiable, Equatable {
    let groupID: String
    let userID: String
    let displayName: String
    let groupName: String
    let status: String
    let statusText: String
    let lastSeenLabel: String
    let latitude: Double
    let longitude: Double
    let lastSeenAt: Date
    let accuracyMeters: Double?

    var id: String { userID }

    var routeTarget: GroupMemberRouteTarget {
        GroupMemberRouteTarget(
            groupID: groupID,
            userID: userID,
            displayName: displayName,
            coordinate: RouteCoordinate(longitude: longitude, latitude: latitude),
            lastSeenAt: lastSeenAt,
            accuracyMeters: accuracyMeters,
            isLive: true
        )
    }
}

/// Peer distress / route-report alert shown on the map HUD.
struct PeerAlertBanner: Identifiable, Equatable {
    let id: String
    let userID: String
    let displayName: String
    let status: String
    let statusText: String
    let groupID: String
    let groupName: String
    let latitude: Double
    let longitude: Double
    let message: String?

    var title: String { "\(displayName) · \(statusText)" }
    var subtitle: String {
        if let message, !message.isEmpty {
            return "\(groupName) · \(message)"
        }
        return "\(groupName) · tap to view last known location"
    }
}

/// Groups. Presence is persisted through `rider_presence`
/// and mirrored over private Realtime channel `group:{id}` (presence + location /
/// alert / sharing_off broadcast). A slower table poll remains as fallback.
@Observable
final class GroupsViewModel {
    private let supabase: SupabaseService
    private let location: LocationService
    private let mapState: MapState

    /// Optional toast sink (wired from AppEnvironment → planner.toast).
    var onToast: ((String) -> Void)?
    /// Latest validated peer position. The map may move immediately; navigation
    /// decides when a frozen route is safe to refresh.
    var onPeerLocationUpdate: ((GroupMemberRouteTarget) -> Void)?
    var onPeerSharingEnded: ((String, String) -> Void)?

    private(set) var groups: [GroupSummary] = []
    private(set) var selectedGroup: GroupSummary?
    private(set) var members: [GroupMemberRow] = []
    private(set) var peerAlerts: [PeerAlertBanner] = []
    private(set) var isLoading = false
    private(set) var isMutatingGroup = false
    private(set) var isSharing = false
    private(set) var isWaitingForLocation = false
    private(set) var realtimeConnected = false
    /// Live peer selected from the map (or roster) — details card, not auto-route.
    var selectedPeer: SelectedGroupPeer?
    var status = "riding"
    /// Live-sharing card presented over the map (owned here so the map control
    /// stack can open it and `RootView` can place it as a bottom card).
    var sharingPanelOpen = false
    var errorMessage: String?

    private var shareTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Group whose live peers stay on the map after the sheet closes
    /// while the group channel is active.
    private var mapTrackedGroupID: String?

    @ObservationIgnored private var realtimeChannels: [String: RealtimeChannelV2] = [:]
    @ObservationIgnored private var channelListenTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var connectingGroupIDs: Set<String> = []
    @ObservationIgnored private var groupRefreshGeneration = 0
    @ObservationIgnored private var memberRefreshGeneration = 0
    /// Last fresh GPS fix accepted during the active sharing session. Stationary
    /// phones may not receive a newly timestamped fix for every heartbeat.
    @ObservationIgnored private var lastSharingFix: CLLocation?
    /// Last trustworthy fix accepted during this app session. Stopping sharing
    /// ends every network heartbeat immediately, but keeping the coordinate
    /// locally lets a rider leave/rejoin a group while stationary without
    /// waiting for Core Location to emit an identical fix again.
    @ObservationIgnored private var lastTrustedFix: CLLocation?
    @ObservationIgnored private var waitingForFixLogged = false
    @ObservationIgnored private var livePresenceLogged = false

    private static func sharingPreferenceKey(userID: String) -> String {
        "dirt.groups.sharing-requested.\(userID)"
    }

    private static func sharingPreference(userID: String) -> Bool? {
        UserDefaults.standard.object(forKey: sharingPreferenceKey(userID: userID)) as? Bool
    }

    private static func setSharingPreference(_ enabled: Bool, userID: String) {
        UserDefaults.standard.set(enabled, forKey: sharingPreferenceKey(userID: userID))
    }

    init(supabase: SupabaseService, location: LocationService, mapState: MapState) {
        self.supabase = supabase
        self.location = location
        self.mapState = mapState
    }

    /// Resolves a map rider/alert annotation id to the roster row when possible.
    func member(forRiderMarkerID markerID: String) -> GroupMemberRow? {
        if markerID.hasPrefix("rider:") {
            let userID = String(markerID.dropFirst("rider:".count))
            return members.first { $0.userID == userID }
        }
        if markerID.hasPrefix("alert:") {
            let alertID = String(markerID.dropFirst("alert:".count))
            guard let alert = peerAlerts.first(where: { $0.id == alertID }) else { return nil }
            return members.first { $0.userID == alert.userID }
        }
        return nil
    }

    /// Open member details from a map rider pin.
    func selectPeer(fromRiderMarkerID markerID: String) {
        guard let member = member(forRiderMarkerID: markerID),
              let lat = member.latitude,
              let lon = member.longitude else { return }
        presentPeer(member, latitude: lat, longitude: lon)
    }

    /// Open member details from the group roster.
    func selectPeer(_ member: GroupMemberRow) {
        guard member.isLive,
              let lat = member.latitude,
              let lon = member.longitude else { return }
        presentPeer(member, latitude: lat, longitude: lon)
    }

    func clearSelectedPeer() {
        selectedPeer = nil
    }

    private func presentPeer(_ member: GroupMemberRow, latitude: Double, longitude: Double) {
        guard member.isLive,
              GroupPresencePolicy.isValidCoordinate(latitude: latitude, longitude: longitude),
              let groupID = mapTrackedGroupID ?? selectedGroup?.id,
              let lastSeenAt = member.lastSeenAt else { return }
        let status = {
            let raw = (member.status ?? "riding").trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.normalizedStatus(raw)
        }()
        selectedPeer = SelectedGroupPeer(
            groupID: groupID,
            userID: member.userID,
            displayName: member.displayName,
            groupName: selectedGroup?.name
                ?? groups.first(where: { $0.id == mapTrackedGroupID })?.name
                ?? "Group",
            status: status,
            statusText: Self.statusLabel(status),
            lastSeenLabel: Self.lastSeenLabel(member.lastSeenAt),
            latitude: latitude,
            longitude: longitude,
            lastSeenAt: lastSeenAt,
            accuracyMeters: member.accuracyMeters
        )
    }

    static func statusLabel(_ status: String) -> String {
        switch normalizedStatus(status) {
        case "riding": return "Riding"
        case "flat_tire": return "Flat Tire"
        case "dead_battery": return "Dead Battery"
        case "unrepairable": return "Unrepairable"
        case "breakdown": return "Breakdown"
        case "injured": return "Injured"
        case "stuck": return "Stuck"
        case "offline": return "Offline"
        default: return "Riding"
        }
    }

    static let selectableStatuses = [
        "riding", "flat_tire", "dead_battery", "unrepairable", "injured", "stuck"
    ]

    /// Keep older app/database values readable while all active clients move to
    /// the clearer rider-facing vocabulary.
    static func normalizedStatus(_ status: String) -> String {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty || value == "available" ? "riding" : value
    }

    static func isMechanicalDistressStatus(_ status: String) -> Bool {
        ["breakdown", "flat_tire", "dead_battery", "unrepairable"]
            .contains(normalizedStatus(status))
    }

    static func lastSeenLabel(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    func focusPeerAlert(_ alert: PeerAlertBanner) {
        mapState.fly(to: RouteCoordinate(longitude: alert.longitude, latitude: alert.latitude), zoom: 13.5)
        dismissPeerAlert(alert.id)
    }

    func dismissPeerAlert(_ alertID: String) {
        peerAlerts.removeAll { $0.id == alertID }
        paintGroupOverlays()
        Task { await resolveAlertOnServer(id: alertID) }
    }

    private var client: SupabaseClient {
        get throws {
            guard let client = supabase.client else { throw SupabaseServiceError.notReady }
            return client
        }
    }

    // MARK: - Decodable rows (column names match Postgres exactly)

    private struct MembershipRow: Decodable {
        struct GroupRow: Decodable {
            let id: String
            let name: String
            let owner_id: String
            let invite_code: String?
            let deleted_at: String?
        }

        let role: String
        let groups: GroupRow?
    }

    private struct MemberCountRow: Decodable {
        let group_id: String
        let user_id: String
    }

    private struct PresenceRow: Decodable {
        let user_id: String
        let sharing_enabled: Bool?
        let status: String?
        let latitude: Double?
        let longitude: Double?
        let accuracy_m: Double?
        let last_seen_at: String?
        let updated_at: String?

        var lastSeenDate: Date? {
            last_seen_at.flatMap { ISO8601DateFormatter.flexible.parse($0) }
        }

        var heartbeatDate: Date? {
            updated_at.flatMap { ISO8601DateFormatter.flexible.parse($0) }
        }

        var locationFix: CLLocation? {
            guard let latitude,
                  let longitude,
                  let accuracy_m,
                  let timestamp = lastSeenDate,
                  GroupPresencePolicy.isValidCoordinate(latitude: latitude, longitude: longitude),
                  accuracy_m >= 0,
                  accuracy_m <= GroupPresencePolicy.maximumHorizontalAccuracy
            else { return nil }
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: 0,
                horizontalAccuracy: accuracy_m,
                verticalAccuracy: -1,
                course: -1,
                speed: -1,
                timestamp: timestamp
            )
        }

        var isLive: Bool {
            GroupPresencePolicy.isLive(
                sharingEnabled: sharing_enabled == true,
                latitude: latitude,
                longitude: longitude,
                accuracyMeters: accuracy_m,
                heartbeatAt: heartbeatDate ?? lastSeenDate
            )
        }
    }

    private struct MemberRowDecodable: Decodable {
        struct ProfileRow: Decodable {
            let display_name: String?
        }

        let user_id: String
        let role: String
        let profiles: ProfileRow?
    }

    private struct AlertRow: Decodable {
        let id: String
        let group_id: String
        let user_id: String
        let status: String
        let message: String?
        let latitude: Double?
        let longitude: Double?
        let created_at: String?
        let resolved_at: String?
    }

    private struct AlertInsert: Encodable {
        let group_id: String
        let user_id: String
        let status: String
        let message: String?
        let latitude: Double?
        let longitude: Double?
    }

    private struct AlertResolveUpdate: Encodable {
        let resolved_at: String
    }

    private struct LocationBroadcast: Codable {
        let userId: String
        let displayName: String?
        let lng: Double?
        let lat: Double?
        let heading: Double?
        let speed: Double?
        let accuracy: Double?
        let status: String?
        let lastSeenAt: String?
        let heartbeatAt: String?
        let groupId: String?
        let groupName: String?
    }

    private struct AlertBroadcast: Codable {
        let alertId: String?
        let userId: String
        let displayName: String?
        let status: String
        let groupId: String?
        let groupName: String?
        let lng: Double?
        let lat: Double?
        let createdAt: String?
        let message: String?
    }

    private struct SharingOffBroadcast: Codable {
        let userId: String
    }

    private struct MembershipChangedBroadcast: Codable {
        let userId: String
        let action: String
    }

    // MARK: - List

    func refreshGroups() async {
        guard let userID = supabase.userID else {
            handleSignedOut()
            return
        }
        groupRefreshGeneration += 1
        let requestGeneration = groupRefreshGeneration
        isLoading = true
        defer {
            if groupRefreshGeneration == requestGeneration { isLoading = false }
        }
        do {
            let rows: [MembershipRow] = try await client
                .from("group_members")
                .select("role, groups(id,name,owner_id,invite_code,deleted_at)")
                .eq("user_id", value: userID)
                .execute()
                .value
            var summaries = rows.compactMap { row -> GroupSummary? in
                guard let group = row.groups, group.deleted_at == nil else { return nil }
                return GroupSummary(
                    id: group.id,
                    name: group.name,
                    ownerID: group.owner_id,
                    inviteCode: group.invite_code,
                    role: row.role,
                    memberCount: 0,
                    liveCount: 0
                )
            }
            let ids = summaries.map(\.id)
            var ownPresence: PresenceRow?
            if !ids.isEmpty {
                let memberships: [MemberCountRow] = try await client
                    .from("group_members")
                    .select("group_id,user_id")
                    .in("group_id", values: ids)
                    .execute()
                    .value
                let userIDs = Array(Set(memberships.map(\.user_id)))
                let presence: [PresenceRow] = try await client
                    .from("rider_presence")
                    .select("user_id,sharing_enabled,status,latitude,longitude,accuracy_m,last_seen_at,updated_at")
                    .in("user_id", values: userIDs)
                    .execute()
                    .value
                ownPresence = presence.first(where: { $0.user_id == userID })
                let liveUsers = Set(presence.filter(\.isLive).map(\.user_id))
                for index in summaries.indices {
                    let groupMembers = memberships.filter { $0.group_id == summaries[index].id }
                    summaries[index].memberCount = groupMembers.count
                    summaries[index].liveCount = groupMembers.filter { liveUsers.contains($0.user_id) }.count
                }
            }
            guard groupRefreshGeneration == requestGeneration,
                  supabase.userID == userID else { return }
            groups = summaries
            // Sharing has no valid audience once the rider leaves or deletes
            // their final group. End it immediately so the UI, persisted
            // preference, GPS background claim, and server presence stay in
            // agreement.
            if summaries.isEmpty, isSharing {
                stopSharing()
            }
            restoreSharingIntentIfNeeded(userID: userID, presence: ownPresence)
            let activeIDs = Set(summaries.map(\.id))
            if let tracked = mapTrackedGroupID, !activeIDs.contains(tracked) {
                stopMapTracking()
            }
            if let selected = selectedGroup,
               let refreshed = summaries.first(where: { $0.id == selected.id }) {
                selectedGroup = refreshed
            } else if selectedGroup != nil {
                selectedGroup = nil
            }
            errorMessage = nil
            // Subscribe even when self is not sharing so you still see live peers.
            await ensureRealtimeForAllGroups()
            await ensureMapTrackingIfNeeded()
        } catch {
            guard groupRefreshGeneration == requestGeneration,
                  supabase.userID == userID else { return }
            errorMessage = "Could not load your riding groups."
        }
    }

    /// Without opening Group detail, still poll/paint the first group so
    /// non-sharing members can see who is live.
    private func ensureMapTrackingIfNeeded() async {
        guard mapTrackedGroupID == nil, let first = groups.first else { return }
        mapTrackedGroupID = first.id
        startPresencePolling(groupID: first.id)
        await refreshMembers(groupID: first.id)
        await fetchPeerAlerts(groupID: first.id)
    }

    func createGroup(named name: String) async {
        guard supabase.userID != nil, !isMutatingGroup else { return }
        let cleaned = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 60 else {
            errorMessage = "Group names must be between 1 and 60 characters."
            return
        }
        isMutatingGroup = true
        defer { isMutatingGroup = false }
        do {
            try await client
                .rpc("create_group", params: ["p_name": cleaned])
                .execute()
            await refreshGroups()
        } catch {
            errorMessage = "The group could not be created."
        }
    }

    func joinGroup(code rawCode: String) async {
        guard !isMutatingGroup else { return }
        let previousGroupIDs = Set(groups.map(\.id))
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code.wholeMatch(of: /[a-z0-9]{6}/) != nil else {
            errorMessage = "Invite codes are six lowercase letters or numbers."
            return
        }
        isMutatingGroup = true
        defer { isMutatingGroup = false }
        do {
            try await client
                .rpc("join_group_by_invite_code", params: ["p_invite_code": code])
                .execute()
            await refreshGroups()
            if let userID = supabase.userID {
                for group in groups where !previousGroupIDs.contains(group.id) {
                    await broadcastMembershipChanged(
                        userID: userID,
                        action: "joined",
                        groupID: group.id
                    )
                }
            }
        } catch {
            errorMessage = "No active riding group was found for that code."
        }
    }

    func leaveGroup(_ group: GroupSummary) async {
        guard !isMutatingGroup else { return }
        isMutatingGroup = true
        defer { isMutatingGroup = false }
        do {
            try await client.rpc("leave_group", params: ["p_group_id": group.id]).execute()
            if let userID = supabase.userID {
                await broadcastMembershipChanged(
                    userID: userID,
                    action: "left",
                    groupID: group.id
                )
            }
            await closeRealtimeChannel(groupID: group.id)
            stopMapTracking()
            selectedGroup = nil
            await refreshGroups()
        } catch {
            errorMessage = "You could not leave this group right now."
        }
    }

    func deleteGroup(_ group: GroupSummary) async {
        guard !isMutatingGroup else { return }
        isMutatingGroup = true
        defer { isMutatingGroup = false }
        do {
            try await client.rpc("delete_group", params: ["p_group_id": group.id]).execute()
            await closeRealtimeChannel(groupID: group.id)
            stopMapTracking()
            selectedGroup = nil
            await refreshGroups()
        } catch {
            errorMessage = "The group could not be deleted."
        }
    }

    // MARK: - Detail

    func openDetail(_ group: GroupSummary) {
        if mapTrackedGroupID != group.id {
            memberRefreshGeneration += 1
            members = []
            peerAlerts = []
            selectedPeer = nil
            clearGroupOverlays()
        }
        selectedGroup = group
        mapTrackedGroupID = group.id
        startPresencePolling(groupID: group.id)
        Task {
            await ensureRealtimeChannel(groupID: group.id)
            await refreshMembers(groupID: group.id)
            await fetchPeerAlerts(groupID: group.id)
        }
    }

    func closeDetail() {
        selectedGroup = nil
        // Keep polling + pins for the last opened group so peers stay visible
        // on the map while riding. Leave/delete clears tracking.
        if let mapTrackedGroupID {
            startPresencePolling(groupID: mapTrackedGroupID)
        } else {
            members = []
            pollTask?.cancel()
            pollTask = nil
            clearGroupOverlays()
        }
    }

    private func startPresencePolling(groupID: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.mapTrackedGroupID == groupID {
                await self.refreshMembers(groupID: groupID)
                // While detail is visible, keep membership joins/leaves feeling
                // immediate even if a Realtime roster signal is missed. Once
                // detail closes, return to the inexpensive safety heartbeat.
                let detailIsVisible = self.selectedGroup?.id == groupID
                let seconds: Double
                if detailIsVisible {
                    seconds = 5
                } else {
                    seconds = self.realtimeChannels[groupID] != nil ? 30 : 10
                }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func stopMapTracking() {
        memberRefreshGeneration += 1
        mapTrackedGroupID = nil
        members = []
        peerAlerts = []
        selectedPeer = nil
        pollTask?.cancel()
        pollTask = nil
        clearGroupOverlays()
    }

    private func refreshMembers(groupID: String) async {
        memberRefreshGeneration += 1
        let requestGeneration = memberRefreshGeneration
        do {
            let rows: [MemberRowDecodable] = try await client
                .from("group_members")
                .select("user_id,role,profiles(display_name)")
                .eq("group_id", value: groupID)
                .execute()
                .value
            let userIDs = rows.map(\.user_id)
            let presence: [PresenceRow] = userIDs.isEmpty ? [] : try await client
                .from("rider_presence")
                .select("user_id,sharing_enabled,status,latitude,longitude,accuracy_m,last_seen_at,updated_at")
                .in("user_id", values: userIDs)
                .execute()
                .value
            let presenceByUser = Dictionary(uniqueKeysWithValues: presence.map { ($0.user_id, $0) })
            let namesByUser = await fetchDisplayNames(for: userIDs)
            let nextMembers = rows.map { row in
                let p = presenceByUser[row.user_id]
                let nested = row.profiles?.display_name
                let fetched = namesByUser[row.user_id]
                return GroupMemberRow(
                    userID: row.user_id,
                    role: row.role,
                    displayName: Self.resolvedDisplayName(nested ?? fetched),
                    isLive: p?.isLive ?? false,
                    latitude: p?.latitude,
                    longitude: p?.longitude,
                    status: {
                        let raw = p?.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return Self.normalizedStatus(raw)
                    }(),
                    lastSeenAt: p?.lastSeenDate,
                    accuracyMeters: p?.accuracy_m
                )
            }
            guard memberRefreshGeneration == requestGeneration,
                  mapTrackedGroupID == groupID,
                  groups.contains(where: { $0.id == groupID })
            else { return }
            let nextLiveIDs = Set(nextMembers.filter(\.isLive).map(\.userID))
            let sharingEnded = members.filter { $0.isLive && !nextLiveIDs.contains($0.userID) }
            members = nextMembers
            for member in sharingEnded where member.userID != supabase.userID {
                onPeerSharingEnded?(member.userID, member.displayName)
            }
            refreshSelectedPeerFromRoster()
            emitPeerUpdates(groupID: groupID)
            await reconcilePeerAlertsWithPresence()
            paintGroupOverlays()
        } catch {
            // Keep the last roster; polling retries shortly.
        }
    }

    private func refreshSelectedPeerFromRoster() {
        guard let selectedPeer,
              let member = members.first(where: { $0.userID == selectedPeer.userID }),
              member.isLive,
              let latitude = member.latitude,
              let longitude = member.longitude
        else {
            if selectedPeer != nil { self.selectedPeer = nil }
            return
        }
        presentPeer(member, latitude: latitude, longitude: longitude)
    }

    private func emitPeerUpdates(groupID: String) {
        for member in members where member.isLive && member.userID != supabase.userID {
            guard let latitude = member.latitude,
                  let longitude = member.longitude,
                  let lastSeenAt = member.lastSeenAt,
                  GroupPresencePolicy.isValidCoordinate(latitude: latitude, longitude: longitude)
            else { continue }
            onPeerLocationUpdate?(
                GroupMemberRouteTarget(
                    groupID: groupID,
                    userID: member.userID,
                    displayName: member.displayName,
                    coordinate: RouteCoordinate(longitude: longitude, latitude: latitude),
                    lastSeenAt: lastSeenAt,
                    accuracyMeters: member.accuracyMeters,
                    isLive: true
                )
            )
        }
    }

    /// Prefer a real screen name; never paint a blank chip.
    private static func resolvedDisplayName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Rider" : trimmed
    }

    private struct ProfileNameRow: Decodable {
        let id: String
        let display_name: String?
    }

    /// Nested `profiles(display_name)` on group_members
    /// can come back empty under RLS / embed shape quirks.
    private func fetchDisplayNames(for userIDs: [String]) async -> [String: String] {
        guard !userIDs.isEmpty else { return [:] }
        do {
            let rows: [ProfileNameRow] = try await client
                .from("profiles")
                .select("id,display_name")
                .in("id", values: userIDs)
                .execute()
                .value
            var map: [String: String] = [:]
            for row in rows {
                let name = row.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty { map[row.id] = name }
            }
            return map
        } catch {
            return [:]
        }
    }

    private func paintGroupOverlays() {
        let selfID = supabase.userID
        var overlays: [MapState.Marker] = []

        for member in members {
            guard member.isLive,
                  member.userID != selfID,
                  let lat = member.latitude,
                  let lon = member.longitude,
                  GroupPresencePolicy.isValidCoordinate(latitude: lat, longitude: lon)
            else { continue }
            overlays.append(
                MapState.Marker(
                    id: "rider:\(member.userID)",
                    latitude: lat,
                    longitude: lon,
                    label: member.displayName,
                    kind: .rider,
                    subtitle: member.displayName,
                    status: Self.normalizedStatus(member.status ?? "riding")
                )
            )
        }

        let liveRiderIDs = Set(overlays.map(\.id))
        for alert in peerAlerts where alert.userID != selfID {
            let riderID = "rider:\(alert.userID)"
            // Prefer live rider pin when present; otherwise drop an alert pin.
            guard !liveRiderIDs.contains(riderID),
                  GroupPresencePolicy.isValidCoordinate(
                    latitude: alert.latitude,
                    longitude: alert.longitude
                  )
            else { continue }
            overlays.append(
                MapState.Marker(
                    id: "alert:\(alert.id)",
                    latitude: alert.latitude,
                    longitude: alert.longitude,
                    label: alert.displayName,
                    kind: .alert,
                    subtitle: alert.statusText,
                    status: alert.status
                )
            )
        }

        mapState.setGroupMarkers(overlays)
    }

    private func clearGroupOverlays() {
        mapState.setGroupMarkers([])
    }

    // MARK: - Presence sharing

    /// Status picker entry point — upserts presence and inserts/broadcasts distress alerts.
    func setStatus(_ newStatus: String) {
        let allowed = Self.selectableStatuses
        guard allowed.contains(newStatus) else { return }
        let previous = status
        status = newStatus
        guard isSharing else { return }
        Task {
            await publishPresence(enabled: true)
            if Self.isDistressStatus(newStatus), newStatus != previous {
                await publishDistressAlert(status: newStatus, message: nil)
            }
            if newStatus == "riding", Self.normalizedStatus(previous) != "riding" {
                await resolveOpenAlerts()
            }
        }
    }

    func startSharing() {
        guard let userID = supabase.userID else {
            RoutingDebugLog.shared.event("groups sharing start rejected reason=signed_out")
            return
        }
        RoutingDebugLog.shared.event(
            "groups sharing start requested groups=\(groups.count) "
                + "authorization=\(location.authorization.rawValue) "
                + "accuracyAuthorization=\(location.accuracyAuthorization.rawValue)"
        )
        Self.setSharingPreference(true, userID: userID)
        beginSharing(seedFix: nil)
    }

    /// Core Location may deliver the first current fix between ordinary
    /// presence heartbeats. Publish it immediately so starting sharing never
    /// needs an app restart (or a ten-second polling delay) to turn live.
    func receiveLocationFix(_ fix: CLLocation) {
        guard isSharing, isWaitingForLocation else { return }
        guard GroupPresencePolicy.canPublish(fix) else {
            if !waitingForFixLogged {
                waitingForFixLogged = true
                RoutingDebugLog.shared.event(
                    "groups sharing fix rejected \(Self.fixDiagnostic(fix))"
                )
            }
            return
        }
        lastSharingFix = fix
        lastTrustedFix = fix
        isWaitingForLocation = false
        waitingForFixLogged = false
        RoutingDebugLog.shared.event(
            "groups sharing fix accepted \(Self.fixDiagnostic(fix))"
        )
        Task {
            await publishPresence(enabled: true)
            await broadcastLocationToChannels()
        }
    }

    private func beginSharing(seedFix: CLLocation?) {
        guard let userID = supabase.userID else {
            RoutingDebugLog.shared.event("groups sharing begin rejected reason=signed_out")
            return
        }
        lastSharingFix = GroupPresencePolicy.retainedPublishableFix(
            latest: location.lastLocation,
            accepted: seedFix ?? lastTrustedFix
        )
        if let lastSharingFix { lastTrustedFix = lastSharingFix }
        isSharing = true
        isWaitingForLocation = lastSharingFix == nil
        waitingForFixLogged = false
        livePresenceLogged = false
        RoutingDebugLog.shared.event(
            "groups sharing begin hasFix=\(lastSharingFix == nil ? 0 : 1) "
                + "seed=\(seedFix == nil ? 0 : 1)"
        )
        if lastSharingFix != nil {
            updateLocalMember(userID: userID, isLive: true, status: status)
        }
        location.requestAlways()
        location.setBackgroundUpdates(true, for: .groupSharing)
        location.startUpdates()
        if isWaitingForLocation {
            location.restartUpdatesForFreshFix()
        }
        shareTask?.cancel()
        shareTask = Task { [weak self] in
            await self?.ensureRealtimeForAllGroups()
            while let self, !Task.isCancelled, self.isSharing {
                await self.publishPresence(enabled: true)
                await self.broadcastLocationToChannels()
                let interval = GroupPresenceCadencePolicy.intervalSeconds(forStatus: self.status)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopSharing() {
        RoutingDebugLog.shared.event("groups sharing stop requested")
        if let userID = supabase.userID {
            Self.setSharingPreference(false, userID: userID)
            updateLocalMember(userID: userID, isLive: false, status: "offline")
        }
        isSharing = false
        isWaitingForLocation = false
        lastSharingFix = nil
        waitingForFixLogged = false
        livePresenceLogged = false
        shareTask?.cancel()
        shareTask = nil
        location.setBackgroundUpdates(false, for: .groupSharing)
        Task {
            await broadcastSharingOff()
            await publishPresence(enabled: false)
            for channel in realtimeChannels.values {
                await channel.untrack()
            }
        }
    }

    /// Called before auth is cleared so peers receive a final offline signal and
    /// no signed-out session keeps polling or sharing a cached location.
    func prepareForSignOut() async {
        if let userID = supabase.userID {
            Self.setSharingPreference(false, userID: userID)
            await broadcastSharingOff()
            await publishPresence(enabled: false)
        }
        for channel in realtimeChannels.values {
            await channel.untrack()
        }
        await closeAllRealtimeChannels()
        clearSessionState()
    }

    /// Fallback for token expiry or sign-out initiated outside Profile.
    func handleSignedOut() {
        clearSessionState()
        Task { await closeAllRealtimeChannels() }
    }

    private func clearSessionState() {
        groupRefreshGeneration += 1
        memberRefreshGeneration += 1
        shareTask?.cancel()
        shareTask = nil
        pollTask?.cancel()
        pollTask = nil
        channelListenTasks.values.forEach { $0.cancel() }
        isSharing = false
        isWaitingForLocation = false
        lastSharingFix = nil
        lastTrustedFix = nil
        waitingForFixLogged = false
        livePresenceLogged = false
        isLoading = false
        isMutatingGroup = false
        realtimeConnected = false
        groups = []
        selectedGroup = nil
        members = []
        peerAlerts = []
        selectedPeer = nil
        mapTrackedGroupID = nil
        sharingPanelOpen = false
        location.setBackgroundUpdates(false, for: .groupSharing)
        clearGroupOverlays()
    }

    private func closeAllRealtimeChannels() async {
        for groupID in Array(realtimeChannels.keys) {
            await closeRealtimeChannel(groupID: groupID)
        }
        channelListenTasks.removeAll()
        realtimeConnected = false
    }

    private struct PresenceUpsert: Encodable {
        let user_id: String
        let sharing_enabled: Bool
        let status: String
        let latitude: Double
        let longitude: Double
        let heading: Double
        let speed_mps: Double
        let accuracy_m: Double
        let last_seen_at: String
    }

    private struct PresenceOfflineUpdate: Encodable {
        let sharing_enabled: Bool
        let status: String
        let last_seen_at: String
    }

    /// Reconnect the UI and heartbeat loop to the rider's explicit sharing
    /// choice after an app relaunch. Existing installs did not yet store that
    /// choice locally, so one currently-live server row seeds the preference.
    private func restoreSharingIntentIfNeeded(userID: String, presence: PresenceRow?) {
        let savedIntent = Self.sharingPreference(userID: userID)
        let shouldShare = savedIntent ?? (presence?.isLive == true)
        if savedIntent == nil {
            Self.setSharingPreference(shouldShare, userID: userID)
        }
        guard shouldShare, !isSharing, !groups.isEmpty else { return }
        if let status = presence?.status,
           !status.isEmpty,
           status != "offline" {
            self.status = Self.normalizedStatus(status)
        }
        beginSharing(seedFix: presence?.locationFix)
    }

    private func updateLocalMember(userID: String, isLive: Bool, status: String) {
        guard let index = members.firstIndex(where: { $0.userID == userID }) else { return }
        members[index].isLive = isLive
        members[index].status = status
        paintGroupOverlays()
    }

    /// Returns the latest trustworthy coordinate for this sharing session.
    /// A stationary phone can keep publishing heartbeats even when Core Location
    /// has not produced a newly timestamped coordinate.
    private func sharingFix() -> CLLocation? {
        let fix = GroupPresencePolicy.retainedPublishableFix(
            latest: location.lastLocation,
            accepted: lastSharingFix
        )
        lastSharingFix = fix
        if let fix { lastTrustedFix = fix }
        return fix
    }

    private static func fixDiagnostic(_ fix: CLLocation) -> String {
        let ageMilliseconds = max(0, Int(Date.now.timeIntervalSince(fix.timestamp) * 1_000))
        return "ageMs=\(ageMilliseconds) accuracyM=\(Int(fix.horizontalAccuracy.rounded()))"
    }

    private func publishPresence(enabled: Bool) async {
        guard let userID = supabase.userID else { return }
        if !enabled {
            do {
                try await client
                    .from("rider_presence")
                    .update(
                        PresenceOfflineUpdate(
                            sharing_enabled: false,
                            status: "offline",
                            last_seen_at: ISO8601DateFormatter().string(from: .now)
                        )
                    )
                    .eq("user_id", value: userID)
                    .execute()
                RoutingDebugLog.shared.event("groups presence committed enabled=0")
            } catch {
                // Realtime sharing_off still removes the live map pin.
                let nsError = error as NSError
                RoutingDebugLog.shared.event(
                    "groups presence failed enabled=0 domain=\(nsError.domain) code=\(nsError.code)"
                )
            }
            return
        }
        guard let fix = sharingFix() else {
            isWaitingForLocation = true
            if !waitingForFixLogged {
                waitingForFixLogged = true
                let cached = location.lastLocation.map(Self.fixDiagnostic) ?? "none"
                RoutingDebugLog.shared.event(
                    "groups sharing waiting for current position cached=\(cached) "
                        + "authorization=\(location.authorization.rawValue)"
                )
            }
            return
        }
        isWaitingForLocation = false
        waitingForFixLogged = false
        updateLocalMember(userID: userID, isLive: true, status: status)
        let payload = PresenceUpsert(
            user_id: userID,
            sharing_enabled: enabled,
            status: enabled ? status : "offline",
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            heading: max(fix.course, 0),
            speed_mps: max(fix.speed, 0),
            accuracy_m: fix.horizontalAccuracy,
            last_seen_at: ISO8601DateFormatter().string(from: fix.timestamp)
        )
        do {
            try await client
                .from("rider_presence")
                .upsert(payload, onConflict: "user_id")
                .execute()
            if !livePresenceLogged {
                livePresenceLogged = true
                RoutingDebugLog.shared.event(
                    "groups presence committed enabled=1 status=\(status) \(Self.fixDiagnostic(fix))"
                )
            }
        } catch {
            // Transient network drop while riding; the next tick retries.
            livePresenceLogged = false
            let nsError = error as NSError
            RoutingDebugLog.shared.event(
                "groups presence failed enabled=1 domain=\(nsError.domain) code=\(nsError.code)"
            )
        }
    }

    // MARK: - rider_alerts

    static func isDistressStatus(_ status: String) -> Bool {
        isMechanicalDistressStatus(status) || ["injured", "stuck"].contains(normalizedStatus(status))
    }

    /// Maps local route-report categories onto the DB check constraint
    /// (`breakdown` | `injured` | `stuck`). Full category title goes in `message`.
    static func alertStatus(for category: RouteIncidentCategory) -> String {
        switch category {
        case .unsafe: return "injured"
        case .other: return "breakdown"
        case .accessClosed, .gateSeasonal, .flooded, .blocked: return "stuck"
        }
    }

    /// Active group for cloud alerts: tracked detail, else first membership.
    var alertTargetGroup: GroupSummary? {
        if let id = mapTrackedGroupID ?? selectedGroup?.id,
           let match = groups.first(where: { $0.id == id }) {
            return match
        }
        return groups.first
    }

    private func resolveAlertOnServer(id: String) async {
        let stamp = ISO8601DateFormatter().string(from: .now)
        do {
            try await client
                .from("rider_alerts")
                .update(AlertResolveUpdate(resolved_at: stamp))
                .eq("id", value: id)
                .execute()
        } catch {
            // Local dismiss already applied; retry on next reconcile.
        }
    }

    /// Clear unresolved distress rows for the signed-in rider in the active group.
    private func resolveOpenAlerts() async {
        guard let userID = supabase.userID, let group = alertTargetGroup else { return }
        let stamp = ISO8601DateFormatter().string(from: .now)
        do {
            try await client
                .from("rider_alerts")
                .update(AlertResolveUpdate(resolved_at: stamp))
                .eq("group_id", value: group.id)
                .eq("user_id", value: userID)
                .is("resolved_at", value: nil)
                .execute()
        } catch {
            // Presence already shows available; peers reconcile on refresh.
        }
    }

    /// Drop toasts for riders whose presence is no longer distress, and resolve those rows.
    private func reconcilePeerAlertsWithPresence() async {
        let clearUserIDs = Set(
            members
                .filter { !Self.isDistressStatus($0.status ?? "riding") }
                .map(\.userID)
        )
        let stale = peerAlerts.filter { clearUserIDs.contains($0.userID) }
        guard !stale.isEmpty else { return }
        peerAlerts.removeAll { clearUserIDs.contains($0.userID) }
        for alert in stale {
            await resolveAlertOnServer(id: alert.id)
        }
    }

    private func clearPeerAlerts(for userID: String, resolveOnServer: Bool) {
        let stale = peerAlerts.filter { $0.userID == userID }
        guard !stale.isEmpty else { return }
        peerAlerts.removeAll { $0.userID == userID }
        paintGroupOverlays()
        guard resolveOnServer else { return }
        Task {
            for alert in stale {
                await resolveAlertOnServer(id: alert.id)
            }
        }
    }

    /// Insert + broadcast when the rider sets a distress status.
    private func publishDistressAlert(status: String, message: String?) async {
        guard let userID = supabase.userID,
              let group = alertTargetGroup,
              Self.isDistressStatus(status) else { return }
        let fix = GroupPresencePolicy.canPublish(location.lastLocation)
            ? location.lastLocation
            : nil
        let lat = fix?.coordinate.latitude
        let lon = fix?.coordinate.longitude
        do {
            try await client
                .from("rider_alerts")
                .insert(
                    AlertInsert(
                        group_id: group.id,
                        user_id: userID,
                        status: status,
                        message: message,
                        latitude: lat,
                        longitude: lon
                    )
                )
                .execute()
            onToast?("Group alerted: \(Self.statusLabel(status))")
        } catch {
            onToast?("Could not send alert")
        }

        let broadcast = AlertBroadcast(
            alertId: "\(userID):\(status):\(Int(Date().timeIntervalSince1970 * 1000))",
            userId: userID,
            displayName: supabase.displayName.isEmpty ? "Rider" : supabase.displayName,
            status: status,
            groupId: group.id,
            groupName: group.name,
            lng: lon,
            lat: lat,
            createdAt: ISO8601DateFormatter().string(from: .now),
            message: message
        )
        let targetIDs = GroupAlertPolicy.broadcastGroupIDs(
            targetGroupID: group.id,
            connectedGroupIDs: realtimeChannels.keys
        )
        for groupID in targetIDs {
            guard let channel = realtimeChannels[groupID] else { continue }
            try? await channel.broadcast(event: "alert", message: broadcast)
        }
    }

    /// Cloud insert for HUD Report while in a group (local store still always runs).
    func publishRouteReportAlert(category: RouteIncidentCategory, latitude: Double, longitude: Double) async {
        guard let userID = supabase.userID,
              let group = alertTargetGroup else { return }
        let status = Self.alertStatus(for: category)
        do {
            try await client
                .from("rider_alerts")
                .insert(
                    AlertInsert(
                        group_id: group.id,
                        user_id: userID,
                        status: status,
                        message: category.title,
                        latitude: latitude,
                        longitude: longitude
                    )
                )
                .execute()
            if let channel = realtimeChannels[group.id] {
                let broadcast = AlertBroadcast(
                    alertId: "\(userID):\(status):\(Int(Date().timeIntervalSince1970 * 1000))",
                    userId: userID,
                    displayName: supabase.displayName.isEmpty ? "Rider" : supabase.displayName,
                    status: status,
                    groupId: group.id,
                    groupName: group.name,
                    lng: longitude,
                    lat: latitude,
                    createdAt: ISO8601DateFormatter().string(from: .now),
                    message: category.title
                )
                try? await channel.broadcast(event: "alert", message: broadcast)
            }
            onToast?("Report shared with \(group.name)")
        } catch {
            // Local report already saved; cloud share is best-effort.
        }
    }

    private func fetchPeerAlerts(groupID: String) async {
        guard let selfID = supabase.userID else { return }
        do {
            let rows: [AlertRow] = try await client
                .from("rider_alerts")
                .select("id,group_id,user_id,status,message,latitude,longitude,created_at,resolved_at")
                .eq("group_id", value: groupID)
                .is("resolved_at", value: nil)
                .order("created_at", ascending: false)
                .limit(20)
                .execute()
                .value
            let names = await fetchDisplayNames(for: Array(Set(rows.map(\.user_id))))
            guard supabase.userID == selfID,
                  mapTrackedGroupID == groupID,
                  groups.contains(where: { $0.id == groupID })
            else { return }
            let groupName = groups.first(where: { $0.id == groupID })?.name
                ?? selectedGroup?.name
                ?? "Group"
            let presenceByUser = Dictionary(
                uniqueKeysWithValues: members.map { ($0.userID, Self.normalizedStatus($0.status ?? "riding")) }
            )
            var next: [PeerAlertBanner] = []
            var staleIDs: [String] = []
            for row in rows {
                guard row.user_id != selfID,
                      Self.isDistressStatus(row.status),
                      let lat = row.latitude,
                      let lon = row.longitude,
                      GroupPresencePolicy.isValidCoordinate(latitude: lat, longitude: lon)
                else { continue }
                // Presence wins over a leftover unresolved alert row.
                if let live = presenceByUser[row.user_id], !Self.isDistressStatus(live) {
                    staleIDs.append(row.id)
                    continue
                }
                next.append(
                    PeerAlertBanner(
                        id: row.id,
                        userID: row.user_id,
                        displayName: Self.resolvedDisplayName(names[row.user_id]),
                        status: row.status,
                        statusText: Self.statusLabel(row.status),
                        groupID: row.group_id,
                        groupName: groupName,
                        latitude: lat,
                        longitude: lon,
                        message: row.message
                    )
                )
            }
            for id in staleIDs {
                await resolveAlertOnServer(id: id)
            }
            // Replace this group's banners so resolved/empty fetches clear local memory.
            let retained = peerAlerts.filter { $0.groupID != groupID }
            peerAlerts = Self.upsertAlerts(retained, with: next)
            paintGroupOverlays()
        } catch {
            // Roster still works without historical alerts.
        }
    }

    private static func upsertAlerts(_ existing: [PeerAlertBanner], with incoming: [PeerAlertBanner]) -> [PeerAlertBanner] {
        var list = existing
        for record in incoming {
            if let idx = list.firstIndex(where: { $0.userID == record.userID && $0.status == record.status }) {
                list[idx] = record
            } else if let idx = list.firstIndex(where: { $0.id == record.id }) {
                list[idx] = record
            } else {
                list.insert(record, at: 0)
            }
        }
        return Array(list.prefix(8))
    }

    private func ingestAlertBroadcast(_ payload: AlertBroadcast) {
        guard let selfID = supabase.userID, payload.userId != selfID else { return }
        guard Self.isDistressStatus(payload.status),
              let lat = payload.lat, let lng = payload.lng,
              GroupPresencePolicy.isValidCoordinate(latitude: lat, longitude: lng)
        else { return }
        let record = PeerAlertBanner(
            id: payload.alertId ?? "\(payload.userId):\(payload.status):\(payload.createdAt ?? "")",
            userID: payload.userId,
            displayName: Self.resolvedDisplayName(payload.displayName),
            status: payload.status.lowercased(),
            statusText: Self.statusLabel(payload.status),
            groupID: payload.groupId ?? mapTrackedGroupID ?? "",
            groupName: payload.groupName ?? "Group",
            latitude: lat,
            longitude: lng,
            message: payload.message
        )
        peerAlerts = Self.upsertAlerts(peerAlerts, with: [record])
        paintGroupOverlays()
        onToast?("\(record.displayName) · \(record.statusText)")
    }

    // MARK: - Realtime

    private func ensureRealtimeForAllGroups() async {
        for group in groups {
            await ensureRealtimeChannel(groupID: group.id)
        }
        let active = Set(groups.map(\.id))
        for groupID in Array(realtimeChannels.keys) where !active.contains(groupID) {
            await closeRealtimeChannel(groupID: groupID)
        }
    }

    private func ensureRealtimeChannel(groupID: String) async {
        guard let userID = supabase.userID, let client = try? client else { return }
        guard realtimeChannels[groupID] == nil,
              !connectingGroupIDs.contains(groupID) else { return }
        connectingGroupIDs.insert(groupID)
        defer { connectingGroupIDs.remove(groupID) }

        let channel = client.channel("group:\(groupID)") {
            $0.isPrivate = true
            $0.presence = PresenceJoinConfig(key: userID)
        }

        let locationStream = channel.broadcastStream(event: "location")
        let alertStream = channel.broadcastStream(event: "alert")
        let sharingOffStream = channel.broadcastStream(event: "sharing_off")
        let membershipChangedStream = channel.broadcastStream(event: "membership_changed")
        let presenceStream = channel.presenceChange()

        channelListenTasks[groupID]?.cancel()
        channelListenTasks[groupID] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await message in locationStream {
                        guard let self, !Task.isCancelled else { break }
                        await self.handleLocationMessage(message, groupID: groupID)
                    }
                }
                group.addTask { [weak self] in
                    for await message in alertStream {
                        guard let self, !Task.isCancelled else { break }
                        await self.handleAlertMessage(message)
                    }
                }
                group.addTask { [weak self] in
                    for await message in sharingOffStream {
                        guard let self, !Task.isCancelled else { break }
                        await self.handleSharingOffMessage(message, groupID: groupID)
                    }
                }
                group.addTask { [weak self] in
                    for await message in membershipChangedStream {
                        guard let self, !Task.isCancelled else { break }
                        await self.handleMembershipChangedMessage(message, groupID: groupID)
                    }
                }
                group.addTask { [weak self] in
                    for await action in presenceStream {
                        guard let self, !Task.isCancelled else { break }
                        await self.handlePresenceAction(action, groupID: groupID)
                    }
                }
            }
        }

        do {
            try await channel.subscribeWithError()
        } catch {
            errorMessage = "Couldn't connect live updates for this group."
            channelListenTasks[groupID]?.cancel()
            channelListenTasks[groupID] = nil
            await supabase.client?.removeChannel(channel)
            return
        }
        guard supabase.userID == userID,
              groups.contains(where: { $0.id == groupID }) else {
            channelListenTasks[groupID]?.cancel()
            channelListenTasks[groupID] = nil
            await supabase.client?.removeChannel(channel)
            return
        }
        realtimeChannels[groupID] = channel
        realtimeConnected = !realtimeChannels.isEmpty
        if isSharing {
            await trackOnChannel(channel, groupID: groupID)
        }
    }

    private func closeRealtimeChannel(groupID: String) async {
        channelListenTasks[groupID]?.cancel()
        channelListenTasks[groupID] = nil
        if let channel = realtimeChannels.removeValue(forKey: groupID) {
            await supabase.client?.removeChannel(channel)
        }
        realtimeConnected = !realtimeChannels.isEmpty
    }

    private func trackOnChannel(_ channel: RealtimeChannelV2, groupID: String) async {
        guard let userID = supabase.userID,
              let fix = sharingFix() else { return }
        let groupName = groups.first(where: { $0.id == groupID })?.name ?? "Group"
        let payload = LocationBroadcast(
            userId: userID,
            displayName: supabase.displayName.isEmpty ? "Rider" : supabase.displayName,
            lng: fix.coordinate.longitude,
            lat: fix.coordinate.latitude,
            heading: max(fix.course, 0),
            speed: max(fix.speed, 0),
            accuracy: fix.horizontalAccuracy,
            status: status,
            lastSeenAt: ISO8601DateFormatter().string(from: fix.timestamp),
            heartbeatAt: ISO8601DateFormatter().string(from: .now),
            groupId: groupID,
            groupName: groupName
        )
        try? await channel.track(payload)
    }

    private func broadcastLocationToChannels() async {
        guard isSharing,
              let userID = supabase.userID,
              let fix = sharingFix() else { return }
        for (groupID, channel) in realtimeChannels {
            let groupName = groups.first(where: { $0.id == groupID })?.name ?? "Group"
            let payload = LocationBroadcast(
                userId: userID,
                displayName: supabase.displayName.isEmpty ? "Rider" : supabase.displayName,
                lng: fix.coordinate.longitude,
                lat: fix.coordinate.latitude,
                heading: max(fix.course, 0),
                speed: max(fix.speed, 0),
                accuracy: fix.horizontalAccuracy,
                status: status,
                lastSeenAt: ISO8601DateFormatter().string(from: fix.timestamp),
                heartbeatAt: ISO8601DateFormatter().string(from: .now),
                groupId: groupID,
                groupName: groupName
            )
            try? await channel.track(payload)
            try? await channel.broadcast(event: "location", message: payload)
        }
    }

    private func broadcastSharingOff() async {
        guard let userID = supabase.userID else { return }
        let payload = SharingOffBroadcast(userId: userID)
        for channel in realtimeChannels.values {
            try? await channel.broadcast(event: "sharing_off", message: payload)
        }
    }

    private func broadcastMembershipChanged(userID: String, action: String, groupID: String) async {
        guard let channel = realtimeChannels[groupID] else { return }
        let payload = MembershipChangedBroadcast(userId: userID, action: action)
        try? await channel.broadcast(event: "membership_changed", message: payload)
    }

    @MainActor
    private func handleLocationMessage(_ message: JSONObject, groupID: String) {
        let payload: LocationBroadcast?
        if let nested = try? message["payload"]?.decode(as: LocationBroadcast.self) {
            payload = nested
        } else {
            payload = try? message.decode(as: LocationBroadcast.self)
        }
        guard let payload, let selfID = supabase.userID, payload.userId != selfID else { return }
        guard let lat = payload.lat,
              let lng = payload.lng,
              let lastSeenAt = payload.lastSeenAt.flatMap({ ISO8601DateFormatter.flexible.parse($0) })
        else { return }
        let heartbeatAt = payload.heartbeatAt.flatMap({ ISO8601DateFormatter.flexible.parse($0) }) ?? lastSeenAt
        guard GroupPresencePolicy.isLive(
                sharingEnabled: true,
                latitude: lat,
                longitude: lng,
                accuracyMeters: payload.accuracy,
                heartbeatAt: heartbeatAt
        ) else { return }

        let resolvedName = Self.resolvedDisplayName(
            payload.displayName
                ?? members.first(where: { $0.userID == payload.userId })?.displayName
        )
        onPeerLocationUpdate?(
            GroupMemberRouteTarget(
                groupID: groupID,
                userID: payload.userId,
                displayName: resolvedName,
                coordinate: RouteCoordinate(longitude: lng, latitude: lat),
                lastSeenAt: lastSeenAt,
                accuracyMeters: payload.accuracy,
                isLive: true
            )
        )
        // We subscribe to every membership so tracking can continue even when
        // another group is open. Only the tracked group's events may mutate the
        // visible roster and rider pins.
        guard mapTrackedGroupID == groupID else { return }

        let previousStatus = members.first(where: { $0.userID == payload.userId })?.status
        if let idx = members.firstIndex(where: { $0.userID == payload.userId }) {
            members[idx].isLive = true
            members[idx].latitude = lat
            members[idx].longitude = lng
            members[idx].lastSeenAt = lastSeenAt
            members[idx].accuracyMeters = payload.accuracy
            if let status = payload.status, !status.isEmpty {
                members[idx].status = Self.normalizedStatus(status)
            }
            if let name = payload.displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // displayName is let — rebuild row
                let old = members[idx]
                members[idx] = GroupMemberRow(
                    userID: old.userID,
                    role: old.role,
                    displayName: Self.resolvedDisplayName(name),
                    isLive: true,
                    latitude: lat,
                    longitude: lng,
                    status: Self.normalizedStatus(payload.status ?? old.status ?? "riding"),
                    lastSeenAt: lastSeenAt,
                    accuracyMeters: payload.accuracy
                )
            }
        }
        refreshSelectedPeerFromRoster()
        paintGroupOverlays()

        if let status = payload.status {
            if Self.isDistressStatus(status), previousStatus != status {
                ingestAlertBroadcast(
                    AlertBroadcast(
                        alertId: "\(payload.userId):\(status):\(payload.lastSeenAt ?? "")",
                        userId: payload.userId,
                        displayName: payload.displayName,
                        status: status,
                        groupId: payload.groupId,
                        groupName: payload.groupName,
                        lng: lng,
                        lat: lat,
                        createdAt: payload.lastSeenAt,
                        message: nil
                    )
                )
            } else if !Self.isDistressStatus(status) {
                clearPeerAlerts(for: payload.userId, resolveOnServer: true)
            }
        }
    }

    @MainActor
    private func handleAlertMessage(_ message: JSONObject) {
        let payload: AlertBroadcast?
        if let nested = try? message["payload"]?.decode(as: AlertBroadcast.self) {
            payload = nested
        } else {
            payload = try? message.decode(as: AlertBroadcast.self)
        }
        guard let payload else { return }
        ingestAlertBroadcast(payload)
    }

    @MainActor
    private func handleSharingOffMessage(_ message: JSONObject, groupID: String) {
        let payload: SharingOffBroadcast?
        if let nested = try? message["payload"]?.decode(as: SharingOffBroadcast.self) {
            payload = nested
        } else {
            payload = try? message.decode(as: SharingOffBroadcast.self)
        }
        guard let payload, let selfID = supabase.userID, payload.userId != selfID else { return }
        let knownName = members.first(where: { $0.userID == payload.userId })?.displayName
            ?? "Group member"
        onPeerSharingEnded?(payload.userId, knownName)
        guard mapTrackedGroupID == groupID else { return }
        if let idx = members.firstIndex(where: { $0.userID == payload.userId }) {
            members[idx].isLive = false
            members[idx].status = "offline"
        }
        if selectedPeer?.userID == payload.userId { selectedPeer = nil }
        paintGroupOverlays()
    }

    @MainActor
    private func handleMembershipChangedMessage(_ message: JSONObject, groupID: String) async {
        let payload: MembershipChangedBroadcast?
        if let nested = try? message["payload"]?.decode(as: MembershipChangedBroadcast.self) {
            payload = nested
        } else {
            payload = try? message.decode(as: MembershipChangedBroadcast.self)
        }
        guard let payload, payload.userId != supabase.userID,
              payload.action == "joined" || payload.action == "left"
        else { return }

        await refreshGroups()
        if mapTrackedGroupID == groupID {
            await refreshMembers(groupID: groupID)
        }
    }

    @MainActor
    private func handlePresenceAction(_ action: any PresenceAction, groupID: String) {
        guard let selfID = supabase.userID else { return }
        let visibleGroup = mapTrackedGroupID == groupID
        if let joins = try? action.decodeJoins(as: LocationBroadcast.self) {
            for join in joins where join.userId != selfID {
                guard let lat = join.lat,
                      let lng = join.lng,
                      let seen = join.lastSeenAt.flatMap({ ISO8601DateFormatter.flexible.parse($0) })
                else { continue }
                let heartbeat = join.heartbeatAt.flatMap({ ISO8601DateFormatter.flexible.parse($0) }) ?? seen
                guard GroupPresencePolicy.isLive(
                        sharingEnabled: true,
                        latitude: lat,
                        longitude: lng,
                        accuracyMeters: join.accuracy,
                        heartbeatAt: heartbeat
                ) else { continue }
                onPeerLocationUpdate?(
                    GroupMemberRouteTarget(
                        groupID: groupID,
                        userID: join.userId,
                        displayName: Self.resolvedDisplayName(join.displayName),
                        coordinate: RouteCoordinate(longitude: lng, latitude: lat),
                        lastSeenAt: seen,
                        accuracyMeters: join.accuracy,
                        isLive: true
                    )
                )
                guard visibleGroup else { continue }
                if let idx = members.firstIndex(where: { $0.userID == join.userId }) {
                    let old = members[idx]
                    members[idx] = GroupMemberRow(
                        userID: old.userID,
                        role: old.role,
                        displayName: Self.resolvedDisplayName(join.displayName ?? old.displayName),
                        isLive: true,
                        latitude: lat,
                        longitude: lng,
                        status: Self.normalizedStatus(join.status ?? old.status ?? "riding"),
                        lastSeenAt: seen,
                        accuracyMeters: join.accuracy
                    )
                }
            }
        }
        // Presence `sync` may contain a join and leave for the same still-connected
        // client while Supabase reconciles a changed payload. A leave therefore
        // is not proof that the rider stopped sharing. The explicit
        // `sharing_off` broadcast handles a deliberate stop immediately, while
        // the persisted heartbeat poll handles a real disconnect after expiry.
        // Also handle presence keyed by user id without full LocationBroadcast decode.
        for (key, presence) in action.joins where key != selfID {
            if let state = try? presence.decodeState(as: LocationBroadcast.self),
               let lat = state.lat,
               let lng = state.lng,
               let seen = state.lastSeenAt.flatMap({ ISO8601DateFormatter.flexible.parse($0) }) {
                let heartbeat = state.heartbeatAt.flatMap({ ISO8601DateFormatter.flexible.parse($0) }) ?? seen
                guard GroupPresencePolicy.isLive(
                sharingEnabled: true,
                latitude: lat,
                longitude: lng,
                accuracyMeters: state.accuracy,
                heartbeatAt: heartbeat
                ) else { continue }
                onPeerLocationUpdate?(
                    GroupMemberRouteTarget(
                        groupID: groupID,
                        userID: key,
                        displayName: Self.resolvedDisplayName(state.displayName),
                        coordinate: RouteCoordinate(longitude: lng, latitude: lat),
                        lastSeenAt: seen,
                        accuracyMeters: state.accuracy,
                        isLive: true
                    )
                )
                guard visibleGroup,
                      let idx = members.firstIndex(where: { $0.userID == key })
                else { continue }
                let old = members[idx]
                members[idx] = GroupMemberRow(
                    userID: old.userID,
                    role: old.role,
                    displayName: Self.resolvedDisplayName(state.displayName ?? old.displayName),
                    isLive: true,
                    latitude: lat,
                    longitude: lng,
                    status: Self.normalizedStatus(state.status ?? old.status ?? "riding"),
                    lastSeenAt: seen,
                    accuracyMeters: state.accuracy
                )
            }
        }
        guard visibleGroup else { return }
        refreshSelectedPeerFromRoster()
        emitPeerUpdates(groupID: groupID)
        paintGroupOverlays()
    }
}


extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatterBox = ISO8601DateFormatterBox()
}

/// Supabase timestamps carry fractional seconds; plain ISO8601 parsing does not.
final class ISO8601DateFormatterBox: Sendable {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
    }

    func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}
