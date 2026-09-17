import CoreLocation
import Foundation
import Observation
import UIKit

// MARK: - POI feature model (shared with MapLibreMapView and RootView)

nonisolated struct POIFeature: Sendable {
    let id: String
    let category: String  // "fuel" | "campground" | "lodging" | "liquor" | "attraction"
    let latitude: Double
    let longitude: Double
    let name: String?
    let address: String?
    let brand: String?
    let openingHours: String?
    let phone: String?
    let website: String?
    /// OSM attraction subclass: viewpoint, attraction, cave, waterfall, lighthouse, beach.
    let kind: String?

    init(
        id: String,
        category: String,
        latitude: Double,
        longitude: Double,
        name: String?,
        address: String?,
        brand: String?,
        openingHours: String?,
        phone: String?,
        website: String?,
        kind: String? = nil
    ) {
        self.id = id
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.address = address
        self.brand = brand
        self.openingHours = openingHours
        self.phone = phone
        self.website = website
        self.kind = kind
    }

    /// Human-readable category label.
    var categoryLabel: String {
        switch category {
        case "fuel":       return "Fuel"
        case "campground": return "Campground"
        case "lodging":    return "Lodging"
        case "liquor":     return "Liquor store"
        case "attraction":
            return MapAttraction.title(for: kind) ?? "Attraction"
        default:           return category
        }
    }

    /// Display name for routing (prefers explicit name, falls back to category label).
    var displayName: String { name ?? categoryLabel }

    /// Tap sheet: named marks are `Name · Type`; unnamed marks are just the type.
    var popupTitle: String {
        if category == "attraction" {
            let type = categoryLabel
            if let name, !name.isEmpty { return "\(name) · \(type)" }
            return type
        }
        var parts = [displayName]
        if let brand, !brand.isEmpty, brand != displayName {
            parts.append(brand)
        }
        if let address, !address.isEmpty {
            parts.append(address)
        }
        if name == nil || name?.isEmpty == true {
            return categoryLabel
        }
        if displayName.caseInsensitiveCompare(categoryLabel) != .orderedSame {
            parts.append(categoryLabel)
        }
        return parts.joined(separator: " · ")
    }
}

enum MapAttractionKind: String, CaseIterable, Sendable {
    case viewpoint
    case attraction
    case cave
    case waterfall
    case lighthouse
    case beach

    var title: String {
        switch self {
        case .viewpoint: return "Viewpoint"
        case .attraction: return "Attraction"
        case .cave: return "Cave"
        case .waterfall: return "Waterfall"
        case .lighthouse: return "Lighthouse"
        case .beach: return "Beach"
        }
    }

    var preferenceKey: String { "dirt.layers.attraction.\(rawValue)" }

    /// Beaches are coastal landcover and flood NS; other kinds default on.
    var defaultOn: Bool { self != .beach }

    var systemSymbolName: String {
        switch self {
        case .viewpoint: return "binoculars.fill"
        case .attraction: return "star.fill"
        case .cave: return "triangle.fill"
        case .waterfall: return "drop.fill"
        case .lighthouse: return "lighthouse.fill"
        case .beach: return "beach.umbrella.fill"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .viewpoint: return UIColor(red: 0.055, green: 0.486, blue: 0.482, alpha: 1)
        case .attraction: return UIColor(red: 0.769, green: 0.361, blue: 0.149, alpha: 1)
        case .cave: return UIColor(red: 0.361, green: 0.290, blue: 0.227, alpha: 1)
        case .waterfall: return UIColor(red: 0.169, green: 0.482, blue: 0.710, alpha: 1)
        case .lighthouse: return UIColor(red: 0.788, green: 0.635, blue: 0.153, alpha: 1)
        case .beach: return UIColor(red: 0.831, green: 0.627, blue: 0.090, alpha: 1)
        }
    }

    var iconName: String { "dirt-attraction-icon-\(rawValue)" }

    var layerIDs: [String] {
        switch self {
        case .beach: return ["dirt-attraction-beach", "dirt-attraction-beach-land"]
        default: return ["dirt-attraction-\(rawValue)"]
        }
    }

    var specs: [(id: String, predicate: NSPredicate, sourceLayer: String, minZoom: Double)] {
        switch self {
        case .viewpoint:
            return [(
                layerIDs[0],
                Self.equals("tourism", "viewpoint")
                    .or(Self.equals("kind", "viewpoint"))
                    .or(Self.equals("kind", "viewing_point")),
                "pois",
                13
            )]
        case .attraction:
            return [(
                layerIDs[0],
                Self.equals("tourism", "attraction").or(Self.equals("kind", "attraction")),
                "pois",
                13
            )]
        case .cave:
            return [(
                layerIDs[0],
                Self.equals("natural", "cave_entrance")
                    .or(Self.equals("kind", "cave"))
                    .or(Self.equals("kind", "cave_entrance")),
                "pois",
                13
            )]
        case .waterfall:
            return [(
                layerIDs[0],
                Self.equals("natural", "waterfall")
                    .or(Self.equals("waterway", "waterfall"))
                    .or(Self.equals("kind", "waterfall")),
                "pois",
                13
            )]
        case .lighthouse:
            return [(
                layerIDs[0],
                Self.equals("man_made", "lighthouse").or(Self.equals("kind", "lighthouse")),
                "pois",
                13
            )]
        case .beach:
            return [
                (
                    "dirt-attraction-beach",
                    Self.equals("natural", "beach")
                        .or(Self.equals("leisure", "beach")),
                    "pois",
                    13
                ),
                (
                    "dirt-attraction-beach-land",
                    Self.equals("kind", "beach"),
                    "land",
                    10
                )
            ]
        }
    }

    private static func equals(_ key: String, _ value: String) -> NSPredicate {
        NSPredicate(format: "%K == %@", key, value)
    }
}

private extension NSPredicate {
    func or(_ other: NSPredicate) -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [self, other])
    }
}

enum MapAttraction {
    static let layerIDs = MapAttractionKind.allCases.flatMap(\.layerIDs)
    static let builtinLayerIDs = [
        "pois-tourism-lightbrown-imagename-15"
    ]

    nonisolated static func title(for kind: String?) -> String? {
        MapAttractionKind(rawValue: kind ?? "")?.title
    }

    nonisolated static func kind(from attrs: [AnyHashable: Any]) -> String? {
        func token(_ key: String) -> String {
            (attrs[key] as? String ?? "").lowercased()
        }
        let natural = token("natural")
        let leisure = token("leisure")
        let tourism = token("tourism")
        let waterway = token("waterway")
        let manMade = token("man_made")
        let kind = token("kind")
        if token("dirt:kind").isEmpty == false,
           let packed = MapAttractionKind(rawValue: token("dirt:kind")) {
            return packed.rawValue
        }
        if tourism == "viewpoint" || kind == "viewpoint" || kind == "viewing_point" {
            return MapAttractionKind.viewpoint.rawValue
        }
        if natural == "waterfall" || waterway == "waterfall" || kind == "waterfall" {
            return MapAttractionKind.waterfall.rawValue
        }
        if natural == "cave_entrance" || kind == "cave" || kind == "cave_entrance" {
            return MapAttractionKind.cave.rawValue
        }
        if manMade == "lighthouse" || kind == "lighthouse" {
            return MapAttractionKind.lighthouse.rawValue
        }
        if tourism == "attraction" || kind == "attraction" {
            return MapAttractionKind.attraction.rawValue
        }
        if natural == "beach" || leisure == "beach" || kind == "beach" {
            return MapAttractionKind.beach.rawValue
        }
        return nil
    }
}

/// Collapse OSM duplicates (e.g. many unnamed `camp_site` nodes in one park)
/// into a single map pin per local cluster. Pure geometry helper — not MainActor.
enum POIDeduper {
    static func collapseNearby(_ features: [POIFeature]) -> [POIFeature] {
        var kept: [POIFeature] = []
        for feature in features {
            if let index = kept.firstIndex(where: {
                $0.category == feature.category
                    && $0.kind == feature.kind
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
        case "attraction": return 40
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
            website: primary.website ?? secondary.website,
            kind: primary.kind ?? secondary.kind
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

/// Stable station cache indexed by geographic cells. Viewport responses merge
/// into it by station ID; zooming only changes presentation, not station truth.
struct FuelViewportCache {
    private struct Cell: Hashable {
        let longitude: Int
        let latitude: Int
    }

    private static let cellDegrees = 0.25
    private(set) var sourceID: String?
    private(set) var successfulCoverages: [MapViewportBounds] = []
    private var featuresByID: [String: POIFeature] = [:]
    private var cellByID: [String: Cell] = [:]
    private var IDsByCell: [Cell: Set<String>] = [:]

    var count: Int { featuresByID.count }

    /// Returns true when changing live/installed source invalidated the cache.
    mutating func prepare(for sourceID: String) -> Bool {
        guard self.sourceID != sourceID else { return false }
        self.sourceID = sourceID
        successfulCoverages = []
        featuresByID = [:]
        cellByID = [:]
        IDsByCell = [:]
        return true
    }

    func covers(_ bounds: MapViewportBounds) -> Bool {
        successfulCoverages.contains { $0.contains(bounds) }
    }

    mutating func merge(_ features: [POIFeature], coverage: MapViewportBounds) {
        for feature in features where feature.category == "fuel" {
            let newCell = Self.cell(latitude: feature.latitude, longitude: feature.longitude)
            if let oldCell = cellByID[feature.id], oldCell != newCell {
                IDsByCell[oldCell]?.remove(feature.id)
            }
            featuresByID[feature.id] = feature
            cellByID[feature.id] = newCell
            IDsByCell[newCell, default: []].insert(feature.id)
        }
        successfulCoverages.append(coverage)
        if successfulCoverages.count > 24 {
            successfulCoverages.removeFirst(successfulCoverages.count - 24)
        }
    }

    func features(in bounds: MapViewportBounds) -> [POIFeature] {
        var IDs = Set<String>()
        let minCell = Self.cell(
            latitude: bounds.minLatitude,
            longitude: bounds.minLongitude
        )
        let maxCell = Self.cell(
            latitude: bounds.maxLatitude,
            longitude: bounds.maxLongitude
        )
        for longitude in minCell.longitude...maxCell.longitude {
            for latitude in minCell.latitude...maxCell.latitude {
                IDs.formUnion(IDsByCell[Cell(longitude: longitude, latitude: latitude)] ?? [])
            }
        }
        return IDs.compactMap { featuresByID[$0] }
            .filter { bounds.contains(latitude: $0.latitude, longitude: $0.longitude) }
            .sorted { lhs, rhs in
                lhs.id == rhs.id ? lhs.displayName < rhs.displayName : lhs.id < rhs.id
            }
    }

    private static func cell(latitude: Double, longitude: Double) -> Cell {
        Cell(
            longitude: Int(floor(longitude / cellDegrees)),
            latitude: Int(floor(latitude / cellDegrees))
        )
    }
}

/// Successful campground / lodging / liquor viewport results. This is kept
/// separate from packed fuel so a temporary upstream outage cannot erase the
/// last trustworthy service pins already shown to the rider.
struct RiderServiceViewportCache {
    private(set) var successfulCoverages: [MapViewportBounds] = []
    private var featuresByID: [String: POIFeature] = [:]

    var count: Int { featuresByID.count }

    func covers(_ bounds: MapViewportBounds) -> Bool {
        successfulCoverages.contains { $0.contains(bounds) }
    }

    mutating func merge(_ features: [POIFeature], coverage: MapViewportBounds) {
        for feature in features where feature.category != "fuel" {
            featuresByID[feature.id] = feature
        }
        successfulCoverages.append(coverage)
        if successfulCoverages.count > 24 {
            successfulCoverages.removeFirst(successfulCoverages.count - 24)
        }
    }

    func features(in bounds: MapViewportBounds) -> [POIFeature] {
        featuresByID.values
            .filter { bounds.contains(latitude: $0.latitude, longitude: $0.longitude) }
            .sorted { lhs, rhs in
                lhs.id == rhs.id ? lhs.displayName < rhs.displayName : lhs.id < rhs.id
            }
    }
}


private enum POIC {
    static let minZoom = 6.5
    static let refreshDelay = UInt64(350_000_000)
    static let viewportOverscan = 0.20
}

/// Loads Rider Services POIs. Online planning fuel comes from the same live
/// candidate as `/api/route`; offline fuel comes from the installed pack.
/// Camp / lodging / liquor use DIRT's packed regional service for the viewport.
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
    private let riderServicesStore = RiderServicesStore()
    private let attractionsStore = AttractionsStore()
    private var attractionViewportCache = RiderServiceViewportCache()
    private var lastAttractionPaint: [POIFeature] = []
    private var debounceTask: Task<Void, Never>?
    private var refreshInProgress = false
    private var refreshPending = false
    private var fuelViewportCache = FuelViewportCache()
    private var riderServiceViewportCache = RiderServiceViewportCache()
    private var lastRiderServicePaint: [POIFeature] = []
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
        padDegrees: Double,
        timeoutInterval: TimeInterval = 30
    ) async throws -> [POIFeature] {
        struct Request: Encodable {
            let locations: [RouteLocation]
        }
        var request = URLRequest(url: AppConfig.liveFuelURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval
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
            _ = mapState.visibleCoordinateBounds
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
        refreshPending = true
        guard !refreshInProgress else {
            RoutingDebugLog.shared.event("poi refresh queued reason=viewport-or-layer-change")
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: POIC.refreshDelay)
            guard !Task.isCancelled else { return }
            await self?.runScheduledRefresh()
        }
    }

    /// Once a rider-service request has reached the network, let it finish.
    /// Cancelling it only disconnects the phone; the serverless invocation can
    /// continue, creating a request storm. Camera
    /// or layer changes during a request collapse into one settled follow-up.
    private func runScheduledRefresh() async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        refreshPending = false
        await performRefresh()
        refreshInProgress = false
        if refreshPending {
            scheduleRefresh()
        }
    }

    private func performRefresh() async {
        let zoom = mapState.mapZoom
        let prefs = LayerPrefsSnapshot()

        guard zoom >= POIC.minZoom, prefs.anyPOIEnabled else {
            mapState.updatePOIFeatures([], packedAttractionsAvailable: false)
            return
        }
        guard let viewport = mapState.visibleCoordinateBounds else { return }
        let queryBounds = viewport.expanded(by: POIC.viewportOverscan)
        let bbox = _BBox(
            minLon: queryBounds.minLongitude,
            minLat: queryBounds.minLatitude,
            maxLon: queryBounds.maxLongitude,
            maxLat: queryBounds.maxLatitude
        )
        var features: [POIFeature] = []
        if prefs.showFuel {
            let sourceID = network.isOnline ? "live-pack" : "installed-pack"
            let sourceChanged = fuelViewportCache.prepare(for: sourceID)
            if sourceChanged {
                // Never paint installed-pack stations as if they were a live
                // response (or vice versa) while the new source is loading.
                mapState.updatePOIFeatures([])
            }
            if !fuelViewportCache.covers(queryBounds) {
                if network.isOnline {
                    let from = RouteCoordinate(longitude: bbox.minLon, latitude: bbox.minLat)
                    let to = RouteCoordinate(longitude: bbox.maxLon, latitude: bbox.maxLat)
                    do {
                        let live = try await liveFuelCandidates(
                            from: from,
                            to: to,
                            padDegrees: 0,
                            timeoutInterval: 5
                        )
                        fuelViewportCache.merge(live, coverage: queryBounds)
                        RoutingDebugLog.shared.event(
                            "fuel viewport packed=\(live.count) cached=\(fuelViewportCache.count) " +
                                "source=live-pack bounds=visible+20pct"
                        )
                    } catch is CancellationError {
                        // Continued map motion cancels stale work. Keep the last
                        // successful paint; the settled camera schedules another.
                        return
                    } catch {
                        // Fuel is independent from the other layer sidecars.
                        // Preserve any cached pumps and continue so a fuel
                        // timeout cannot suppress campground/lodging/liquor.
                        RoutingDebugLog.shared.event(
                            "fuel viewport live source unavailable preserved=\(fuelViewportCache.count)"
                        )
                    }
                } else {
                    let installed = graphPacks.fuelStations(
                        minLat: bbox.minLat, maxLat: bbox.maxLat,
                        minLon: bbox.minLon, maxLon: bbox.maxLon
                    )
                    fuelViewportCache.merge(installed, coverage: queryBounds)
                    RoutingDebugLog.shared.event(
                        "fuel viewport packed=\(installed.count) cached=\(fuelViewportCache.count) " +
                            "source=installed-pack bounds=visible+20pct"
                    )
                }
            } else {
                RoutingDebugLog.shared.event(
                    "fuel viewport cache hit source=\(sourceID) cached=\(fuelViewportCache.count)"
                )
            }
            features.append(contentsOf: fuelViewportCache.features(in: queryBounds))
        }
        let needRiderServices = prefs.showCampgrounds || prefs.showLodging || prefs.showLiquor
        if needRiderServices {
            var requestFailed = false
            if !riderServiceViewportCache.covers(queryBounds) {
                do {
                    let raw: [RiderServiceElement]
                    if network.isOnline {
                        do {
                            raw = try await fetchRiderServices(bbox: bbox)
                            Task { [riderServicesStore] in
                                do {
                                    try await riderServicesStore.refreshCache(in: queryBounds)
                                    RoutingDebugLog.shared.event(
                                        "poi offline cache verified source=dirt-r2"
                                    )
                                } catch {
                                    RoutingDebugLog.shared.event(
                                        "poi offline cache unavailable msg=\(error.localizedDescription)"
                                    )
                                }
                            }
                        } catch {
                            guard let cached = await riderServicesStore.cachedElements(in: queryBounds) else {
                                throw error
                            }
                            raw = cached
                            RoutingDebugLog.shared.event(
                                "poi viewport fallback source=verified-device-cache elements=\(cached.count)"
                            )
                        }
                    } else {
                        guard let cached = await riderServicesStore.cachedElements(in: queryBounds) else {
                            throw _POIServiceError.offlineCacheUnavailable
                        }
                        raw = cached
                        RoutingDebugLog.shared.event(
                            "poi viewport loaded source=verified-device-cache elements=\(cached.count)"
                        )
                    }
                    let loaded = raw.compactMap {
                        feature(from: $0, prefs: nil, fuelOnly: false)
                    }
                    riderServiceViewportCache.merge(loaded, coverage: queryBounds)
                    RoutingDebugLog.shared.event(
                        "poi viewport loaded=\(loaded.count) cached=\(riderServiceViewportCache.count) " +
                            "source=dirt-poi bounds=visible+20pct"
                    )
                } catch is CancellationError {
                    // Camera motion cancelled stale work. Keep the current map
                    // paint and let the settled viewport schedule the next load.
                    return
                } catch {
                    requestFailed = true
                    RoutingDebugLog.shared.event(
                        "poi viewport unavailable preserved=\(riderServiceViewportCache.count) " +
                            "source=dirt-poi msg=\(error.localizedDescription)"
                    )
                }
            } else {
                RoutingDebugLog.shared.event(
                    "poi viewport cache hit source=dirt-poi cached=\(riderServiceViewportCache.count)"
                )
            }
            let riderServicePaint = (requestFailed
                ? lastRiderServicePaint
                : riderServiceViewportCache.features(in: queryBounds)).filter {
                prefs.isPOIEnabled(category: $0.category)
            }
            if !requestFailed {
                lastRiderServicePaint = riderServicePaint
            }
            features.append(contentsOf: riderServicePaint)
        }
        var packedAttractionsAvailable = false
        if prefs.anyAttractionEnabled {
            var requestFailed = false
            if !attractionViewportCache.covers(queryBounds) {
                do {
                    let raw: [RiderServiceElement]
                    do {
                        try await attractionsStore.refreshCache(in: queryBounds)
                    } catch {
                        RoutingDebugLog.shared.event(
                            "attractions cache refresh unavailable msg=\(error.localizedDescription)"
                        )
                    }
                    guard let cached = await attractionsStore.cachedElements(in: queryBounds) else {
                        throw _POIServiceError.offlineCacheUnavailable
                    }
                    raw = cached
                    packedAttractionsAvailable = true
                    let loaded = raw.compactMap {
                        feature(from: $0, prefs: nil, fuelOnly: false)
                    }
                    attractionViewportCache.merge(loaded, coverage: queryBounds)
                    RoutingDebugLog.shared.event(
                        "attractions viewport loaded=\(loaded.count) cached=\(attractionViewportCache.count) " +
                            "source=attractions.v1 bounds=visible+20pct"
                    )
                } catch is CancellationError {
                    return
                } catch {
                    requestFailed = true
                    RoutingDebugLog.shared.event(
                        "attractions viewport unavailable preserved=\(attractionViewportCache.count) " +
                            "msg=\(error.localizedDescription)"
                    )
                }
            } else {
                packedAttractionsAvailable = true
                RoutingDebugLog.shared.event(
                    "attractions viewport cache hit cached=\(attractionViewportCache.count)"
                )
            }
            let attractionPaint = (requestFailed
                ? lastAttractionPaint
                : attractionViewportCache.features(in: queryBounds)).filter { feature in
                    guard let kind = MapAttractionKind(rawValue: feature.kind ?? "") else { return false }
                    return prefs.showsAttraction(kind)
                }
            if !requestFailed {
                lastAttractionPaint = attractionPaint
            }
            if requestFailed, !lastAttractionPaint.isEmpty {
                packedAttractionsAvailable = true
            }
            features.append(contentsOf: attractionPaint)
        }
        let stable = POIDeduper.collapseNearby(features).sorted {
            $0.category == $1.category ? $0.id < $1.id : $0.category < $1.category
        }
        mapState.updatePOIFeatures(stable, packedAttractionsAvailable: packedAttractionsAvailable)
    }

    private func fetchRiderServices(bbox: _BBox) async throws -> [RiderServiceElement] {
        let requestID = "poi-\(UUID().uuidString.prefix(8).lowercased())"
        var request = URLRequest(url: AppConfig.livePOIURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: "X-Dirt-Request-ID")
        request.timeoutInterval = 25
        request.httpBody = try JSONEncoder().encode(bbox)
        RoutingDebugLog.shared.event(
            "poi request begin id=\(requestID) categories=campground,lodging,liquor timeoutMs=25000"
        )
        do {
            let started = ContinuousClock.now
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw _POIServiceError.rejected(statusCode: code)
            }
            let decoded = try JSONDecoder().decode(RiderServiceResponse.self, from: data)
            let elapsed = ContinuousClock.now - started
            let source = http.value(forHTTPHeaderField: "X-Dirt-POI-Source") ?? "unknown"
            RoutingDebugLog.shared.event(
                "poi request response id=\(requestID) http=\(http.statusCode) " +
                    "elements=\(decoded.elements.count) upstream=\(source) elapsed=\(elapsed)"
            )
            return decoded.elements
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private func feature(from el: RiderServiceElement, prefs: LayerPrefsSnapshot?, fuelOnly: Bool) -> POIFeature? {
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
            website: tags["website"] ?? tags["contact:website"],
            kind: MapAttraction.kind(from: tags)
        )
    }

    private func category(for tags: [String: String]) -> String? {
        if tags["dirt:category"] == "attraction",
           MapAttraction.kind(from: tags) != nil {
            return "attraction"
        }
        if let packed = tags["dirt:category"],
           ["campground", "lodging", "liquor"].contains(packed) {
            return packed
        }
        if tags["amenity"] == "fuel" { return "fuel" }
        if ["alcohol", "wine"].contains(tags["shop"]) { return "liquor" }
        switch tags["tourism"] {
        case "hotel", "motel", "hostel", "guest_house", "chalet", "bed_and_breakfast", "apartment":
            return "lodging"
        case "camp_site", "caravan_site": return "campground"
        default: return nil
        }
    }
}

nonisolated private enum _POIServiceError: LocalizedError {
    case rejected(statusCode: Int)
    case offlineCacheUnavailable

    var errorDescription: String? {
        switch self {
        case let .rejected(statusCode):
            "DIRT rider-service request failed (HTTP \(statusCode))."
        case .offlineCacheUnavailable:
            "Rider Services have not been saved for this area yet."
        }
    }
}

nonisolated private struct _BBox: Codable, Sendable {
    let minLon, minLat, maxLon, maxLat: Double
}

nonisolated struct RiderServiceResponse: Decodable, Sendable {
    let elements: [RiderServiceElement]
}

nonisolated struct RiderServiceElement: Decodable, Sendable {
    let id: Int
    let type: String?
    let lat: Double?
    let lon: Double?
    let center: RiderServiceCenter?
    let tags: [String: String]?
}

nonisolated struct RiderServiceCenter: Decodable, Sendable {
    let lat: Double
    let lon: Double
}
