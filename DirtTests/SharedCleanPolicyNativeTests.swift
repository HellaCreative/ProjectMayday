import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct SharedCleanPolicyNativeTests {
    @Test func nativeRoutesMatchReferenceCostBlockExactly() throws {
        for fixture in ["native-preferences-city", "native-preferences-variety"] {
            let prefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + fixture)
            let pack = try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path + ".graph.v4.bin")))
            pack.geometry = try GeometryV1Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path + ".geometry.v1.bin")))
            let start = try #require(pack.osmNodeIds.firstIndex(of: 1))
            let end = try #require(pack.osmNodeIds.firstIndex(of: 4))
            func point(_ n: Int) -> CLLocationCoordinate2D {
                .init(latitude: Double(pack.nodeCoords[n * 2 + 1]), longitude: Double(pack.nodeCoords[n * 2]))
            }
            for profile in [RouteProfile.cleanest, .dirt, .balanced] {
                for avoidMotorways in [false, true] {
                    for initialFuel in [false, true] {
                        var reference = try fixtureRouter(pack: pack)
                        reference.recordedStartNode = start; reference.recordedEndNode = end
                        reference.initialFuelApproach = initialFuel
                        reference.useSharedCleanPolicyReads = false
                        var extracted = reference
                        extracted.useSharedCleanPolicyReads = true
                        let old = reference.routeDetailed(from: point(start), to: point(end), profile: profile,
                            allowUnknown: false, sessionSeed: 17, avoidMotorways: avoidMotorways)
                        let new = extracted.routeDetailed(from: point(start), to: point(end), profile: profile,
                            allowUnknown: false, sessionSeed: 17, avoidMotorways: avoidMotorways)
                        switch (old, new) {
                        case let (.success(a), .success(b)):
                            #expect(a.edgeIds == b.edgeIds)
                            #expect(a.coordinates.map { $0.latitude.bitPattern } == b.coordinates.map { $0.latitude.bitPattern })
                            #expect(a.coordinates.map { $0.longitude.bitPattern } == b.coordinates.map { $0.longitude.bitPattern })
                            #expect(a.distanceMeters.bitPattern == b.distanceMeters.bitPattern)
                            #expect(a.terminalContinuation == b.terminalContinuation)
                            #expect(a.searchMeta.pops == b.searchMeta.pops)
                            #expect(a.searchMeta.pass2Outcome == b.searchMeta.pass2Outcome)
                            #expect(a.searchMeta.resourceSelectionCost?.bitPattern == b.searchMeta.resourceSelectionCost?.bitPattern)
                            #expect(a.reportedDirtPercent == b.reportedDirtPercent)
                            #expect(a.reportedPavedPercent == b.reportedPavedPercent)
                        case let (.failure(a), .failure(b)):
                            #expect(String(describing: a) == String(describing: b))
                        default: Issue.record("Extracted cost changed route completion for \(fixture)/\(profile)")
                        }
                    }
                }
            }
        }
    }
}
