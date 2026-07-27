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

    var id: String { userID }
}

/// Groups parity with the web POC. Presence is persisted through the shared
/// `rider_presence` table (the same rows the web reads for live counts); the
/// native v1 polls that table instead of subscribing to the realtime channel.
@Observable
final class GroupsViewModel {
    private let supabase: SupabaseService
    private let location: LocationService
    private let mapState: MapState

    private(set) var groups: [GroupSummary] = []
    private(set) var selectedGroup: GroupSummary?
    private(set) var members: [GroupMemberRow] = []
    private(set) var isLoading = false
    private(set) var isSharing = false
    var status = "available"
    var errorMessage: String?

    private var shareTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Group whose live peers stay on the map after the sheet closes (HTML keeps
    /// markers while the group channel is active).
    private var mapTrackedGroupID: String?

    init(supabase: SupabaseService, location: LocationService, mapState: MapState) {
        self.supabase = supabase
        self.location = location
        self.mapState = mapState
    }

    /// Resolves a map rider annotation id (`rider:<userID>`) to the roster row.
    func member(forRiderMarkerID markerID: String) -> GroupMemberRow? {
        guard markerID.hasPrefix("rider:") else { return nil }
        let userID = String(markerID.dropFirst("rider:".count))
        return members.first { $0.userID == userID }
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
        } catch {
            errorMessage = "Could not load your riding groups."
        }
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
    }

    func closeDetail() {
        selectedGroup = nil
        // Keep polling + pins for the last opened group so peers stay visible
        // on the map while riding (HTML parity). Leave/delete clears tracking.
        if let mapTrackedGroupID {
            startPresencePolling(groupID: mapTrackedGroupID)
        } else {
            members = []
            pollTask?.cancel()
            pollTask = nil
            clearRiderMarkers()
        }
    }

    private func startPresencePolling(groupID: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.mapTrackedGroupID == groupID {
                await self.refreshMembers(groupID: groupID)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func stopMapTracking() {
        mapTrackedGroupID = nil
        members = []
        pollTask?.cancel()
        pollTask = nil
        clearRiderMarkers()
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
                    }()
                )
            }
            paintLiveRiders()
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

    /// Direct profiles lookup — nested `profiles(display_name)` on group_members
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

    private func paintLiveRiders() {
        let selfID = supabase.userID
        let markers = members.compactMap { member -> MapState.Marker? in
            guard member.isLive,
                  member.userID != selfID,
                  let lat = member.latitude,
                  let lon = member.longitude else { return nil }
            return MapState.Marker(
                id: "rider:\(member.userID)",
                latitude: lat,
                longitude: lon,
                label: member.displayName,
                kind: .rider,
                subtitle: member.displayName,
                status: member.status ?? "available"
            )
        }
        // Preserve route A/B markers already drawn by the planner; only swap rider pins.
        let nonRiders = mapState.markers.filter { $0.kind != .rider }
        mapState.setMarkers(nonRiders + markers)
    }

    private func clearRiderMarkers() {
        let nonRiders = mapState.markers.filter { $0.kind != .rider }
        mapState.setMarkers(nonRiders)
    }

    // MARK: - Presence sharing

    func startSharing() {
        guard supabase.userID != nil else { return }
        isSharing = true
        location.requestAlways()
        location.setBackgroundUpdates(true)
        location.startUpdates()
        shareTask?.cancel()
        shareTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isSharing {
                await self.publishPresence(enabled: true)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopSharing() {
        isSharing = false
        shareTask?.cancel()
        shareTask = nil
        Task { await publishPresence(enabled: false) }
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
