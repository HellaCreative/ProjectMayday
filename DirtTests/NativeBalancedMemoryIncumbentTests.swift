import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Balanced retains verified road completion at label memory limit", .serialized)
struct NativeBalancedMemoryIncumbentTests {
    @Test func memoryCapAfterDestinationRetainsRoadAndDisclosesIncompleteSelection() throws {
        var router = try fixture()
        // One-label pages make each allocation boundary observable without a
        // test-only injected failure or changes to the legal graph.
        router.balancedLabelPageCapacity = 1
        var retained: OnDeviceRouter.Result?
        for labels in 1...256 {
            router.maximumSearchLabelPayloadBytes = labels * MemoryLayout<DemandBalancedSearchLabels.Label>.stride
            if case .success(let result) = calculate(router), result.searchMeta.pass2Outcome == "labelMemoryCap" {
                retained = result
                break
            }
        }
        let result = try #require(retained, "Fixture must actually exhaust after reaching a legal destination")
        #expect(result.searchMeta.timedOut)
        #expect(result.searchMeta.rideObjective == "surface-balance")
        #expect(result.searchMeta.resourceSelectionCost?.isFinite == true)
        #expect(result.coordinates.count > 1)
        #expect(result.distanceMeters > 0)
        #expect(result.backtrackMeters == 0)
        #expect(result.terminalContinuation != nil)
        #expect(result.legs.allSatisfy { $0.accessName == "motorized_verified" })
        let destination = point(router.pack, 4)
        #expect(result.coordinates.last?.latitude == destination.latitude)
        #expect(result.coordinates.last?.longitude == destination.longitude)
        #expect(abs(result.legs.reduce(0) { $0 + $1.distanceMeters } - result.distanceMeters) < 0.001)
        router.maximumSearchLabelPayloadBytes = 128 * 1024 * 1024
        guard case .success(let complete) = calculate(router) else {
            Issue.record("Adequate memory must complete the same fixture"); return
        }
        #expect(!complete.searchMeta.timedOut)

    }

    @Test func noIncumbentAndCancellationRemainFailures() throws {
        var router = try fixture()
        router.maximumSearchLabelPayloadBytes = 0
        guard case .failure(.searchLimit) = calculate(router) else {
            Issue.record("No allocated route cannot be preserved"); return
        }
        router.maximumSearchLabelPayloadBytes = 128 * 1024 * 1024
        RoutingWorkContext.$deadline.withValue(0) {
            guard case .failure(.searchLimit) = calculate(router) else {
                Issue.record("Cancellation must not publish an incumbent"); return
            }
        }
    }

    private func fixture() throws -> OnDeviceRouter {
        let prefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety")
        let pack = try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path + ".graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path + ".geometry.v1.bin")))
        var router = try fixtureRouter(pack: pack)
        router.recordedStartNode = try #require(pack.osmNodeIds.firstIndex(of: 1))
        router.recordedEndNode = try #require(pack.osmNodeIds.firstIndex(of: 4))
        router.matchLimitMeters = 30
        return router
    }
    private func point(_ pack: GraphV2Pack,_ id: Int64) -> CLLocationCoordinate2D {
        let node = pack.osmNodeIds.firstIndex(of: id)!
        return .init(latitude: Double(pack.nodeCoords[node*2+1]),longitude: Double(pack.nodeCoords[node*2]))
    }
    private func calculate(_ router: OnDeviceRouter) -> Swift.Result<OnDeviceRouter.Result,OnDeviceRouter.Failure> {
        router.routeDetailed(from: point(router.pack,1),to: point(router.pack,4),profile: .balanced,
            allowUnknown: false,sessionSeed: 17)
    }
}
