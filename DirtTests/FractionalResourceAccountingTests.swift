import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite struct FractionalResourceAccountingTests {
    @Test func fractionalKnownDirtContributesToSelectedResourceMix() throws {
        let (result, _) = try route(ferry: false)
        let selectedDirt = try #require(result.searchMeta.resourceSelectionDirtMeters)
        let actualDirt = result.legs.filter { $0.surfaceName == "gravel" }.reduce(0) { $0 + $1.distanceMeters }
        #expect(actualDirt > 1_000)
        #expect(abs(selectedDirt - actualDirt) < 0.01)
        #expect((49...51).contains(result.dirtPercent))
    }

    @Test func fractionalFerryNeverCountsAsDirtAndUsesParentTimeCost() throws {
        let (result, pack) = try route(ferry: true)
        #expect(result.legs.contains { $0.structureType == "ferry" })
        #expect(result.searchMeta.resourceSelectionDirtMeters == 0)
        #expect(result.dirtPercent == 0)
        var expected = 0.0
        for leg in result.legs {
            if leg.structureType == "ferry" {
                let edge = try #require(leg.edgeIndex)
                #expect(try pack.crossingSeconds(edge) == 600)
                expected += OnDeviceProfileCosts.fractionalFerryRelaxStepCost(
                    traversedMeters: leg.distanceMeters, parentMeters: Double(pack.edgeMeters[edge]),
                    storedSeconds: try pack.crossingSeconds(edge))
            } else { expected += leg.distanceMeters / 1_000 }
        }
        #expect(abs((try #require(result.searchMeta.resourceSelectionCost)) - expected) < 0.02)
    }

    @Test func splittingFerryCostDoesNotReapplyMinimumCrossingTime() {
        for seconds: UInt32 in [0, 600] {
            for distance in [10.0, 10_000] {
                let full = OnDeviceProfileCosts.ferryRelaxStepCost(crossingSeconds:
                    OnDeviceProfileCosts.ferryCrossingSeconds(distanceMeters: distance, storedSeconds: seconds))
                let pieces = [0.1, 0.3, 0.6].reduce(0) { total, fraction in
                    total + OnDeviceProfileCosts.fractionalFerryRelaxStepCost(
                        traversedMeters: distance * fraction, parentMeters: distance, storedSeconds: seconds)
                }
                #expect(abs(full - pieces) < 0.000001)
            }
        }
    }

    private func route(ferry: Bool) throws -> (OnDeviceRouter.Result, GraphV2Pack) {
        let name = ferry ? "fractional-ferry" : "fractional-dirt"
        func fixture(_ suffix: String) -> URL {
            let file = name + suffix
            let bundle = Bundle(for: FractionalResourceFixtureBundle.self)
            return bundle.url(forResource: file, withExtension: nil)
                ?? bundle.url(forResource: file, withExtension: nil, subdirectory: "Fixtures")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + file)
        }
        let pack = try GraphV2Pack(data: Data(contentsOf: fixture(".graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: fixture(".geometry.v1.bin")))
        var router = try fixtureRouter(pack: pack)
        router.matchLimitMeters = 30
        let outcome = router.routeDetailed(from: .init(latitude: 0, longitude: 0.005),
            to: .init(latitude: 0, longitude: 0.025), profile: .balanced, allowUnknown: false, sessionSeed: 0)
        guard case .success(let result) = outcome else { throw FixtureError.failed("\(outcome)") }
        return (result, pack)
    }
    private enum FixtureError: Error { case failed(String) }
}
private final class FractionalResourceFixtureBundle: NSObject {}
