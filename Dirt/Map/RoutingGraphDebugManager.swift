import CoreLocation
import Foundation
import Observation

struct RoutingGraphDebugHit: Equatable {
    let edgeId: String
    let surfaceClass: String
    let accessClass: String
    let roadClass: String
    let source: String
    let surfaceLeaf: String
    let surfaceFamily: String
    let roadClassLeaf: String
    let roadTier: String
    let accessLeaf: String
    let atvDesignated: Bool
}

private struct LiveDebugGraphRequest: Encodable {
    struct Location: Encodable {
        let lat: Double
        let lon: Double
        let label: String
    }

    struct BBox: Encodable {
        let minLon: Double
        let minLat: Double
        let maxLon: Double
        let maxLat: Double
    }

    let action = "debug_graph"
    let profile = "dirt"
    let locations: [Location]
    let bbox: BBox
    let cap: Int
}

private struct LiveDebugGraphResponse: Decodable {
    struct Feature: Decodable {
        let edgeId: String
        let coordinates: [[Double]]
        let surfaceClass: String
        let accessClass: String
        let structureType: String
        let roadClass: String
    }

    let status: String
    let message: String?
    let source: String?
    let features: [Feature]
    let capped: Bool
    let matchingCount: Int?
}

/// DEBUG: paints viewport edges from the installed pack (v3 leaves when present).
/// Live API is a fallback only when no pack is installed — it has no leaf fields.
@MainActor
final class RoutingGraphDebugManager {
    private let mapState: MapState
    private let graphPacks: GraphPackStore
    private let network: NetworkPathMonitor
    private var debounceTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(mapState: MapState, graphPacks: GraphPackStore, network: NetworkPathMonitor) {
        self.mapState = mapState
        self.graphPacks = graphPacks
        self.network = network
        armObservation()
    }

    private func armObservation() {
        withObservationTracking {
            _ = mapState.showRoutingGraphDebug
            _ = mapState.debugGraphPaintMode
            _ = mapState.mapCenter.latitude
            _ = mapState.mapCenter.longitude
            _ = mapState.mapZoom
            _ = network.isOnline
            _ = graphPacks.loadedRegionIds
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
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.startRefresh()
        }
    }

    /// Keep viewport debounce separate from the request itself. Panning now cancels
    /// only the pending timer; once the rider pauses, one refresh replaces any older
    /// in-flight request instead of producing a cancellation for every map tick.
    private func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        guard mapState.showRoutingGraphDebug else {
            mapState.updateDebugGraphFeatures([], status: nil, capped: false)
            return
        }

        let center = mapState.mapCenter
        guard let region = GraphPackStore.primaryRegionId(containing: center) else {
            mapState.updateDebugGraphFeatures(
                [],
                status: "No live routing region at this map location.",
                capped: false
            )
            return
        }

        // Viewport-bounded so this temporary diagnostic never downloads a pack.
        let pad = max(0.035, 1.2 / pow(2, max(mapState.mapZoom - 8, 1)))
        let minLon = center.longitude - pad
        let maxLon = center.longitude + pad
        let minLat = center.latitude - pad * 0.7
        let maxLat = center.latitude + pad * 0.7
        let cap = 4000

        // Phase E3: prefer installed pack so surface/road-class leaves paint.
        if let pack = graphPacks.packIfInstalled(region.uppercased()) {
            let pool = await Task.detached(priority: .userInitiated) {
                PackNetworkOverlay.features(
                    from: pack,
                    minLon: minLon,
                    minLat: minLat,
                    maxLon: maxLon,
                    maxLat: maxLat,
                    province: region.uppercased(),
                    cap: cap
                )
            }.value
            guard mapState.showRoutingGraphDebug else { return }
            let capped = pool.count >= cap
            let fmt = "v4"
            let mode = mapState.debugGraphPaintMode.title
            let status = capped
                ? "PACK \(fmt) · \(mode) · \(pool.count) edges (capped — zoom in)"
                : "PACK \(fmt) · \(mode) · \(pool.count) edges"
            mapState.updateDebugGraphFeatures(pool, status: status, capped: capped)
            return
        }

        if network.isOnline {
            if mapState.debugGraphPaintMode != .access {
                mapState.debugGraphPaintMode = .access
            }
            mapState.updateDebugGraphFeatures(
                [],
                status: "No pack installed — loading LIVE graph (no v3 leaves)…",
                capped: false
            )
            do {
                let response = try await liveFeatures(
                    minLon: minLon,
                    minLat: minLat,
                    maxLon: maxLon,
                    maxLat: maxLat,
                    cap: cap,
                    region: region.uppercased()
                )
                guard mapState.showRoutingGraphDebug else { return }
                let count = response.features.count
                let status = response.capped
                    ? "LIVE graph · \(count) edges (capped — zoom in)"
                    : "LIVE graph · \(count) edges · coarse only"
                mapState.updateDebugGraphFeatures(
                    response.features,
                    status: status,
                    capped: response.capped
                )
                return
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                RoutingDebugLog.shared.event(
                    "debug graph live failed region=\(region): \(error.localizedDescription)"
                )
            }
        }

        mapState.updateDebugGraphFeatures(
            [],
            status: "Install the \(region.uppercased()) pack from Layers to paint graph leaves.",
            capped: false
        )
    }

    private func liveFeatures(
        minLon: Double,
        minLat: Double,
        maxLon: Double,
        maxLat: Double,
        cap: Int,
        region: String
    ) async throws -> (features: [NetworkLineFeature], capped: Bool) {
        let requestBody = LiveDebugGraphRequest(
            locations: [
                .init(lat: minLat, lon: minLon, label: "viewport-sw"),
                .init(lat: maxLat, lon: maxLon, label: "viewport-ne")
            ],
            bbox: .init(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat),
            cap: cap
        )
        var request = URLRequest(url: AppConfig.routeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(requestBody)
        let (data, rawResponse) = try await URLSession.shared.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(response.statusCode) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<non-text response>"
            throw NSError(
                domain: "Dirt.LiveDebugGraph",
                code: response.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "HTTP \(response.statusCode): \(snippet.replacingOccurrences(of: "\n", with: " "))"
                ]
            )
        }
        let decoded = try JSONDecoder().decode(LiveDebugGraphResponse.self, from: data)
        guard decoded.status == "complete" else {
            throw NSError(
                domain: "Dirt.LiveDebugGraph",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: decoded.message ?? "Live graph request failed"]
            )
        }
        let features = decoded.features.compactMap { feature -> NetworkLineFeature? in
            let coordinates = feature.coordinates.compactMap { pair -> NetworkLineFeature.Point? in
                guard pair.count >= 2 else { return nil }
                return NetworkLineFeature.Point(lat: pair[1], lon: pair[0])
            }
            guard coordinates.count >= 2 else { return nil }
            return NetworkLineFeature(
                edgeId: feature.edgeId,
                coordinates: coordinates,
                surfaceClass: feature.surfaceClass,
                accessClass: feature.accessClass,
                structureType: feature.structureType,
                province: region,
                roadClass: feature.roadClass,
                surfaceLeaf: "",
                surfaceFamily: "unknown",
                roadClassLeaf: "",
                roadTier: "unknown",
                accessLeaf: "",
                atvDesignated: false
            )
        }
        return (features, decoded.capped)
    }

    static func sourceLabel(edgeId: String) -> String {
        if edgeId.hasPrefix("bc-dra") { return "DRA" }
        if edgeId.hasPrefix("bc-ften") { return "FTEN" }
        if edgeId.hasPrefix("pack-stitch-") { return "OSM stitch" }
        if edgeId.hasPrefix("osm-") { return "OSM" }
        return "pack"
    }
}
