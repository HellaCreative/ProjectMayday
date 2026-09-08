import CoreLocation
import Foundation

/// Geographic loop / out-and-back pruning — Swift port of `pack-fabric/routing/lib` path pruning.
///
/// A shortest path is node-simple, but dual fabrics can paint the same road with
/// different node ids. Proximity cells (~20 m) catch near-miss revisits that
/// exact coordinate keys miss.
/// Opted out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (used from on-device search).
nonisolated enum OnDevicePathPruning {

    struct EdgePiece: Sendable {
        var edgeId: String
        var coords: [CLLocationCoordinate2D]
        var meters: Double
        var surfaceName: String
    }

    struct Options: Sendable {
        /// Proximity grid size in meters (default 20).
        var cellMeters: Double = 20
        /// Max haversine between candidate revisits (default max(cell, 25)).
        var matchMeters: Double? = nil
        /// Ignore tiny revisits (default 50).
        var minLoopMeters: Double = 50
        /// Legacy precision-N exact coordinate keys.
        var exactOnly: Bool = false
        var precision: Int = 6
    }

    struct Result: Sendable {
        var edges: [EdgePiece]
        var prunedLoopCount: Int
        var prunedMeters: Double
    }

    /// Loop-erases a path at repeated geographic vertices (proximity cells by default).
    static func pruneGeographicLoops(
        _ edges: [EdgePiece],
        options: Options = Options()
    ) -> Result {
        let minLoopMeters = options.minLoopMeters >= 0 ? options.minLoopMeters : 50
        let keying = makeKeyFn(options)
        let beforeMeters = totalMeters(edges)
        var result = edges
        var prunedLoopCount = 0

        // Each pass removes at least one coordinate interval. Guard against
        // malformed self-overlapping polylines consuming unbounded CPU.
        for _ in 0..<100 {
            guard let loop = findLargestLoop(result, keying: keying, minLoopMeters: minLoopMeters) else {
                break
            }
            result = eraseLoop(result, loop: loop)
            prunedLoopCount += 1
        }

        return Result(
            edges: result,
            prunedLoopCount: prunedLoopCount,
            prunedMeters: max(0, beforeMeters - totalMeters(result))
        )
    }

    // MARK: - Internals

    private struct ProximityCell {
        var key: String
        var x: Int
        var y: Int
    }

    private struct Keying {
        var primary: (CLLocationCoordinate2D) -> String
        var candidates: (CLLocationCoordinate2D) -> [String]
        var matchMeters: Double
    }

    private struct Visit {
        var edgeIndex: Int
        var coordIndex: Int
        var coord: CLLocationCoordinate2D
        var alongMeters: Double
    }

    private struct Loop {
        var first: Visit
        var second: Visit
        var loopMeters: Double
    }

    private static func haversineMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func lineMeters(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<coords.count {
            total += haversineMeters(coords[i - 1], coords[i])
        }
        return total
    }

    private static func totalMeters(_ edges: [EdgePiece]) -> Double {
        edges.reduce(0) { $0 + $1.meters }
    }

    private static func coordKey(_ coord: CLLocationCoordinate2D, precision: Int) -> String {
        let fmt = "%.\(precision)f"
        let lon = String(format: fmt, coord.longitude)
        let lat = String(format: fmt, coord.latitude)
        return "\(lon),\(lat)"
    }

    /// Quantize lon/lat into ~cellMeters grid cells.
    private static func proximityKey(_ coord: CLLocationCoordinate2D, cellMeters: Double) -> ProximityCell {
        let latRad = coord.latitude * .pi / 180
        let metersPerLon = max(1e-6, 111_320 * cos(latRad))
        let x = Int((coord.longitude * metersPerLon / cellMeters).rounded())
        let y = Int((coord.latitude * 110_540 / cellMeters).rounded())
        return ProximityCell(key: "\(x):\(y)", x: x, y: y)
    }

    private static func neighborKeys(x: Int, y: Int) -> [String] {
        var keys: [String] = []
        keys.reserveCapacity(9)
        for dx in -1...1 {
            for dy in -1...1 {
                keys.append("\(x + dx):\(y + dy)")
            }
        }
        return keys
    }

    private static func makeKeyFn(_ options: Options) -> Keying {
        let cellMeters = options.cellMeters > 0 ? options.cellMeters : 20
        let matchMeters: Double
        if let m = options.matchMeters, m > 0 {
            matchMeters = m
        } else {
            matchMeters = max(cellMeters, 25)
        }

        if options.exactOnly {
            let precision = options.precision
            return Keying(
                primary: { coordKey($0, precision: precision) },
                candidates: { [coordKey($0, precision: precision)] },
                matchMeters: 0
            )
        }

        return Keying(
            primary: { proximityKey($0, cellMeters: cellMeters).key },
            candidates: { coord in
                let cell = proximityKey(coord, cellMeters: cellMeters)
                return neighborKeys(x: cell.x, y: cell.y)
            },
            matchMeters: matchMeters
        )
    }

    private static func clonePiece(_ edge: EdgePiece, coords: [CLLocationCoordinate2D]) -> EdgePiece? {
        guard coords.count >= 2 else { return nil }
        let originalGeomMeters = lineMeters(edge.coords)
        let pieceGeomMeters = lineMeters(coords)
        guard pieceGeomMeters > 0 else { return nil }
        let originalMeters = edge.meters > 0 ? edge.meters : originalGeomMeters
        let meters: Double
        if originalGeomMeters > 0 {
            meters = originalMeters * (pieceGeomMeters / originalGeomMeters)
        } else {
            meters = pieceGeomMeters
        }
        return EdgePiece(
            edgeId: edge.edgeId,
            coords: coords,
            meters: meters,
            surfaceName: edge.surfaceName
        )
    }

    private static func findLargestLoop(
        _ edges: [EdgePiece],
        keying: Keying,
        minLoopMeters: Double
    ) -> Loop? {
        var seen: [String: Visit] = [:]
        var previousKey: String?
        var alongMeters = 0.0
        var previousCoord: CLLocationCoordinate2D?
        var largest: Loop?

        for edgeIndex in 0..<edges.count {
            let coords = edges[edgeIndex].coords
            for coordIndex in 0..<coords.count {
                let coord = coords[coordIndex]
                let key = keying.primary(coord)
                // Adjacent segment boundaries repeat by construction; not loops.
                if key == previousKey { continue }
                if let prev = previousCoord {
                    alongMeters += haversineMeters(prev, coord)
                }

                for candidateKey in keying.candidates(coord) {
                    guard let first = seen[candidateKey] else { continue }
                    if keying.matchMeters > 0,
                       haversineMeters(first.coord, coord) > keying.matchMeters {
                        continue
                    }
                    if alongMeters - first.alongMeters >= minLoopMeters {
                        let candidate = Loop(
                            first: first,
                            second: Visit(
                                edgeIndex: edgeIndex,
                                coordIndex: coordIndex,
                                coord: coord,
                                alongMeters: alongMeters
                            ),
                            loopMeters: alongMeters - first.alongMeters
                        )
                        if largest == nil || candidate.loopMeters > largest!.loopMeters {
                            largest = candidate
                        }
                    }
                }

                if seen[key] == nil {
                    seen[key] = Visit(
                        edgeIndex: edgeIndex,
                        coordIndex: coordIndex,
                        coord: coord,
                        alongMeters: alongMeters
                    )
                }
                previousKey = key
                previousCoord = coord
            }
        }
        return largest
    }

    private static func eraseLoop(_ edges: [EdgePiece], loop: Loop) -> [EdgePiece] {
        let first = loop.first
        let second = loop.second
        var out = Array(edges.prefix(first.edgeIndex))
        let firstEdge = edges[first.edgeIndex]
        let secondEdge = edges[second.edgeIndex]
        let firstCoords = firstEdge.coords
        let secondCoords = secondEdge.coords

        if first.edgeIndex == second.edgeIndex {
            var joined = Array(firstCoords.prefix(first.coordIndex + 1))
            joined.append(contentsOf: firstCoords.suffix(from: second.coordIndex + 1))
            if let piece = clonePiece(firstEdge, coords: joined) {
                out.append(piece)
            }
            out.append(contentsOf: edges.suffix(from: second.edgeIndex + 1))
            return out
        }

        let prefixCoords = Array(firstCoords.prefix(first.coordIndex + 1))
        if let prefix = clonePiece(firstEdge, coords: prefixCoords) {
            out.append(prefix)
        }

        let suffixCoords = Array(secondCoords.suffix(from: second.coordIndex))
        let suffix = clonePiece(secondEdge, coords: suffixCoords)
        let rest = Array(edges.suffix(from: second.edgeIndex + 1))

        // Near-miss joins can leave a single-vertex suffix. Drop it and stitch
        // the next edge onto the loop start so we do not open a geometry gap.
        if suffix == nil, let next = rest.first {
            var nextCoords = next.coords
            if nextCoords.count >= 2 {
                nextCoords[0] = first.coord
                if let stitched = clonePiece(next, coords: nextCoords) {
                    out.append(stitched)
                    out.append(contentsOf: rest.dropFirst())
                    return out
                }
            }
        }

        if var s = suffix {
            var joinedCoords = s.coords
            if !joinedCoords.isEmpty {
                joinedCoords[0] = first.coord
            }
            s.coords = joinedCoords
            out.append(s)
        }
        out.append(contentsOf: rest)
        return out
    }

}
