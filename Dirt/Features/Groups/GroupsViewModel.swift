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

    var id: String { userID }
}

/// Map / roster selection for a live peer.
struct SelectedGroupPeer: Identifiable, Equatable {
    let userID: String
    let displayName: String
    let groupName: String
    let status: String
    let statusText: String
    let lastSeenLabel: String
    let latitude: Double
    let longitude: Double

    var id: String { userID }
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

    private(set) var groups: [GroupSummary] = []
    private(set) var selectedGroup: GroupSummary?
    private(set) var members: [GroupMemberRow] = []
    private(set) var peerAlerts: [PeerAlertBanner] = []
    private(set) var isLoading = false
    private(set) var isSharing = false
    private(set) var realtimeConnected = false
    /// Live peer selected from the map (or roster) — details card, not auto-route.
    var selectedPeer: SelectedGroupPeer?
    var status = "available"
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
        let status = {
            let raw = (member.status ?? "available").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "available" : raw.lowercased()
        }()
        selectedPeer = SelectedGroupPeer(
            userID: member.userID,
            displayName: member.displayName,
            groupName: selectedGroup?.name
                ?? groups.first(where: { $0.id == mapTrackedGroupID })?.name
                ?? "Group",
            status: status,
            statusText: Self.statusLabel(status),
            lastSeenLabel: Self.lastSeenLabel(member.lastSeenAt),
            latitude: latitude,
            longitude: longitude
        )
    }

    static func statusLabel(_ status: String) -> String {
        switch status.lowercased() {
        case "breakdown": return "Breakdown"
        case "injured": return "Injured"
        case "stuck": return "Stuck"
        case "offline": return "Offline"
        default: return "Available"
        }
    }

    private static func lastSeenLabel(_ date: Date?) -> String {
        guard let date else { return "just now" }
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
        let last_seen_at: String?

        var isLive: Bool {
            guard sharing_enabled == true else { return false }
            guard let last_seen_at, let seen = ISO8601DateFormatter.flexible.parse(last_seen_at) else { return true }
            return Date.now.timeIntervalSince(seen) < 120
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
        let status: String?
        let lastSeenAt: String?
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

    // MARK: - List

    func refreshGroups() async {
        guard let userID = supabase.userID else { return }
        isLoading = true
        defer { isLoading = false }
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
                    .select("user_id,sharing_enabled,status,latitude,longitude,last_seen_at")
                    .in("user_id", values: userIDs)
                    .execute()
                    .value
                let liveUsers = Set(presence.filter(\.isLive).map(\.user_id))
                for index in summaries.indices {
                    let groupMembers = memberships.filter { $0.group_id == summaries[index].id }
                    summaries[index].memberCount = groupMembers.count
                    summaries[index].liveCount = groupMembers.filter { liveUsers.contains($0.user_id) }.count
                }
            }
            groups = summaries
            errorMessage = nil
            // Subscribe even when self is not sharing so you still see live peers.
            await ensureRealtimeForAllGroups()
            await ensureMapTrackingIfNeeded()
        } catch {
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
        guard let userID = supabase.userID else { return }
        do {
            struct NewGroup: Encodable {
                let name: String
                let owner_id: String
            }
            struct CreatedGroup: Decodable {
                let id: String
            }
            let created: CreatedGroup = try await client
                .from("groups")
                .insert(NewGroup(name: name, owner_id: userID))
                .select("id")
                .single()
                .execute()
                .value
            struct NewMember: Encodable {
                let group_id: String
                let user_id: String
                let role: String
            }
            try await client
                .from("group_members")
                .insert(NewMember(group_id: created.id, user_id: userID, role: "owner"))
                .execute()
            await refreshGroups()
        } catch {
            errorMessage = "The group could not be created."
        }
    }

    func joinGroup(code rawCode: String) async {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code.wholeMatch(of: /[a-z0-9]{6}/) != nil else {
            errorMessage = "Invite codes are six lowercase letters or numbers."
            return
        }
        do {
            try await client
                .rpc("join_group_by_invite_code", params: ["p_invite_code": code])
                .execute()
            await refreshGroups()
        } catch {
            errorMessage = "No active riding group was found for that code."
        }
    }

    func leaveGroup(_ group: GroupSummary) async {
        do {
            try await client.rpc("leave_group", params: ["p_group_id": group.id]).execute()
            await closeRealtimeChannel(groupID: group.id)
            stopMapTracking()
            selectedGroup = nil
            await refreshGroups()
        } catch {
            errorMessage = "You could not leave this group right now."
        }
    }

    func deleteGroup(_ group: GroupSummary) async {
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
                // Faster when Realtime is down; slower fallback when connected.
                let seconds: Double = self.realtimeChannels[groupID] != nil ? 30 : 10
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func stopMapTracking() {
        mapTrackedGroupID = nil
        members = []
        peerAlerts = []
        selectedPeer = nil
        pollTask?.cancel()
        pollTask = nil
        clearGroupOverlays()
    }

    private func refreshMembers(groupID: String) async {
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
                .select("user_id,sharing_enabled,status,latitude,longitude,last_seen_at")
                .in("user_id", values: userIDs)
                .execute()
                .value
            let presenceByUser = Dictionary(uniqueKeysWithValues: presence.map { ($0.user_id, $0) })
            let namesByUser = await fetchDisplayNames(for: userIDs)
            members = rows.map { row in
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
                        return raw.isEmpty ? "available" : raw
                    }(),
                    lastSeenAt: p?.last_seen_at.flatMap { ISO8601DateFormatter.flexible.parse($0) }
                )
            }
            await reconcilePeerAlertsWithPresence()
            paintGroupOverlays()
        } catch {
            // Keep the last roster; polling retries shortly.
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
                  let lon = member.longitude else { continue }
            overlays.append(
                MapState.Marker(
                    id: "rider:\(member.userID)",
                    latitude: lat,
                    longitude: lon,
                    label: member.displayName,
                    kind: .rider,
                    subtitle: member.displayName,
                    status: member.status ?? "available"
                )
            )
        }

        let liveRiderIDs = Set(overlays.map(\.id))
        for alert in peerAlerts where alert.userID != selfID {
            let riderID = "rider:\(alert.userID)"
            // Prefer live rider pin when present; otherwise drop an alert pin.
            guard !liveRiderIDs.contains(riderID) else { continue }
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

        let retained = mapState.markers.filter { !$0.kind.isGroupOverlay }
        mapState.setMarkers(retained + overlays)
    }

    private func clearGroupOverlays() {
        let retained = mapState.markers.filter { !$0.kind.isGroupOverlay }
        mapState.setMarkers(retained)
    }

    // MARK: - Presence sharing

    /// Status picker entry point — upserts presence and inserts/broadcasts distress alerts.
    func setStatus(_ newStatus: String) {
        let allowed = ["available", "breakdown", "injured", "stuck"]
        guard allowed.contains(newStatus) else { return }
        let previous = status
        status = newStatus
        guard isSharing else { return }
        Task {
            await publishPresence(enabled: true)
            if Self.isDistressStatus(newStatus), newStatus != previous {
                await publishDistressAlert(status: newStatus, message: nil)
            }
            if newStatus == "available", previous != "available" {
                await resolveOpenAlerts()
            }
        }
    }

    func startSharing() {
        guard supabase.userID != nil else { return }
        isSharing = true
        location.requestAlways()
        location.setBackgroundUpdates(true)
        location.startUpdates()
        shareTask?.cancel()
        shareTask = Task { [weak self] in
            await self?.ensureRealtimeForAllGroups()
            while let self, !Task.isCancelled, self.isSharing {
                await self.publishPresence(enabled: true)
                await self.broadcastLocationToChannels()
                let interval: Double = Self.isDistressStatus(self.status) ? 5 : 5
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopSharing() {
        isSharing = false
        shareTask?.cancel()
        shareTask = nil
        Task {
            await broadcastSharingOff()
            await publishPresence(enabled: false)
            for channel in realtimeChannels.values {
                await channel.untrack()
            }
        }
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

    private func publishPresence(enabled: Bool) async {
        guard let userID = supabase.userID else { return }
        let fix = location.lastLocation
        let payload = PresenceUpsert(
            user_id: userID,
            sharing_enabled: enabled,
            status: enabled ? status : "offline",
            latitude: fix?.coordinate.latitude ?? 0,
            longitude: fix?.coordinate.longitude ?? 0,
            heading: max(fix?.course ?? 0, 0),
            speed_mps: max(fix?.speed ?? 0, 0),
            accuracy_m: fix?.horizontalAccuracy ?? 0,
            last_seen_at: ISO8601DateFormatter().string(from: .now)
        )
        do {
            try await client
                .from("rider_presence")
                .upsert(payload, onConflict: "user_id")
                .execute()
        } catch {
            // Transient network drop while riding; the next tick retries.
        }
    }

    // MARK: - rider_alerts

    static func isDistressStatus(_ status: String) -> Bool {
        ["breakdown", "injured", "stuck"].contains(status.lowercased())
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
                .filter { !Self.isDistressStatus($0.status ?? "available") }
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
        let fix = location.lastLocation
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
        for (groupID, channel) in realtimeChannels {
            var payload = broadcast
            if let named = groups.first(where: { $0.id == groupID }) {
                payload = AlertBroadcast(
                    alertId: broadcast.alertId,
                    userId: broadcast.userId,
                    displayName: broadcast.displayName,
                    status: broadcast.status,
                    groupId: groupID,
                    groupName: named.name,
                    lng: broadcast.lng,
                    lat: broadcast.lat,
                    createdAt: broadcast.createdAt,
                    message: broadcast.message
                )
            }
            try? await channel.broadcast(event: "alert", message: payload)
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
            let groupName = groups.first(where: { $0.id == groupID })?.name
                ?? selectedGroup?.name
                ?? "Group"
            let presenceByUser = Dictionary(
                uniqueKeysWithValues: members.map { ($0.userID, $0.status ?? "available") }
            )
            var next: [PeerAlertBanner] = []
            var staleIDs: [String] = []
            for row in rows {
                guard row.user_id != selfID,
                      Self.isDistressStatus(row.status),
                      let lat = row.latitude,
                      let lon = row.longitude else { continue }
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
              lat.isFinite, lng.isFinite else { return }
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
        for groupID in realtimeChannels.keys where !active.contains(groupID) {
            await closeRealtimeChannel(groupID: groupID)
        }
    }

    private func ensureRealtimeChannel(groupID: String) async {
        guard let userID = supabase.userID, let client = try? client else { return }
        if realtimeChannels[groupID] != nil { return }

        let channel = client.channel("group:\(groupID)") {
            $0.isPrivate = true
            $0.presence = PresenceJoinConfig(key: userID)
        }

        let locationStream = channel.broadcastStream(event: "location")
        let alertStream = channel.broadcastStream(event: "alert")
        let sharingOffStream = channel.broadcastStream(event: "sharing_off")
        let presenceStream = channel.presenceChange()

        channelListenTasks[groupID]?.cancel()
        channelListenTasks[groupID] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await message in locationStream {
                        guard let self, !Task.isCancelled else { break }
                        await self.handleLocationMessage(message)
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
                        await self.handleSharingOffMessage(message)
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
        guard let userID = supabase.userID, let fix = location.lastLocation else { return }
        let groupName = groups.first(where: { $0.id == groupID })?.name ?? "Group"
        let payload = LocationBroadcast(
            userId: userID,
            displayName: supabase.displayName.isEmpty ? "Rider" : supabase.displayName,
            lng: fix.coordinate.longitude,
            lat: fix.coordinate.latitude,
            heading: max(fix.course, 0),
            speed: max(fix.speed, 0),
            status: status,
            lastSeenAt: ISO8601DateFormatter().string(from: .now),
            groupId: groupID,
            groupName: groupName
        )
        try? await channel.track(payload)
    }

    private func broadcastLocationToChannels() async {
        guard isSharing, let userID = supabase.userID, let fix = location.lastLocation else { return }
        for (groupID, channel) in realtimeChannels {
            let groupName = groups.first(where: { $0.id == groupID })?.name ?? "Group"
            let payload = LocationBroadcast(
                userId: userID,
                displayName: supabase.displayName.isEmpty ? "Rider" : supabase.displayName,
                lng: fix.coordinate.longitude,
                lat: fix.coordinate.latitude,
                heading: max(fix.course, 0),
                speed: max(fix.speed, 0),
                status: status,
                lastSeenAt: ISO8601DateFormatter().string(from: .now),
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

    @MainActor
    private func handleLocationMessage(_ message: JSONObject) {
        let payload: LocationBroadcast?
        if let nested = try? message["payload"]?.decode(as: LocationBroadcast.self) {
            payload = nested
        } else {
            payload = try? message.decode(as: LocationBroadcast.self)
        }
        guard let payload, let selfID = supabase.userID, payload.userId != selfID else { return }
        guard let lat = payload.lat, let lng = payload.lng, lat.isFinite, lng.isFinite else { return }

        let previousStatus = members.first(where: { $0.userID == payload.userId })?.status
        if let idx = members.firstIndex(where: { $0.userID == payload.userId }) {
            members[idx].isLive = true
            members[idx].latitude = lat
            members[idx].longitude = lng
            members[idx].lastSeenAt = .now
            if let status = payload.status, !status.isEmpty {
                members[idx].status = status
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
                    status: payload.status ?? old.status,
                    lastSeenAt: .now
                )
            }
        }
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
    private func handleSharingOffMessage(_ message: JSONObject) {
        let payload: SharingOffBroadcast?
        if let nested = try? message["payload"]?.decode(as: SharingOffBroadcast.self) {
            payload = nested
        } else {
            payload = try? message.decode(as: SharingOffBroadcast.self)
        }
        guard let payload, let selfID = supabase.userID, payload.userId != selfID else { return }
        if let idx = members.firstIndex(where: { $0.userID == payload.userId }) {
            members[idx].isLive = false
        }
        paintGroupOverlays()
    }

    @MainActor
    private func handlePresenceAction(_ action: any PresenceAction, groupID: String) {
        guard let selfID = supabase.userID else { return }
        if let joins = try? action.decodeJoins(as: LocationBroadcast.self) {
            for join in joins where join.userId != selfID {
                guard let lat = join.lat, let lng = join.lng else { continue }
                if let idx = members.firstIndex(where: { $0.userID == join.userId }) {
                    let old = members[idx]
                    members[idx] = GroupMemberRow(
                        userID: old.userID,
                        role: old.role,
                        displayName: Self.resolvedDisplayName(join.displayName ?? old.displayName),
                        isLive: true,
                        latitude: lat,
                        longitude: lng,
                        status: join.status ?? old.status ?? "available",
                        lastSeenAt: .now
                    )
                }
            }
        }
        if let leaves = try? action.decodeLeaves(as: LocationBroadcast.self) {
            for leave in leaves where leave.userId != selfID {
                if let idx = members.firstIndex(where: { $0.userID == leave.userId }) {
                    members[idx].isLive = false
                }
            }
        }
        // Also handle presence keyed by user id without full LocationBroadcast decode.
        for (key, presence) in action.joins where key != selfID {
            if let state = try? presence.decodeState(as: LocationBroadcast.self),
               let lat = state.lat, let lng = state.lng,
               let idx = members.firstIndex(where: { $0.userID == key }) {
                let old = members[idx]
                members[idx] = GroupMemberRow(
                    userID: old.userID,
                    role: old.role,
                    displayName: Self.resolvedDisplayName(state.displayName ?? old.displayName),
                    isLive: true,
                    latitude: lat,
                    longitude: lng,
                    status: state.status ?? old.status ?? "available",
                    lastSeenAt: .now
                )
            }
        }
        for key in action.leaves.keys where key != selfID {
            if let idx = members.firstIndex(where: { $0.userID == key }) {
                members[idx].isLive = false
            }
        }
        _ = groupID
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
