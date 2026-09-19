import Foundation
import CryptoKit
import Testing
import DirtRoutingEngine
@testable import Dirt

/// Opt-in qualification through the same session and response conversion used by
/// the app. Reads immutable host fixtures; never installs into the rider's cache.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DIRT_QUALIFY_CANDIDATE"] == "1"))
struct NativeCandidateQualificationTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/pack-fabric/routing/candidates/fabric-v4-20260917-02/packs")
    }

    @Test(.timeLimit(.minutes(5)))
    func ontarioRideVarietyAndFrozenResponse() async throws {
        let session = NativeRoutingSession()
        let directories = ["on-s": root.appendingPathComponent("on-s")]
        var first: [String] = [], signatures = Set<String>()
        for seed: UInt64 in [1, 2, 3, 1] {
            let req = RidePreferenceContext.$current.withValue(
                .init(wander: 1, avoidCities: true, avoidHighways: true)) {
                RouteRequest(profile: .dirt, locations: [
                    .init(latitude: 43.4516, longitude: -80.4925, label: "Kitchener"), .init(latitude: 44.3894, longitude: -79.6903, label: "Barrie")
                ], allowUnknown: false, sessionSeed: seed, matchLimitMeters: 250)
            }
            let native = try NativeRoutingAdapter.request(req)
            #expect(native.profile.appetite == 1)
            #expect(native.profile.avoidMajorHighways && native.options.cityWall)
            #expect(!native.access.allowUnknown)
            let started = ContinuousClock.now
            let route = try await session.route(native, directories: directories)
            let quality = RouteQuality(route: route)
            #expect(route.limit == nil)
            #expect(quality.knownDirtPercent >= 70)
            #expect(quality.reriddenMeters == 0)
            #expect(quality.returnMeters == 0)
            #expect(route.segments.allSatisfy { $0.access == 0 })
            #expect(route.start.coordinate.distance(to: native.start) <= 250)
            #expect(route.end.coordinate.distance(to: native.end) <= 250)
            let response = NativeRoutingAdapter.response(route, style: .dirt)
            let data = try JSONEncoder().encode(response)
            let reopened = try JSONDecoder().decode(RouteResponse.self, from: data)
            #expect(reopened.geometry == response.geometry)
            #expect(reopened.dirtPercent == response.dirtPercent)
            let painted = RouteSurfaceComposition.from(responses: [response])
            #expect(abs(painted.dirtPercent - response.dirtPercent) <= 1)
            let roads = route.segments.map(\.edgeID)
            if seed == 1 {
                if first.isEmpty { first = roads } else { #expect(roads == first) }
            }
            signatures.insert(roads.joined(separator: "|"))
            report("ontario-seed-\(seed)", started: started, route: route)
        }
        #expect(signatures.count == 3)
    }

    @Test(.timeLimit(.minutes(5)))
    func crossCanadaKeepsRiderDestinationAndBoundsWorkingMemory() async throws {
        let regions = ["ns", "nb", "qc-s", "on-n", "mb", "sk", "ab", "bc"]
        let directories = Dictionary(uniqueKeysWithValues: regions.map { ($0, root.appendingPathComponent($0)) })
        let session = NativeRoutingSession()
        for run in 1...2 {
            var request = RoutingRequest(start: .init(longitude: -63.5752, latitude: 44.6488),
                end: .init(longitude: -123.1558, latitude: 49.7016), style: .dirt, allowUnknown: false, seed: 1)
            request.profile.wander = 1; request.profile.avoidMajorHighways = true; request.options.cityWall = true
            let started = ContinuousClock.now
            let route = try await session.route(request, directories: directories)
            #expect(route.limit == nil)
            #expect(route.end.coordinate.distance(to: request.end) <= 250)
            #expect(route.segments.allSatisfy { $0.access != 1 && $0.access != 2 && $0.access != 5 })
            let hash = SHA256.hash(data: Data((route.segments.map(\.edgeID).joined(separator: "\n") + "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            #expect(hash == "22f7e584630576a203013905553bc71fabab1cd2407419dd0324a7ef1367f13d")
            #expect(RouteQuality(route: route).knownDirtPercent >= 70)
            #expect(ProcessMemory.megabytes().peak < 1_300)
            report("canada-\(run)", started: started, route: route)
        }
    }

    private func report(_ name: String, started: ContinuousClock.Instant, route: ComputedRoute) {
        let d = started.duration(to: .now).components
        let seconds = Double(d.seconds) + Double(d.attoseconds) / 1e18
        let q = RouteQuality(route: route)
        print("CANDIDATE \(name) seconds=\(seconds) km=\(route.distanceMeters/1000) dirt=\(q.knownDirtPercent) repeatM=\(q.reriddenMeters) peakFootprintMB=\(ProcessMemory.megabytes().peak)")
    }
}
