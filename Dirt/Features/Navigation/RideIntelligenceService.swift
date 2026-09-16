import Foundation
import Supabase

/// Cloud sync for route incidents + opt-in track contributions.
/// Does not replace group `rider_alerts` (distress). Best-effort; local always wins.
@MainActor
final class RideIntelligenceService {
    private let supabase: SupabaseService

    init(supabase: SupabaseService) {
        self.supabase = supabase
    }

    // MARK: - Incidents

    func enqueueAndFlush(
        _ report: RouteIncidentReport,
        regionCode: String?,
        packVersion: String?
    ) {
        RouteIncidentCloudQueue.enqueue(report, regionCode: regionCode, packVersion: packVersion)
        Task { await flushPendingIncidents() }
    }

    func flushPendingIncidents() async {
        guard supabase.isSignedIn, let client = supabase.client, let userID = supabase.userID else { return }
        let pending = RouteIncidentCloudQueue.load()
        guard !pending.isEmpty else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for row in pending {
            struct Insert: Encodable {
                let client_id: String
                let user_id: String
                let category: String
                let status: String
                let latitude: Double
                let longitude: Double
                let edge_id: String?
                let region_code: String?
                let pack_version: String?
                let created_at: String
                let expires_at: String
                let source: String
            }
            let body = Insert(
                client_id: row.clientId.uuidString.lowercased(),
                user_id: userID,
                category: row.category,
                status: row.status,
                latitude: row.latitude,
                longitude: row.longitude,
                edge_id: row.edgeId,
                region_code: row.regionCode,
                pack_version: row.packVersion,
                created_at: iso.string(from: row.createdAt),
                expires_at: iso.string(from: row.expiresAt),
                source: "rider_report"
            )
            do {
                try await client
                    .from("route_incidents")
                    .upsert(body, onConflict: "client_id")
                    .execute()
                RouteIncidentCloudQueue.remove(clientId: row.clientId)
            } catch {
                // Keep in queue; retry on next sign-in / report / contribute.
                break
            }
        }
    }

    // MARK: - Track contributions

    func contributeTrack(
        edgeIds: [String],
        distanceMeters: Double?,
        regionCodes: [String],
        packVersion: String?,
        startedAt: Date?,
        endedAt: Date = Date()
    ) async -> Bool {
        let cleaned = RideEdgeSequence.sanitize(edgeIds)
        guard cleaned.count >= 3 else { return false }
        guard let client = supabase.client, let userID = supabase.userID else { return false }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        struct Insert: Encodable {
            let user_id: String
            let edge_ids: [String]
            let distance_m: Double?
            let region_codes: [String]?
            let pack_version: String?
            let started_at: String?
            let ended_at: String
            let consent_version: String
        }
        let body = Insert(
            user_id: userID,
            edge_ids: cleaned,
            distance_m: distanceMeters,
            region_codes: regionCodes.isEmpty ? nil : regionCodes,
            pack_version: packVersion,
            started_at: startedAt.map { iso.string(from: $0) },
            ended_at: iso.string(from: endedAt),
            consent_version: RideEdgeSequence.consentVersion
        )
        do {
            try await client.from("track_contributions").insert(body).execute()
            return true
        } catch {
            return false
        }
    }
}

/// Opt-in preference for post-ride track contribution prompts.
enum TrackContributePrefs {
    static let enabledKey = "dirt.contributeTracks.enabled.v1"
    static let askedKey = "dirt.contributeTracks.asked.v1"

    /// When true, end-of-ride may offer / auto-ask to upload edge sequences.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var hasBeenAsked: Bool {
        get { UserDefaults.standard.bool(forKey: askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: askedKey) }
    }

    /// Tester replay: restore default-off contribute so first-run can ask again.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: askedKey)
    }
}
