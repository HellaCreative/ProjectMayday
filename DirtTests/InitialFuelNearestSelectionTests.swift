import CoreLocation
import Foundation
import Testing
@testable import Dirt

@MainActor
struct InitialFuelNearestSelectionTests {
    private func station(_ id: String, longitude: Double) -> POIFeature {
        .init(id: id, category: "fuel", latitude: 0, longitude: longitude,
            name: id, address: nil, brand: nil, openingHours: nil, phone: nil, website: nil)
    }
    @Test func fartherGeographicStationWinsOnActualLegalDistanceWithTwoAttempts() async throws {
        let near = station("a-near", longitude: 0.001), farther = station("b-farther", longitude: 0.002)
        let remote = (0..<100).map { station("remote-\($0)", longitude: Double($0 + 1)) }
        var calls: [String] = [], boundCalls = 0
        let winner = try await InitialFuelNearestSelection.choose(candidates: [near,farther] + remote,
            rangeMeters: 180_000, requiredStationID: nil, attempt: { station, cap in
                #expect(cap == 180_000, "Incumbent must not change preferred-match selection through a tighter cap")
                calls.append(station.id)
                return .init(value: station.id, meters: station.id == near.id ? 900 : 400)
            }, lowerBounds: { remaining, incumbent in
                boundCalls += 1
                #expect(incumbent == 900)
                return Dictionary(uniqueKeysWithValues: remaining.map { ($0.id, $0.id == farther.id ? 300.0 : .infinity) })
            })
        #expect(winner?.station.id == farther.id)
        #expect(winner?.route.meters == 400)
        #expect(calls == [near.id, farther.id])
        #expect(boundCalls == 1)
    }
    @Test func oneActualAttemptSufficesOnlyWhenEveryRemainingBoundProvesIt() async throws {
        let near = station("a", longitude: 0), farther = station("b", longitude: 1)
        var calls = 0
        let winner = try await InitialFuelNearestSelection.choose(candidates: [near,farther],
            rangeMeters: 180_000, requiredStationID: nil, attempt: { station, _ in
                calls += 1; return .init(value: station.id, meters: 100)
            }, lowerBounds: { _, _ in [farther.id: 101] })
        #expect(winner?.station.id == near.id)
        #expect(calls == 1)
    }
    @Test func incompleteFieldNeverLabelsAnIncumbentClosest() async throws {
        let near = station("a", longitude: 0), farther = station("b", longitude: 1)
        do {
            _ = try await InitialFuelNearestSelection.choose(candidates: [near,farther],
                rangeMeters: 180_000, requiredStationID: nil,
                attempt: { station, _ in .init(value: station.id, meters: 100) },
                lowerBounds: { _, _ in nil })
            Issue.record("Incomplete proof returned a winner")
        } catch InitialFuelNearestSelection.Failure.incompleteProof {} catch { throw error }
    }
    @Test func requiredStationDoesNotNeedClosestProofAndCancellationStillPropagates() async throws {
        let a = station("a", longitude: 0), b = station("b", longitude: 1)
        let selected = try await InitialFuelNearestSelection.choose(candidates: [a,b],
            rangeMeters: 180_000, requiredStationID: b.id, attempt: { station, _ in
                #expect(station.id == b.id); return .init(value: station.id, meters: 500)
            }, lowerBounds: { _, _ in Issue.record("Required pump must not invoke closest proof"); return nil })
        #expect(selected?.station.id == b.id)
        do {
            _ = try await InitialFuelNearestSelection.choose(candidates: [a,b],
                rangeMeters: 180_000, requiredStationID: nil,
                attempt: { station, _ in .init(value: station.id, meters: 100) },
                lowerBounds: { _, _ in throw CancellationError() })
            Issue.record("Cancellation returned a winner")
        } catch is CancellationError {} catch { throw error }
    }
    @Test func sameParentAndActualWideMatchingRadiusRemainInBoundSuperset() throws {
        let bundle = Bundle(for: InitialBoundFixtureBundle.self)
        func bytes(_ name: String) throws -> Data {
            let url = bundle.url(forResource: name, withExtension: nil)
                ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
            return try Data(contentsOf: url)
        }
        let pack = try GraphV2Pack(data: bytes("legal-topology-restrictions.graph.v4.bin"))
        pack.geometry = try GeometryV1Pack(data: bytes("legal-topology-restrictions.geometry.v1.bin"))
        let router = try fixtureRouter(pack: pack)
        let a = try #require(pack.osmNodeIds.firstIndex(of: 1)), b = try #require(pack.osmNodeIds.firstIndex(of: 2))
        let origin = CLLocationCoordinate2D(latitude: Double(pack.nodeCoords[a*2+1]), longitude: Double(pack.nodeCoords[a*2]))
        let end = CLLocationCoordinate2D(latitude: Double(pack.nodeCoords[b*2+1]), longitude: Double(pack.nodeCoords[b*2]))
        let midpoint = CLLocationCoordinate2D(latitude: (origin.latitude+end.latitude)/2,
            longitude: (origin.longitude+end.longitude)/2)
        let sameEdge = try #require(try router.initialStationLowerBounds(from: origin,
            stations: [(point: midpoint, matchMeters: 1)], incumbentMeters: 0))
        #expect(sameEdge == [0], "Zero-seeded parent must protect a station before either road endpoint")
        let offset = CLLocationCoordinate2D(latitude: midpoint.latitude + 0.007, longitude: midpoint.longitude)
        let wide = try #require(try router.initialStationLowerBounds(from: origin,
            stations: [(point: offset, matchMeters: 1_000)], incumbentMeters: 100))
        #expect(wide == [0], "Actual wide matching cannot be eliminated by the old 550m discovery cap")
        let narrow = try #require(try router.initialStationLowerBounds(from: origin,
            stations: [(point: offset, matchMeters: 1)], incumbentMeters: 100))
        #expect(narrow == [.infinity])
        #expect(try router.initialStationLowerBounds(from: origin,
            stations: [(point: midpoint, matchMeters: 1)], incumbentMeters: 0,
            limits: .init(maximumStates: 1)) == nil)
    }
}
private final class InitialBoundFixtureBundle: NSObject {}
