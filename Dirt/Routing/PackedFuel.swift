import Foundation

/// Motorcycle-usable fuel baked into a region pack (`fuel.v1.json`).
/// Pack-time twin of `build-fuel-pack.js` — never fetched from Overpass on device.
nonisolated enum PackedFuel {
    struct File: Decodable, Sendable {
        var schema: String?
        var regionId: String?
        var stations: [Station]
    }

    struct Station: Decodable, Sendable {
        var id: String
        var lat: Double
        var lon: Double
        var name: String?
        var brand: String?
        var address: String?
        var openingHours: String?
        var phone: String?
        var website: String?
    }

    static func decode(_ data: Data) -> [POIFeature] {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.stations.compactMap { s in
            guard s.lat.isFinite, s.lon.isFinite else { return nil }
            return POIFeature(
                id: s.id,
                category: "fuel",
                latitude: s.lat,
                longitude: s.lon,
                name: s.name,
                address: s.address,
                brand: s.brand,
                openingHours: s.openingHours,
                phone: s.phone,
                website: s.website
            )
        }
    }
}
