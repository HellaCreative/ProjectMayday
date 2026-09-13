import CoreLocation
import Foundation
import Testing
@testable import Dirt

@MainActor
struct DestinationFuelEscapeTests {
    @Test func reachableFreshExitIsNotProofAfterRestrictedArrival() async throws {
        let pack = try packFixture()
        var approachRouter = OnDeviceRouter(pack: pack)
        approachRouter.recordedStartNode = try node(pack, 1)
        approachRouter.recordedEndNode = try node(pack, 3)
        let start = coordinate(pack, try node(pack, 1)), arrival = coordinate(pack, try node(pack, 3))
        let end = coordinate(pack, try node(pack, 5))
        guard case .success(let approach) = approachRouter.routeDetailed(from: start, to: arrival,
            profile: .cleanest, allowUnknown: false, sessionSeed: 0) else {
            Issue.record("Expected legal arrival before prohibited exit"); return
        }
        let token = try #require(approach.terminalContinuation)
        var escapeRouter = OnDeviceRouter(pack: pack)
        escapeRouter.recordedStartNode = try node(pack, 3)
        escapeRouter.recordedEndNode = try node(pack, 5)
        guard case .success = escapeRouter.routeDetailed(from: arrival, to: end,
            profile: .cleanest, allowUnknown: false, sessionSeed: 0) else {
            Issue.record("Fresh-start escape fixture must be reachable"); return
        }
        let proof = await PackRoutingSource.verifyDestinationEscape(arrival: token, remainingMeters: 1_000,
            stations: [station(end)]) { _, carried, cap in
                escapeRouter.routeDetailed(from: arrival, to: end, profile: .cleanest,
                    allowUnknown: false, arrivalContinuation: carried, sessionSeed: 0, maxRouteMeters: cap)
            }
        guard case .unknown = proof else { Issue.record("Restricted arrival falsely proved fuel escape"); return }
    }

    @Test func selectedEscapeDistanceMustFitActualRemainingFuel() async throws {
        let pack = try packFixture()
        var router = OnDeviceRouter(pack: pack)
        router.recordedStartNode = try node(pack, 5)
        router.recordedEndNode = try node(pack, 4)
        let start = coordinate(pack, try node(pack, 5)), end = coordinate(pack, try node(pack, 4))
        guard case .success(let legal) = router.routeDetailed(from: start, to: end,
            profile: .cleanest, allowUnknown: false, sessionSeed: 0) else {
            Issue.record("Expected finite escape route fixture"); return
        }
        let token = try #require(legal.terminalContinuation)
        let limit = legal.distanceMeters / 2
        let rejected = await PackRoutingSource.verifyDestinationEscape(arrival: token, remainingMeters: limit,
            stations: [station(end)]) { _, carried, cap in
                #expect(carried == token)
                #expect(cap == limit)
                // Deliberately simulate a lower-level result exceeding the
                // supplied cap: the proof boundary must independently reject it.
                return .success(legal)
            }
        guard case .unknown = rejected else { Issue.record("Over-range escape was accepted"); return }
        let accepted = await PackRoutingSource.verifyDestinationEscape(arrival: token,
            remainingMeters: legal.distanceMeters, stations: [station(end)]) { _, _, _ in .success(legal) }
        guard case .verified(let actual) = accepted else { Issue.record("In-range legal proof was rejected"); return }
        #expect(actual == legal.distanceMeters)
    }

    @Test func expiredProofAndEmptyCandidatesRemainUnknown() async throws {
        let pack = try packFixture()
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        let edge = try #require(pack.osmWayIds.firstIndex(of: 10))
        let token = try turns.exportContinuation(state: turns.stateForArrival(node: node(pack, 2), incomingEdge: edge),
            incomingEdge: edge, arrivedFromNode: node(pack, 1), pack: pack)
        var queries = 0
        let candidate = station(coordinate(pack, try node(pack, 5)))
        let expired = await RoutingWorkContext.$deadline.withValue(0) {
            await PackRoutingSource.verifyDestinationEscape(arrival: token, remainingMeters: 1_000,
                stations: [candidate]) { _, _, _ in
                    queries += 1; return .failure(.noPath)
                }
        }
        #expect(queries == 0)
        guard case .unknown = expired else { Issue.record("Expired proof must remain unknown"); return }
        let empty = await PackRoutingSource.verifyDestinationEscape(arrival: token, remainingMeters: 1_000,
            stations: []) { _, _, _ in queries += 1; return .failure(.noPath) }
        #expect(queries == 0)
        guard case .unknown = empty else { Issue.record("No candidates are not a demonstrated fuel gap"); return }
    }

    @Test func cancelledProofDoesNotBeginAnotherStationQuery() async throws {
        let pack = try packFixture()
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        let edge = try #require(pack.osmWayIds.firstIndex(of: 10))
        let token = try turns.exportContinuation(state: turns.stateForArrival(node: node(pack, 2), incomingEdge: edge),
            incomingEdge: edge, arrivedFromNode: node(pack, 1), pack: pack)
        let candidate = station(coordinate(pack, try node(pack, 5)))
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var queries = 0
        let task = Task {
            for await _ in stream { break }
            return await PackRoutingSource.verifyDestinationEscape(arrival: token,
                remainingMeters: 1_000, stations: [candidate]) { _, _, _ in
                    queries += 1; return .failure(.noPath)
                }
        }
        task.cancel()
        continuation.finish()
        let outcome = await task.value
        #expect(queries == 0)
        guard case .unknown = outcome else { Issue.record("Cancelled proof must remain unknown"); return }
    }

    @Test func destinationDistanceOrdersCandidatesAndFailedNearestDoesNotEndProof() async throws {
        let pack = try packFixture()
        var router = OnDeviceRouter(pack: pack)
        router.recordedStartNode = try node(pack, 5)
        router.recordedEndNode = try node(pack, 4)
        let a = coordinate(pack, try node(pack, 5)), b = coordinate(pack, try node(pack, 4))
        guard case .success(let legal) = router.routeDetailed(from: a, to: b,
            profile: .cleanest, allowUnknown: false, sessionSeed: 0) else {
            Issue.record("Expected finite route fixture"); return
        }
        let token = try #require(legal.terminalContinuation)
        func pump(_ id: String, _ longitude: Double) -> POIFeature {
            .init(id: id, category: "fuel", latitude: 0, longitude: longitude,
                name: id, address: nil, brand: nil, openingHours: nil, phone: nil, website: nil)
        }
        let remote = pump("remote", 1), near = pump("near", 0.0001), next = pump("next", 0.0002)
        var attempted: [String] = []
        let proof = await PackRoutingSource.verifyDestinationEscape(arrival: token,
            remainingMeters: 1_000, from: .init(longitude: 0, latitude: 0),
            stations: [remote, next, near]) { candidate, carried, cap in
                attempted.append(candidate.id)
                #expect(carried == token)
                #expect(cap == 1_000)
                if candidate.id == "near" { return .failure(.noPath) }
                return .success(legal)
            }
        #expect(attempted == ["near", "next"])
        guard case .verified = proof else { Issue.record("Next legally proved candidate should qualify"); return }
    }

    private func packFixture() throws -> GraphV2Pack {
        let pack = try GraphV2Pack(data: data("legal-topology-restrictions.graph.v4.bin"))
        pack.geometry = try GeometryV1Pack(data: data("legal-topology-restrictions.geometry.v1.bin"))
        return pack
    }
    private func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: EscapeFixtureBundle.self)
        let url = bundle.url(forResource: name, withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
        return try Data(contentsOf: url)
    }
    private func node(_ pack: GraphV2Pack, _ original: Int64) throws -> Int { try #require(pack.osmNodeIds.firstIndex(of: original)) }
    private func coordinate(_ pack: GraphV2Pack, _ node: Int) -> CLLocationCoordinate2D {
        .init(latitude: Double(pack.nodeCoords[node * 2 + 1]), longitude: Double(pack.nodeCoords[node * 2]))
    }
    private func station(_ point: CLLocationCoordinate2D) -> POIFeature {
        .init(id: "fixture-pump", category: "fuel", latitude: point.latitude, longitude: point.longitude,
            name: "Fixture pump", address: nil, brand: nil, openingHours: nil, phone: nil, website: nil)
    }
}

private final class EscapeFixtureBundle: NSObject {}
