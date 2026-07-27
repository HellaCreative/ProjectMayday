import CoreLocation
import Foundation
import Observation

// MARK: - POI feature model (shared with MapLibreMapView and RootView)

struct POIFeature: Sendable {
    let id: String
    let category: String  // "fuel" | "campground" | "lodging" | "liquor"
    let latitude: Double
    let longitude: Double
    let name: String?
    let address: String?
    let brand: String?
    let openingHours: String?
    let phone: String?
    let website: String?

    /// Human-readable category label matching web POC POI_CATEGORIES.
    var categoryLabel: String {
        switch category {
        case "fuel":       return "Fuel"
        case "campground": return "Campground"
        case "lodging":    return "Lodging"
        case "liquor":     return "Liquor store"
        default:           return category
        }
    }

    /// Display name for routing (prefers explicit name, falls back to category label).
    var displayName: String { name ?? categoryLabel }
}

/// Collapse OSM duplicates (e.g. many unnamed `camp_site` nodes in one park)
/// into a single map pin per local cluster. Pure geometry helper — not MainActor.
enum POIDeduper {
    static func collapseNearby(_ features: [POIFeature]) -> [POIFeature] {
        var kept: [POIFeature] = []
        for feature in features {
            if let index = kept.firstIndex(where: {
                $0.category == feature.category
                    && distanceMeters($0, feature) <= radiusMeters(for: feature.category)
            }) {
                kept[index] = merge(kept[index], feature)
            } else {
                kept.append(feature)
            }
        }
        return kept
    }

    static func radiusMeters(for category: String) -> Double {
        switch category {
        case "campground": return 450
        case "lodging": return 120
        case "fuel": return 55
        case "liquor": return 80
        default: return 100
        }
    }

    private static func merge(_ a: POIFeature, _ b: POIFeature) -> POIFeature {
        let preferB = (a.name == nil || a.name?.isEmpty == true) && (b.name?.isEmpty == false)
        let primary = preferB ? b : a
        let secondary = preferB ? a : b
        return POIFeature(
            id: primary.id,
            category: primary.category,
            latitude: (primary.latitude + secondary.latitude) / 2,
            longitude: (primary.longitude + secondary.longitude) / 2,
            name: primary.name ?? secondary.name,
            address: primary.address ?? secondary.address,
            brand: primary.brand ?? secondary.brand,
            openingHours: primary.openingHours ?? secondary.openingHours,
            phone: primary.phone ?? secondary.phone,
            website: primary.website ?? secondary.website
        )
    }

    private static func distanceMeters(_ a: POIFeature, _ b: POIFeature) -> Double {
        let R = 6_371_000.0
        let toR = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * toR
        let dLon = (b.longitude - a.longitude) * toR
        let lat1 = a.latitude * toR
        let lat2 = b.latitude * toR
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(min(1, sqrt(h)))
    }
}

// MARK: - Constants

private enum POIC {
    static let manifestURL  = URL(string: "https://dirt-mayday.vercel.app/app/data/poi/poi.manifest.json")!
    static let chunkBase    = "https://dirt-mayday.vercel.app/app/data/poi/chunks/"
    /// Show planning dots from regional overview (~province) zoom.
    static let minZoom      = 6.5
    /// Load more chunks when zoomed out so overview still has coverage.
    static let maxChunksOverview = 22
    static let maxChunksDetail = 14
    static let refreshDelay = UInt64(350_000_000)   // 350 ms in nanoseconds
}

// MARK: - POIManager

/// Loads Rider Services POIs from the production Vercel CDN.  Mirrors the web
/// POC chunk-corridor loader: fetches only the chunks that intersect the
/// current viewport, caps at POIC.maxChunks, filters by enabled categories,
/// and publishes the result to `MapState.poiFeatures`.
///
/// Lifecycle: one instance per AppEnvironment, lives as long as the app.
@MainActor
final class POIManager {
    private let mapState: MapState
    private var manifest: _POIManifest?
    private var manifestTask: Task<_POIManifest, Error>?
    /// In-memory chunk store keyed by chunk id.
    private var chunkCache: [String: [_POIRaw]] = [:]
    private var debounceTask: Task<Void, Never>?

    init(mapState: MapState) {
        self.mapState = mapState
        armObservation()
    }

    // MARK: - Observation loop

    /// Re-arms after each change.  withObservationTracking fires once per
    /// change batch, so we call scheduleRefresh and then re-arm immediately.
    private func armObservation() {
        withObservationTracking {
            _ = mapState.mapCenter.latitude
            _ = mapState.mapCenter.longitude
            _ = mapState.mapZoom
            _ = mapState.layerPrefsGeneration
        } onChange: {
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
                self?.armObservation()
            }
        }
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: POIC.refreshDelay)
            guard !Task.isCancelled else { return }
            await self?.performRefresh()
        }
    }

    // MARK: - Data refresh

    private func performRefresh() async {
        let zoom   = mapState.mapZoom
        let center = mapState.mapCenter
        let prefs  = LayerPrefsSnapshot()

        guard zoom >= POIC.minZoom, prefs.anyPOIEnabled else {
            mapState.updatePOIFeatures([])
            return
        }

        do {
            let manifest = try await ensureManifest()
            // Wider corridor + more chunks when zoomed out for plan-route overview.
            let overview = zoom < 9.0
            let padKm = overview ? 28.0 : 4.0
            let padDeg = padKm / 111.0
            let maxChunks = overview ? POIC.maxChunksOverview : POIC.maxChunksDetail
            let bbox = _BBox(
                minLon: center.longitude - padDeg,
                minLat: center.latitude  - padDeg,
                maxLon: center.longitude + padDeg,
                maxLat: center.latitude  + padDeg
            )
            let nearChunks = manifest.chunks
                .filter { bboxIntersects($0.bbox, bbox) }
                .prefix(maxChunks)

            await loadChunks(Array(nearChunks), buildStamp: manifest.generatedAt)

            // Evict chunks that are no longer nearby.
            let keepIds = Set(nearChunks.map { $0.id })
            chunkCache = chunkCache.filter { keepIds.contains($0.key) }

            let features = collectFeatures(prefs: prefs)
            mapState.updatePOIFeatures(features)
        } catch {
            // Network errors offline: keep existing data; do not clear.
        }
    }

    // MARK: - Manifest

    private func ensureManifest() async throws -> _POIManifest {
        if let cached = manifest { return cached }
        if let existing = manifestTask {
            do {
                let result = try await existing.value
                manifest = result
                return result
            } catch {
                // Failed task must not stick for the session — allow a later refresh to retry.
                manifestTask = nil
                throw error
            }
        }
        let task = Task<_POIManifest, Error> {
            let (data, _) = try await URLSession.shared.data(from: POIC.manifestURL)
            return try JSONDecoder().decode(_POIManifest.self, from: data)
        }
        manifestTask = task
        do {
            let result = try await task.value
            manifest = result
            manifestTask = nil
            return result
        } catch {
            manifestTask = nil
            throw error
        }
    }

    // MARK: - Chunk loading

    private func loadChunks(_ chunks: [_POIChunk], buildStamp: String) async {
        await withTaskGroup(of: (String, [_POIRaw])?.self) { group in
            for chunk in chunks where chunkCache[chunk.id] == nil {
                group.addTask { [weak self] in
                    await self?.fetchChunk(chunk)
                }
            }
            for await result in group {
                if let (id, pois) = result {
                    chunkCache[id] = pois
                }
            }
        }
    }

    private func fetchChunk(_ chunk: _POIChunk) async -> (String, [_POIRaw])? {
        guard let url = URL(string: POIC.chunkBase + chunk.file) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Decompress + decode on a background thread for large files.
            let pois: [_POIRaw] = try await Task.detached(priority: .background) {
                let raw = try data.gunzipped()
                return try JSONDecoder().decode(_POIChunkPayload.self, from: raw).pois
            }.value
            return (chunk.id, pois)
        } catch {
            return nil
        }
    }

    // MARK: - Feature collection

    private func collectFeatures(prefs: LayerPrefsSnapshot) -> [POIFeature] {
        var out: [POIFeature] = []
        for raws in chunkCache.values {
            for raw in raws where prefs.isPOIEnabled(category: raw.category) {
                out.append(POIFeature(
                    id:           raw.id,
                    category:     raw.category,
                    latitude:     raw.lat,
                    longitude:    raw.lon,
                    name:         raw.name,
                    address:      raw.address,
                    brand:        raw.brand,
                    openingHours: raw.openingHours,
                    phone:        raw.phone,
                    website:      raw.website
                ))
            }
        }
        return POIDeduper.collapseNearby(out)
    }

    // MARK: - Helpers

    private struct _BBox {
        let minLon, minLat, maxLon, maxLat: Double
    }

    private func bboxIntersects(_ bbox: [Double], _ b: _BBox) -> Bool {
        guard bbox.count >= 4 else { return false }
        return bbox[0] <= b.maxLon && bbox[2] >= b.minLon &&
               bbox[1] <= b.maxLat && bbox[3] >= b.minLat
    }
}

// MARK: - Decodable models (private, prefixed to avoid top-level collisions)
// `nonisolated` — default MainActor isolation would make Decodable unusable in Task.detached.

nonisolated private struct _POIManifest: Decodable, Sendable {
    let generatedAt: String
    let chunks: [_POIChunk]
}

nonisolated private struct _POIChunk: Decodable, Sendable {
    let id: String
    let file: String
    let bbox: [Double]
}

nonisolated private struct _POIChunkPayload: Decodable, Sendable {
    let pois: [_POIRaw]
}

nonisolated private struct _POIRaw: Decodable, Sendable {
    let id: String
    let category: String
    let lat: Double
    let lon: Double
    let name: String?
    let address: String?
    let brand: String?
    let openingHours: String?
    let phone: String?
    let website: String?
}
