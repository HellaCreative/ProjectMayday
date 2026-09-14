import CoreLocation
import Foundation

/// The existing native urban/settlement/corridor predicate. Source adapters
/// supply exact bounds and bounded full geometry; unavailable data must throw,
/// never become an empty shape. Explicit nil retains legacy missing-geometry
/// behavior only. No source graph/closures are retained after this call.
nonisolated enum NativeRoadBlockPolicy {
    static func blocked(_ point: CLLocationCoordinate2D,
        edgeFrom: CLLocationCoordinate2D? = nil, edgeIndex: Int? = nil,
        edgeShape: [CLLocationCoordinate2D]? = nil,
        from: CLLocationCoordinate2D,to: CLLocationCoordinate2D,ctx: HopSearchContext,
        sourceIdentity: AnyObject,hasGeometry: Bool,
        urbanCores: () -> [UrbanCore.Box],settlements: () -> [UrbanCore.Box],
        boundsMayIntersect: ((Int,UrbanCore.Box) throws -> Bool)?,
        geometryForEdge: (Int) throws -> [CLLocationCoordinate2D]?) throws -> Bool {
        if ctx.cityWall, !urbanCores().isEmpty {
            let memo = ctx.urbanEdgeMemo.flatMap {
                $0.matches(owner: sourceIdentity,from: from,to: to) ? $0 : nil
            }
            let boxes = memo?.boxes ?? urbanCores().filter { !$0.contains(from) && !$0.contains(to) }
            if !boxes.isEmpty {
                var fullGeometryProof = true
                func urbanBlocked() throws -> Bool {
                var couldCross = true
                if let edgeIndex, let boundsMayIntersect {
                    couldCross = try boxes.contains { try boundsMayIntersect(edgeIndex,$0) }
                }
                if couldCross {
                    let geometry: [CLLocationCoordinate2D]
                    if let edgeShape { geometry = edgeShape }
                    else if let edgeIndex, let stored = try geometryForEdge(edgeIndex) { geometry = stored }
                    else { fullGeometryProof = false; geometry = edgeFrom.map { [$0, point] } ?? [point] }
                    if geometry.count == 1, UrbanCore.blocks(point: geometry[0], start: from, end: to, boxes: boxes) { return true }
                    for i in geometry.indices.dropFirst() {
                        if UrbanCore.blocks(segmentFrom: geometry[i - 1], segmentTo: geometry[i],
                            start: from, end: to, boxes: boxes) { return true }
                    }
                }
                return false
                }
                // Only native full-edge reads participate. Virtual/partial
                // shapes and missing geometry retain their original checks.
                let blocked: Bool
                if let memo,let edgeIndex,edgeShape == nil,hasGeometry {
                    blocked = try memo.value(edge: edgeIndex,shouldStore: { fullGeometryProof },compute: urbanBlocked)
                } else { blocked = try urbanBlocked() }
                if blocked { return true }
            }
        }
        if ctx.settlementWall,
           UrbanCore.blocks(point: point, start: from, end: to, boxes: settlements()) {
            return true
        }
        if ctx.hardCorridor, let corridor = ctx.corridorMeters,
           abs(GeoMath.crossTrackMeters(point: point, lineFrom: from, to: to)) > corridor {
            return true
        }
        return false
    }
}
