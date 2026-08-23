import CoreLocation
import Foundation
import Testing
@testable import Dirt

/// Phase E2: Clean path from road-class + surface leaves must match JS findPathV2.
struct GraphV3CleanPathLockstepTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: src.path) { return src }
        Issue.record("missing fixture \(name)")
        throw GraphV2Pack.PackError.truncated
    }

    private func loadNsV3() throws -> GraphV2Pack {
        let graph = try fixtureURL("DirtLocalPacks/ns/graph.v3.bin")
        let geom = try fixtureURL("DirtLocalPacks/ns/geometry.v1.bin")
        let pack = try GraphV2Pack(data: Data(contentsOf: graph))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: geom))
        return pack
    }

    @Test func cleanLeafLawBlocksDestinationAndPrefersCollector() {
        #expect(RoadTierStats.tier(of: "secondary") == .collector)
        #expect(RoadTierStats.tier(of: "primary") == .arterial)
        #expect(RoadTierStats.tier(of: "residential") == .destination)
        #expect(
            RoadTierStats.isBlockedForCleanLeaf(
                family: .paved, tier: .destination, pavedOnly: true, isEndpointEdge: false
            )
        )
        #expect(
            !RoadTierStats.isBlockedForCleanLeaf(
                family: .paved, tier: .destination, pavedOnly: true, isEndpointEdge: true
            )
        )
        let collector = RoadTierStats.cleanLeafCostMult(tier: .collector, family: .paved)
        let arterial = RoadTierStats.cleanLeafCostMult(tier: .arterial, family: .paved)
        let motorway = RoadTierStats.cleanLeafCostMult(tier: .motorway, family: .paved)
        #expect(collector < arterial)
        #expect(arterial < motorway)
    }

    @Test func swiftCleanPathMatchesJsLockstepFixture() throws {
        let pack = try loadNsV3()
        #expect(pack.hasLeaves)
        let router = OnDeviceRouter(pack: pack)

        let fixtureData = try Data(contentsOf: try fixtureURL("ns-graph.v3.clean-path.lockstep.json"))
        guard let root = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
              let routes = root["routes"] as? [[String: Any]] else {
            Issue.record("fixture routes missing")
            return
        }

        for route in routes {
            let id = route["id"] as? String ?? "?"
            guard let fromArr = route["from"] as? [Double], fromArr.count >= 2,
                  let toArr = route["to"] as? [Double], toArr.count >= 2,
                  let startEi = route["startEdgeIndex"] as? Int,
                  let endEi = route["endEdgeIndex"] as? Int,
                  let startCoord = route["startCoord"] as? [Double], startCoord.count >= 2,
                  let endCoord = route["endCoord"] as? [Double], endCoord.count >= 2,
                  let startAlong = route["startAlongM"] as? Double,
                  let endAlong = route["endAlongM"] as? Double,
                  let expectedIds = route["edgeIds"] as? [String] else {
                Issue.record("incomplete route \(id)")
                continue
            }
            let from = CLLocationCoordinate2D(latitude: fromArr[1], longitude: fromArr[0])
            let to = CLLocationCoordinate2D(latitude: toArr[1], longitude: toArr[0])
            let startProj = CLLocationCoordinate2D(latitude: startCoord[1], longitude: startCoord[0])
            let endProj = CLLocationCoordinate2D(latitude: endCoord[1], longitude: endCoord[0])

            guard let result = router.routeCleanLockstep(
                from: from,
                to: to,
                startEdgeIndex: startEi,
                endEdgeIndex: endEi,
                startProjected: startProj,
                endProjected: endProj,
                startAlongM: startAlong,
                endAlongM: endAlong,
                sessionSeed: 1
            ) else {
                Issue.record("Swift Clean route failed for \(id)")
                continue
            }

            let gotIds = result.edgeIds.filter {
                !$0.hasPrefix("soft-stitch-") && !$0.hasPrefix("perm-stitch-")
            }
            #expect(gotIds == expectedIds, "edge path mismatch route=\(id) got=\(gotIds.count) exp=\(expectedIds.count)")

            let expDirt = route["dirtPercent"] as? Int ?? -1
            #expect(result.reportedDirtPercent == expDirt, "dirt% route=\(id)")
            #expect(result.reportedDirtPercent <= 2, "Clean dirt% too high route=\(id)")

            // No residential/living_street through-hops except endpoints.
            for (idx, ei) in (route["edgeIndexes"] as? [Int] ?? []).enumerated() {
                let tier = pack.roadTier(ei)
                if tier == .destination {
                    let isEnd = idx == 0 || idx == gotIds.count - 1 || ei == startEi || ei == endEi
                    #expect(isEnd, "destination through-route at \(idx) route=\(id)")
                }
            }
        }
    }
}
