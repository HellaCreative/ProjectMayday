import Foundation

/// Offline queue for `route_incidents` upserts until Supabase accepts them.
enum RouteIncidentCloudQueue {
    private static let key = "dirt.route_incidents.pending.v1"

    struct Pending: Codable, Equatable, Identifiable {
        var id: UUID { clientId }
        let clientId: UUID
        let category: String
        let latitude: Double
        let longitude: Double
        let edgeId: String?
        let regionCode: String?
        let packVersion: String?
        let createdAt: Date
        let expiresAt: Date
        let status: String
    }

    static func load() -> [Pending] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rows = try? JSONDecoder().decode([Pending].self, from: data)
        else { return [] }
        return rows
    }

    static func save(_ rows: [Pending]) {
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func enqueue(
        _ report: RouteIncidentReport,
        regionCode: String?,
        packVersion: String?
    ) {
        var rows = load()
        rows.removeAll { $0.clientId == report.id }
        rows.append(
            Pending(
                clientId: report.id,
                category: report.category.rawValue,
                latitude: report.latitude,
                longitude: report.longitude,
                edgeId: report.edgeId,
                regionCode: regionCode,
                packVersion: packVersion,
                createdAt: report.createdAt,
                expiresAt: report.expiresAt,
                status: report.status
            )
        )
        save(rows)
    }

    static func remove(clientId: UUID) {
        var rows = load()
        rows.removeAll { $0.clientId == clientId }
        save(rows)
    }
}
