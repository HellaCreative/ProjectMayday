import CoreLocation
import Foundation
import Observation

struct RoutingGraphDebugHit: Equatable {
    let edgeId: String
    let accessClass: String
    let roadClass: String
    let source: String
}

/// DEBUG: paints installed BC `graph.v2` edges by access class (the real router fabric).
@MainActor
final class RoutingGraphDebugManager {
    private let mapState: MapState
    private let graphPacks: GraphPackStore
    private var debounceTask: Task<Void, Never>?

    init(mapState: MapState, graphPacks: GraphPackStore) {
        self.mapState = mapState
        self.graphPacks = graphPacks
        armObservation()
    }

    private func armObservation() {
        withObservationTracking {
            _ = mapState.showRoutingGraphDebug
            _ = mapState.mapCenter.latitude
            _ = mapState.mapCenter.longitude
            _ = mapState.mapZoom
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
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        guard BuildChannel.debugRoutingGraphOverlay, mapState.showRoutingGraphDebug else {
            mapState.updateDebugGraphFeatures([], status: nil, capped: false)
            return
        }

        let center = mapState.mapCenter
        let region = GraphPackStore.primaryRegionId(containing: center)
        guard region == "bc" else {
            mapState.updateDebugGraphFeatures(
                [],
                status: "Routing graph debug is BC-only. Pan to BC.",
                capped: false
            )
            return
        }
        guard let pack = graphPacks.packIfInstalled("BC") else {
            mapState.updateDebugGraphFeatures(
                [],
                status: "Download BC from PACKS (Remove first if you still have the old file).",
                capped: false
            )
            return
        }

        // Viewport-bounded. Cap 6k edges so MapLibre stays usable — not a full-province dump.
        let pad = max(0.035, 1.2 / pow(2, max(mapState.mapZoom - 8, 1)))
        let minLon = center.longitude - pad
        let maxLon = center.longitude + pad
        let minLat = center.latitude - pad * 0.7
        let maxLat = center.latitude + pad * 0.7
        let cap = 6000

        let pool = await Task.detached(priority: .userInitiated) {
            PackNetworkOverlay.features(
                from: pack,
                minLon: minLon,
                minLat: minLat,
                maxLon: maxLon,
                maxLat: maxLat,
                province: "BC",
                cap: cap
            )
        }.value

        let capped = pool.count >= cap
        let status = capped
            ? "DEBUG graph · \(pool.count) edges in view (capped at \(cap) — zoom in)"
            : "DEBUG graph · \(pool.count) edges in view · access colors · no Allow filter"
        mapState.updateDebugGraphFeatures(pool, status: status, capped: capped)
    }

    static func sourceLabel(edgeId: String) -> String {
        if edgeId.hasPrefix("bc-dra") { return "DRA" }
        if edgeId.hasPrefix("bc-ften") { return "FTEN" }
        if edgeId.hasPrefix("pack-stitch-") { return "OSM stitch" }
        if edgeId.hasPrefix("osm-") { return "OSM" }
        return "pack"
    }
}
