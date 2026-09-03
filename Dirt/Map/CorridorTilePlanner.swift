import Foundation

/// Corridor tile keys for nav prefetch.
enum CorridorTilePlanner {
    nonisolated struct Tile: Hashable, Sendable {
        let z: Int
        let x: Int
        let y: Int

        var key: String { "\(z)/\(x)/\(y)" }

    }

    nonisolated struct Plan: Sendable {
        let tiles: [Tile]
        /// Tiles intersected by the route itself. Halo tiles are useful buffer,
        /// but a failed halo request must not be confused with a hole in the ride.
        let requiredTiles: Set<Tile>
        let fitZoom: Int
        let maxZoom: Int
        let truncated: Bool
    }

    nonisolated private static let maxNativeZoom = 14
    nonisolated private static let maxTiles = 1200

    nonisolated static func collectRouteTiles(
        coordinates: [RouteCoordinate],
        viewportWidth: Double = 390,
        viewportHeight: Double = 844
    ) -> Plan {
        guard coordinates.count >= 2 else {
            return Plan(
                tiles: [],
                requiredTiles: [],
                fitZoom: maxNativeZoom,
                maxZoom: maxNativeZoom,
                truncated: false
            )
        }

        let bounds = routeBounds(coordinates, paddingRatio: 0.05)
        let fitZoom = fitZoomForBounds(bounds, width: viewportWidth, height: viewportHeight, maxZoom: maxNativeZoom)
        var levels: [(z: Int, core: [Tile], extras: [Tile])] = []
        for z in fitZoom...maxNativeZoom {
            levels.append(levelCandidates(coordinates, bounds: bounds, z: z))
        }
        let totalCandidates = levels.reduce(0) { $0 + $1.core.count + $1.extras.count }

        let selectedTiles: [Tile]
        let requiredTiles: Set<Tile>
        if totalCandidates <= maxTiles {
            selectedTiles = levels.flatMap { $0.core + $0.extras }
            requiredTiles = Set(levels.flatMap(\.core))
        } else {
            let weights = levels.indices.map { i in max(1.0, pow(Double(i + 1), 1.35)) }
            let weightTotal = weights.reduce(0, +)
            var budgets = weights.map { max(2, Int(floor(Double(maxTiles) * $0 / weightTotal))) }
            while budgets.reduce(0, +) > maxTiles {
                if let index = budgets.firstIndex(where: { $0 > 2 }) {
                    budgets[index] -= 1
                } else {
                    break
                }
            }
            while budgets.reduce(0, +) < maxTiles {
                budgets[budgets.count - 1] += 1
            }
            var selected: [Tile] = []
            var required = Set<Tile>()
            for (index, level) in levels.enumerated() {
                let budget = budgets[index]
                let core = evenlySelect(level.core, limit: min(level.core.count, budget))
                let remaining = budget - core.count
                selected.append(contentsOf: core)
                selected.append(contentsOf: evenlySelect(level.extras, limit: max(0, remaining)))
                required.formUnion(core)
            }
            selectedTiles = selected
            requiredTiles = required
        }

        return Plan(
            tiles: selectedTiles,
            requiredTiles: requiredTiles,
            fitZoom: fitZoom,
            maxZoom: maxNativeZoom,
            truncated: totalCandidates > maxTiles
        )
    }

    // MARK: - Geometry helpers

    nonisolated private static func clamp(_ value: Double, _ minV: Double, _ maxV: Double) -> Double {
        min(maxV, max(minV, value))
    }

    nonisolated private static func mercatorX(_ lon: Double) -> Double { (lon + 180) / 360 }

    nonisolated private static func mercatorY(_ lat: Double) -> Double {
        let safe = clamp(lat, -85.05112878, 85.05112878)
        let rad = safe * .pi / 180
        return (1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2
    }

    nonisolated private static func coordToTile(_ lon: Double, _ lat: Double, z: Int) -> (x: Int, y: Int) {
        let scale = pow(2.0, Double(z))
        let x = Int(clamp(floor(mercatorX(lon) * scale), 0, scale - 1))
        let y = Int(clamp(floor(mercatorY(lat) * scale), 0, scale - 1))
        return (x, y)
    }

    nonisolated private static func routeBounds(_ coords: [RouteCoordinate], paddingRatio: Double) -> (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        var minLon = Double.infinity, minLat = Double.infinity
        var maxLon = -Double.infinity, maxLat = -Double.infinity
        for c in coords {
            minLon = min(minLon, c.longitude)
            minLat = min(minLat, c.latitude)
            maxLon = max(maxLon, c.longitude)
            maxLat = max(maxLat, c.latitude)
        }
        let lonPad = max(0.002, (maxLon - minLon) * paddingRatio)
        let latPad = max(0.002, (maxLat - minLat) * paddingRatio)
        return (
            clamp(minLon - lonPad, -180, 180),
            clamp(minLat - latPad, -85.05112878, 85.05112878),
            clamp(maxLon + lonPad, -180, 180),
            clamp(maxLat + latPad, -85.05112878, 85.05112878)
        )
    }

    nonisolated private static func fitZoomForBounds(
        _ bounds: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double),
        width: Double,
        height: Double,
        maxZoom: Int
    ) -> Int {
        let usableWidth = max(80, width - 80)
        let usableHeight = max(80, height - 250)
        let xSpan = max(1e-9, abs(mercatorX(bounds.maxLon) - mercatorX(bounds.minLon)))
        let ySpan = max(1e-9, abs(mercatorY(bounds.maxLat) - mercatorY(bounds.minLat)))
        let scale = min(usableWidth / (512 * xSpan), usableHeight / (512 * ySpan))
        let z = Int(floor(log2(max(1, scale))))
        return min(maxZoom, max(0, z))
    }

    nonisolated private static func traceRouteTiles(_ coords: [RouteCoordinate], z: Int) -> Set<Tile> {
        var tiles = Set<Tile>()
        let scale = pow(2.0, Double(z))
        guard coords.count >= 2 else {
            if let only = coords.first {
                let t = coordToTile(only.longitude, only.latitude, z: z)
                tiles.insert(Tile(z: z, x: t.x, y: t.y))
            }
            return tiles
        }
        for i in 1..<coords.count {
            let aLon = mercatorX(coords[i - 1].longitude) * scale
            let aLat = mercatorY(coords[i - 1].latitude) * scale
            let bLon = mercatorX(coords[i].longitude) * scale
            let bLat = mercatorY(coords[i].latitude) * scale
            let steps = max(1, Int(ceil(max(abs(bLon - aLon), abs(bLat - aLat)) * 2)))
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let x = Int(clamp(floor(aLon + (bLon - aLon) * t), 0, scale - 1))
                let y = Int(clamp(floor(aLat + (bLat - aLat) * t), 0, scale - 1))
                tiles.insert(Tile(z: z, x: x, y: y))
            }
        }
        return tiles
    }

    nonisolated private static func levelCandidates(
        _ coords: [RouteCoordinate],
        bounds: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double),
        z: Int
    ) -> (z: Int, core: [Tile], extras: [Tile]) {
        let maxIndex = Int(pow(2.0, Double(z))) - 1
        let coreSet = traceRouteTiles(coords, z: z)
        var all = coreSet
        let padding = z >= 12 ? 1 : 0

        if z <= 11 {
            let nw = coordToTile(bounds.minLon, bounds.maxLat, z: z)
            let se = coordToTile(bounds.maxLon, bounds.minLat, z: z)
            let area = (se.x - nw.x + 3) * (se.y - nw.y + 3)
            if area <= 180 {
                for x in max(0, nw.x - 1)...min(maxIndex, se.x + 1) {
                    for y in max(0, nw.y - 1)...min(maxIndex, se.y + 1) {
                        all.insert(Tile(z: z, x: x, y: y))
                    }
                }
            }
        } else if padding > 0 {
            for tile in coreSet {
                for dx in -padding...padding {
                    for dy in -padding...padding {
                        let x = tile.x + dx
                        let y = tile.y + dy
                        if x >= 0, y >= 0, x <= maxIndex, y <= maxIndex {
                            all.insert(Tile(z: z, x: x, y: y))
                        }
                    }
                }
            }
        }

        let order: (Tile, Tile) -> Bool = { lhs, rhs in
            if lhs.z != rhs.z { return lhs.z < rhs.z }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        }
        let core = coreSet.sorted(by: order)
        let extras = all.subtracting(coreSet).sorted(by: order)
        return (z, core, extras)
    }

    nonisolated private static func evenlySelect<T>(_ values: [T], limit: Int) -> [T] {
        guard limit > 0, !values.isEmpty else { return [] }
        if values.count <= limit { return values }
        if limit == 1 { return [values[0]] }
        var selected: [T] = []
        var lastIndex = -1
        for i in 0..<limit {
            let index = Int(round(Double(i) * Double(values.count - 1) / Double(limit - 1)))
            if index != lastIndex {
                selected.append(values[index])
                lastIndex = index
            }
        }
        return selected
    }
}

/// Exact in-memory reuse for a route's last tile plan. This avoids rebuilding
/// every zoom-level corridor on repeated Start taps while never trusting a hash
/// collision or an endpoint-only route identity.
struct CorridorTilePlanCache {
    private struct CoordinateKey: Equatable {
        let latitudeBits: UInt64
        let longitudeBits: UInt64

        nonisolated init(_ coordinate: RouteCoordinate) {
            latitudeBits = coordinate.latitude.bitPattern
            longitudeBits = coordinate.longitude.bitPattern
        }
    }

    private struct Entry {
        let coordinateKeys: [CoordinateKey]
        let viewportWidthBits: UInt64
        let viewportHeightBits: UInt64
        let plan: CorridorTilePlanner.Plan
    }

    private var entries: [Entry] = []
    private let capacity = 12

    mutating func plan(
        for coordinates: [RouteCoordinate],
        viewportWidth: Double,
        viewportHeight: Double
    ) -> CorridorTilePlanner.Plan? {
        let keys = coordinates.map(CoordinateKey.init)
        guard let index = entries.firstIndex(where: {
            $0.coordinateKeys == keys
                && $0.viewportWidthBits == viewportWidth.bitPattern
                && $0.viewportHeightBits == viewportHeight.bitPattern
        }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.plan
    }

    mutating func store(
        _ plan: CorridorTilePlanner.Plan,
        for coordinates: [RouteCoordinate],
        viewportWidth: Double,
        viewportHeight: Double
    ) {
        let keys = coordinates.map(CoordinateKey.init)
        entries.removeAll {
            $0.coordinateKeys == keys
                && $0.viewportWidthBits == viewportWidth.bitPattern
                && $0.viewportHeightBits == viewportHeight.bitPattern
        }
        entries.append(
            Entry(
                coordinateKeys: keys,
                viewportWidthBits: viewportWidth.bitPattern,
                viewportHeightBits: viewportHeight.bitPattern,
                plan: plan
            )
        )
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}

/// Chooses the smallest honest Start Navigation gate from already-routed
/// rider/fuel stages. CorridorTilePlanner adds the practical one-tile halo.
enum NavigationTileScope {
    nonisolated static func blockingCoordinates(
        stageCoordinates: [[RouteCoordinate]],
        fallback: [RouteCoordinate]
    ) -> [RouteCoordinate] {
        stageCoordinates.first(where: { $0.count >= 2 }) ?? fallback
    }

    nonisolated static func lookaheadCoordinates(
        after currentStageIndex: Int,
        stageCoordinates: [[RouteCoordinate]]
    ) -> (index: Int, coordinates: [RouteCoordinate])? {
        let nextIndex = currentStageIndex + 1
        guard stageCoordinates.indices.contains(nextIndex),
              stageCoordinates[nextIndex].count >= 2
        else { return nil }
        return (nextIndex, stageCoordinates[nextIndex])
    }
}

/// Start Navigation needs one routing region, not the complete itinerary's
/// province/state chain. The current region follows the rider later from live
/// location updates, so a cross-country route never turns Start into a bulk
/// pack scan or download.
enum NavigationRoutingPackScope {
    nonisolated static func startingCoordinate(
        stageCoordinates: [[RouteCoordinate]],
        fallback: [RouteCoordinate]
    ) -> RouteCoordinate? {
        NavigationTileScope.blockingCoordinates(
            stageCoordinates: stageCoordinates,
            fallback: fallback
        ).first ?? fallback.first
    }

    nonisolated static func regionTransition(
        currentRegionID: String?,
        lastPreparedRegionID: String?
    ) -> String? {
        guard let currentRegionID,
              currentRegionID != lastPreparedRegionID
        else { return nil }
        return currentRegionID
    }
}
