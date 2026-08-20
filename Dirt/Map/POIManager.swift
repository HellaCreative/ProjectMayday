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

    /// Human-readable category label.
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


private enum POIC {
    static let minZoom = 6.5
    static let refreshDelay = UInt64(350_000_000)
}

/// Loads Rider Services POIs. Online planning fuel comes from the same live
/// candidate as `/api/route`; offline fuel comes from the installed pack.
/// Camp / lodging / liquor still use OSM Overpass for the current viewport.
/// Fuel goes through `FuelPOIFilter` at pack build time (bulk / cardlock / truck-only / closed).
@MainActor
final class POIManager {
    enum FuelSourceError: LocalizedError {
        case liveUnavailable

        var errorDescription: String? {
            switch self {
            case .liveUnavailable:
                "Live fuel data is unavailable. Check your connection and try again."
            }
        }
    }

    private let mapState: MapState
    private let graphPacks: GraphPackStore
    private let network: NetworkPathMonitor
    private var debounceTask: Task<Void, Never>?
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = ["User-Agent": "DIRT-iOS/1.0 (dual-sport navigator)"]
        return URLSession(configuration: cfg)
    }()

    init(mapState: MapState, graphPacks: GraphPackStore, network: NetworkPathMonitor) {
        self.mapState = mapState
        self.graphPacks = graphPacks
        self.network = network
        armObservation()
    }

    /// Fuel stations in the A→B geographic box. Live planning deliberately
    /// asks the candidate-aware API exclusively. Offline planning uses the
    /// installed sidecar exclusively. Neither path uses Overpass.
    func fuelCandidates(
        from start: RouteCoordinate,
        to end: RouteCoordinate,
        preferLive: Bool
    ) async throws -> [POIFeature] {
        if preferLive {
            let live = try await liveFuelCandidates(
                from: start,
                to: end,
                padDegrees: 150_000.0 / 111_000.0
            )
            let collapsed = POIDeduper.collapseNearby(live)
            RoutingDebugLog.shared.event(
                "fuel search packed=\(live.count) usable=\(collapsed.count) source=live-pack"
            )
            return collapsed
        }
        let packed = graphPacks.fuelStations(from: start, to: end)
        let collapsed = POIDeduper.collapseNearby(packed)
        RoutingDebugLog.shared.event(
            "fuel search packed=\(packed.count) usable=\(collapsed.count) source=installed-pack"
        )
        return collapsed
    }

    private func liveFuelCandidates(
        from start: RouteCoordinate,
        to end: RouteCoordinate,
        padDegrees: Double
    ) async throws -> [POIFeature] {
        struct Request: Encodable {
            let locations: [RouteLocation]
        }
        var request = URLRequest(url: AppConfig.liveFuelURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONEncoder().encode(Request(locations: [
            RouteLocation(latitude: start.latitude, longitude: start.longitude, label: "A"),
            RouteLocation(latitude: end.latitude, longitude: end.longitude, label: "B")
        ]))
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                RoutingDebugLog.shared.event("fuel live source rejected")
                throw FuelSourceError.liveUnavailable
            }
            let all = PackedFuel.decode(data)
            // Match the installed-pack prefilter. It is intentionally generous:
            // adventure routes can sit far outside their straight A→B box.
            return all.filter {
                $0.latitude >= min(start.latitude, end.latitude) - padDegrees
                    && $0.latitude <= max(start.latitude, end.latitude) + padDegrees
                    && $0.longitude >= min(start.longitude, end.longitude) - padDegrees
                    && $0.longitude <= max(start.longitude, end.longitude) + padDegrees
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // Pin dragging deliberately cancels the stale planning job. It is
            // not a live-service outage and must not become a red fuel error.
            throw CancellationError()
        } catch let error as NSError
            where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            // URLSession occasionally bridges cancellation as NSError rather
            // than URLError. Treat both representations identically.
            throw CancellationError()
        } catch {
            RoutingDebugLog.shared.event(
                "fuel live source failed: \(error.localizedDescription)"
            )
            if error is FuelSourceError { throw error }
            throw FuelSourceError.liveUnavailable
        }
    }

    private func armObservation() {
        withObservationTracking {
            _ = mapState.mapCenter.latitude
            _ = mapState.mapCenter.longitude
            _ = mapState.mapZoom
            _ = mapState.layerPrefsGeneration
            _ = network.isOnline
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

    private func performRefresh() async {
        let zoom = mapState.mapZoom
        let center = mapState.mapCenter
        let prefs = LayerPrefsSnapshot()

        guard zoom >= POIC.minZoom, prefs.anyPOIEnabled else {
            mapState.updatePOIFeatures([])
            return
        }

        let overview = zoom < 9.0
        let padKm = overview ? 28.0 : 4.0
        let padDeg = padKm / 111.0
        let bbox = _BBox(
            minLon: center.longitude - padDeg,
            minLat: center.latitude - padDeg,
            maxLon: center.longitude + padDeg,
            maxLat: center.latitude + padDeg
        )
        var features: [POIFeature] = []
        if prefs.showFuel {
            if network.isOnline {
                let from = RouteCoordinate(longitude: bbox.minLon, latitude: bbox.minLat)
                let to = RouteCoordinate(longitude: bbox.maxLon, latitude: bbox.maxLat)
                do {
                    let live = try await liveFuelCandidates(
                        from: from,
                        to: to,
                        padDegrees: 0
                    )
                    features.append(contentsOf: live)
                    RoutingDebugLog.shared.event(
                        "fuel viewport packed=\(live.count) source=live-pack"
                    )
                } catch is CancellationError {
                    return
                } catch {
                    // Online means live-only. Do not paint stale downloaded fuel.
                    RoutingDebugLog.shared.event("fuel viewport live source unavailable")
                }
            } else {
                let installed = graphPacks.fuelStations(
                    minLat: bbox.minLat, maxLat: bbox.maxLat,
                    minLon: bbox.minLon, maxLon: bbox.maxLon
                )
                features.append(contentsOf: installed)
                RoutingDebugLog.shared.event(
                    "fuel viewport packed=\(installed.count) source=installed-pack"
                )
            }
        }
        let needOverpass = prefs.showCampgrounds || prefs.showLodging || prefs.showLiquor
        if needOverpass {
            do {
                let raw = try await fetchOSM(bbox: bbox)
                features.append(contentsOf: raw.compactMap { feature(from: $0, prefs: prefs, fuelOnly: false) })
            } catch {
                // Keep last paint when Overpass is unreachable.
            }
        }
        mapState.updatePOIFeatures(POIDeduper.collapseNearby(features))
    }

    private func fetchOSM(bbox: _BBox) async throws -> [_OSMElement] {
        let query = """
        [out:json][timeout:25];
        (
          nwr["tourism"~"^(hotel|motel|hostel|guest_house|chalet)$"](\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon));
          nwr["tourism"~"^(camp_site|caravan_site)$"](\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon));
          nwr["shop"="alcohol"](\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon));
        );
        out center tags;
        """
        var request = URLRequest(url: AppConfig.overpassURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        request.httpBody = "data=\(encoded)".data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(_OSMResponse.self, from: data).elements
    }

    private func feature(from el: _OSMElement, prefs: LayerPrefsSnapshot?, fuelOnly: Bool) -> POIFeature? {
        let tags = el.tags ?? [:]
        guard let category = category(for: tags) else { return nil }
        if category == "fuel" { return nil }
        if let prefs, !prefs.isPOIEnabled(category: category) { return nil }
        let lat = el.lat ?? el.center?.lat
        let lon = el.lon ?? el.center?.lon
        guard let lat, let lon else { return nil }
        if category == "fuel" {
            let input = FuelPOIFilter.Input(
                name: tags["name"] ?? tags["brand"] ?? tags["operator"],
                brand: tags["brand"] ?? tags["operator"],
                openingHours: tags["opening_hours"],
                tags: tags
            )
            guard FuelPOIFilter.isMotorcycleUsable(input) else { return nil }
        }
        let line1 = [tags["addr:housenumber"], tags["addr:street"]].compactMap { $0 }.joined(separator: " ")
        let addressParts = [line1, tags["addr:city"], tags["addr:province"] ?? tags["addr:state"], tags["addr:postcode"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return POIFeature(
            id: "osm:\(el.type ?? "n")\(el.id)",
            category: category,
            latitude: lat,
            longitude: lon,
            name: tags["name"] ?? tags["brand"] ?? tags["operator"],
            address: addressParts.isEmpty ? nil : addressParts.joined(separator: ", "),
            brand: tags["brand"] ?? tags["operator"],
            openingHours: tags["opening_hours"],
            phone: tags["phone"] ?? tags["contact:phone"],
            website: tags["website"] ?? tags["contact:website"]
        )
    }

    private func category(for tags: [String: String]) -> String? {
        if tags["amenity"] == "fuel" { return "fuel" }
        if tags["shop"] == "alcohol" { return "liquor" }
        switch tags["tourism"] {
        case "hotel", "motel", "hostel", "guest_house", "chalet": return "lodging"
        case "camp_site", "caravan_site": return "campground"
        default: return nil
        }
    }
}

nonisolated private struct _BBox: Sendable {
    let minLon, minLat, maxLon, maxLat: Double
}

nonisolated private struct _OSMResponse: Decodable, Sendable {
    let elements: [_OSMElement]
}

nonisolated private struct _OSMElement: Decodable, Sendable {
    let id: Int
    let type: String?
    let lat: Double?
    let lon: Double?
    let center: _OSMCenter?
    let tags: [String: String]?
}

nonisolated private struct _OSMCenter: Decodable, Sendable {
    let lat: Double
    let lon: Double
}
