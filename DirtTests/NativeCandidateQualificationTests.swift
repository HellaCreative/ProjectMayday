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
            let graph = try PackRepository(installedDirectories: directories).open("on-s").graph
            #expect(!RouteQuality.hasClosedRoadCircuit(route.segments, in: graph))
            verifyShortUnknownConnectors(route)
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
        var firstHash: String?
        for run in 1...2 {
            var request = RoutingRequest(start: .init(longitude: -63.5752, latitude: 44.6488),
                end: .init(longitude: -123.1558, latitude: 49.7016), style: .dirt, allowUnknown: false, seed: 1)
            request.profile.wander = 1; request.profile.avoidMajorHighways = true; request.options.cityWall = true
            let started = ContinuousClock.now
            let route = try await session.route(request, directories: directories)
            #expect(route.limit == nil)
            #expect(route.end.coordinate.distance(to: request.end) <= 250)
            verifyShortUnknownConnectors(route)
            let hash = SHA256.hash(data: Data((route.segments.map(\.edgeID).joined(separator: "\n") + "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            if let firstHash { #expect(hash == firstHash) } else { firstHash = hash }
            #expect(RouteQuality(route: route).knownDirtPercent >= 70)
            #expect(RouteQuality(route: route).reriddenMeters == 0)
            #expect(ProcessMemory.megabytes().peak < 1_300)
            report("canada-\(run)", started: started, route: route)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func ownerHalifaxStStephenRespectsUnknownConnectorSetting() async throws {
        let directories = Dictionary(uniqueKeysWithValues: ["ns", "nb"].map { ($0, root.appendingPathComponent($0)) })
        let session = NativeRoutingSession()
        for unknown in [false, true] {
            let req = RidePreferenceContext.$current.withValue(
                .init(wander: 1, avoidCities: true, avoidHighways: true)) {
                RouteRequest(profile: .dirt, locations: [
                    .init(latitude: 44.696743, longitude: -63.485973, label: "Owner start"),
                    .init(latitude: 45.213841, longitude: -67.296321, label: "St Stephen")
                ], allowUnknown: unknown, sessionSeed: 1, matchLimitMeters: 250)
            }
            let native = try NativeRoutingAdapter.request(req)
            let started = ContinuousClock.now
            let route = try await session.route(native, directories: directories)
            #expect(route.limit == nil)
            #expect(route.end.coordinate.distance(to: native.end) <= 250)
            #expect(route.segments.allSatisfy { $0.access != 2 && $0.access != 5 })
            let uncertainMeters = route.segments.filter { $0.access == 1 }.reduce(0) { $0+$1.meters }
            #expect(uncertainMeters > 0)
            if !unknown { verifyShortUnknownConnectors(route) }
            let response = NativeRoutingAdapter.response(route, style: .dirt)
            #expect(response.segments?.contains { $0.accessClass == "motorized_unknown" } == true)
            report("owner-nsnb-unknown-\(unknown)", started: started, route: route)
        }
    }

    // Audit the returned itinerary, including joins, independently of search labels.
    private func verifyShortUnknownConnectors(_ route: ComputedRoute) {
        var run = 0.0
        var previous: UInt8?
        for segment in route.segments where segment.meters > 0.01 {
            #expect(segment.access != 2 && segment.access != 5)
            if segment.access == 1 {
                if run == 0 { #expect(previous == 0) }
                run += segment.meters
                #expect(run <= 100)
            } else {
                if run > 0 { #expect(segment.access == 0) }
                run = 0
            }
            previous = segment.access
        }
        #expect(run == 0)
    }

    private func report(_ name: String, started: ContinuousClock.Instant, route: ComputedRoute) {
        let d = started.duration(to: .now).components
        let seconds = Double(d.seconds) + Double(d.attoseconds) / 1e18
        let q = RouteQuality(route: route)
        print("CANDIDATE \(name) seconds=\(seconds) km=\(route.distanceMeters/1000) dirt=\(q.knownDirtPercent) repeatM=\(q.reriddenMeters) nearbyReturnM=\(q.returnMeters) peakFootprintMB=\(ProcessMemory.megabytes().peak)")
    }
}
