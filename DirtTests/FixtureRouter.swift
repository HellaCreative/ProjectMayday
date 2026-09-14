import Foundation
import CoreLocation
@testable import Dirt

/// Builds the exact candidate index for small in-memory topology fixtures.
/// Full app/pack replay uses GraphPackStore's verified source-file preparation.
func fixtureRouter(pack: GraphV2Pack) throws -> OnDeviceRouter {
    if pack.version >= 4, pack.exactSnapIndex == nil {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirtRoutingFixtureIndexes/" + UUID().uuidString)
        let url = directory.appendingPathComponent("snap.bin")
        let identity = ExactSnapIndex.Identity(graphSHA256: "in-memory-fixture",
            graphBytes: 0, geometrySHA256: "fixture-geometry", geometryBytes: 0)
        try ExactSnapIndexBuilder.build(to: url, identity: identity,
            edgeCount: pack.undirectedEdgeCount) { edge in
            guard let from = pack.edgeFrom, let to = pack.edgeTo else { return nil }
            let a = Int(from[edge]), b = Int(to[edge])
            guard a >= 0, b >= 0, a < pack.nodeCount, b < pack.nodeCount else { return nil }
            let aLon = Double(pack.nodeCoords[a*2]), aLat = Double(pack.nodeCoords[a*2+1])
            let bLon = Double(pack.nodeCoords[b*2]), bLat = Double(pack.nodeCoords[b*2+1])
            var minLon = min(aLon,bLon), maxLon = max(aLon,bLon)
            var minLat = min(aLat,bLat), maxLat = max(aLat,bLat)
            for point in try pack.geometry?.polyline(edgeIndex: edge) ?? [] {
                minLon = min(minLon,point.longitude); maxLon = max(maxLon,point.longitude)
                minLat = min(minLat,point.latitude); maxLat = max(maxLat,point.latitude)
            }
            return .init(aLon: aLon,aLat: aLat,bLon: bLon,bLat: bLat,
                minLon: minLon,maxLon: maxLon,minLat: minLat,maxLat: maxLat)
        }
        pack.exactSnapIndex = try ExactSnapIndex(url: url, identity: identity)
    }
    return OnDeviceRouter(pack: pack)
}
