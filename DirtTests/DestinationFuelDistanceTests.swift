import CoreLocation
import Foundation
import Testing
@testable import Dirt

@MainActor
struct DestinationFuelDistanceTests {
    private func fixture(_ variant: String) throws -> OnDeviceRouter {
        func data(_ suffix: String) throws -> Data {
            let name = "initial-distance-" + variant + suffix
            let bundle = Bundle(for: DestinationDistanceFixtureBundle.self)
            let url = bundle.url(forResource: name, withExtension: nil)
                ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
            return try Data(contentsOf: url)
        }
        let pack = try GraphV2Pack(data: data(".graph.v4.bin"))
        pack.geometry = try GeometryV1Pack(data: data(".geometry.v1.bin"))
        var router = try fixtureRouter(pack: pack)
        router.matchLimitMeters = 20
        router.endEndpointKind = "customers"
        router.ridePreferences = RidePreferences(wander: 1, avoidCities: true, avoidHighways: false)
        return router
    }
    private let destination = RouteCoordinate(longitude: 0, latitude: 0)
    private let pumpPoint = CLLocationCoordinate2D(latitude: 0, longitude: 0.025)
    private func station(_ id: String, lon: Double) -> POIFeature {
        .init(id: id, category: "fuel", latitude: 0, longitude: lon, name: id,
            address: nil, brand: nil, openingHours: nil, phone: nil, website: nil)
    }
    private func arrival(_ router: OnDeviceRouter) throws -> OnDeviceRouter.Result {
        var approach = router
        approach.endEndpointKind = nil
        let outcome = approach.routeDetailed(from: .init(latitude: 0, longitude: -0.005),
            to: destination.locationCoordinate, profile: .dirt, allowUnknown: false)
        guard case .success(let route) = outcome else { throw FixtureFailure.route("\(outcome)") }
        return route
    }
    @Test func estimateUsesOneActualRouteWithoutClaimingClosestOrArrivalProof() async throws {
        var router = try fixture("plain")
        router.initialFuelApproach = true
        var attempts = 0
        let estimate = await PackRoutingSource.estimateDestinationFuel(from: destination,
            stations: [station("far", lon: 1), station("near", lon: 0.025)], usableMeters: 3_000) { station, cap in
                attempts += 1
                #expect(station.id == "near")
                return router.routeDetailed(from: destination.locationCoordinate, to: pumpPoint,
                    profile: .cleanest, allowUnknown: false, maxRouteMeters: cap)
            }
        #expect(attempts == 1)
        #expect(estimate.stationID == "near")
        #expect(estimate.meters != nil && estimate.meters! <= 3_000)
    }
    @Test func incompleteEstimateNeverReportsGapOrMakesMoreAttempts() async throws {
        let estimate = await PackRoutingSource.estimateDestinationFuel(from: destination,
            stations: [station("a", lon: 0.025), station("b", lon: 1)], usableMeters: 3_000) { _, _ in
                .failure(.searchLimit("timeBudget"))
            }
        #expect(estimate.meters == nil && estimate.stationID == nil && estimate.attempts == 1)
        let expired = await RoutingWorkContext.$deadline.withValue(ProcessInfo.processInfo.systemUptime - 1) {
            await PackRoutingSource.estimateDestinationFuel(from: destination,
                stations: [station("a", lon: 0.025)], usableMeters: 3_000) { _, _ in
                    Issue.record("Expired preparation invoked native search"); return .failure(.noPath)
                }
        }
        #expect(expired.meters == nil && expired.attempts == 0)
    }
    @Test func distanceContingencyFitsWhenRecreationalTownDetourDoesNot() async throws {
        let recreational = try fixture("urban")
        let ride = try arrival(recreational)
        let token = try #require(ride.terminalContinuation)
        var contingency = recreational
        contingency.initialFuelApproach = true
        let cap = 3_000.0
        let physical = contingency.routeDetailed(from: destination.locationCoordinate, to: pumpPoint,
            profile: .dirt, allowUnknown: false, arrivalContinuation: token, maxRouteMeters: cap)
        guard case .success(let escape) = physical else { Issue.record("Distance contingency did not fit: \(physical)"); return }
        #expect(escape.distanceMeters <= cap)
        #expect(escape.edgeIds.contains { $0.hasPrefix("w20:") })
        // Only the proof router receives the distance objective. The accepted
        // rider route and the recreational policy remain independent values.
        #expect(recreational.initialFuelApproach == false)
        #expect(ride.coordinates.last?.longitude == destination.longitude)
        let normal = recreational.routeDetailed(from: destination.locationCoordinate, to: pumpPoint,
            profile: .cleanest, allowUnknown: false, arrivalContinuation: token, maxRouteMeters: 20_000)
        guard case .success(let long) = normal else { Issue.record("Recreational comparison failed"); return }
        #expect(long.distanceMeters > cap)
        let proof = await PackRoutingSource.verifyDestinationEscape(arrival: token, remainingMeters: cap,
            stations: [station("pump", lon: 0.025)]) { _, carried, remaining in
                #expect(carried == token)
                return contingency.routeDetailed(from: destination.locationCoordinate, to: pumpPoint,
                    profile: .dirt, allowUnknown: false, arrivalContinuation: carried, maxRouteMeters: remaining)
            }
        guard case .verified = proof else { Issue.record("Legal distance contingency was not verified"); return }
    }
    @Test func freshEstimateDoesNotReopenProhibitedArrivalOrExplicitDenial() async throws {
        for variant in ["turn", "denied"] {
            var router = try fixture(variant)
            let ride = try arrival(router)
            let token = try #require(ride.terminalContinuation)
            router.initialFuelApproach = true
            if variant == "turn" {
                let estimate = await PackRoutingSource.estimateDestinationFuel(from: destination,
                    stations: [station("pump", lon: 0.025)], usableMeters: 3_000) { _, cap in
                        router.routeDetailed(from: destination.locationCoordinate, to: pumpPoint,
                            profile: .dirt, allowUnknown: false, maxRouteMeters: cap)
                    }
                #expect(estimate.meters != nil)
            }
            for allowUnknown in [false, true] {
                let proof = await PackRoutingSource.verifyDestinationEscape(arrival: token, remainingMeters: 3_000,
                    stations: [station("pump", lon: 0.025)]) { _, carried, cap in
                        router.routeDetailed(from: destination.locationCoordinate, to: pumpPoint,
                            profile: .dirt, allowUnknown: allowUnknown, arrivalContinuation: carried, maxRouteMeters: cap)
                    }
                guard case .unknown = proof else { Issue.record("Distance objective reopened \(variant)"); continue }
            }
        }
    }
    private enum FixtureFailure: Error { case route(String) }
}
private final class DestinationDistanceFixtureBundle: NSObject {}
