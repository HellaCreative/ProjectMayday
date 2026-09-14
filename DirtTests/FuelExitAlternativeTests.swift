import CoreLocation
import Foundation
import Testing
@testable import Dirt

@MainActor
struct FuelExitAlternativeTests {
    private let station = RouteCoordinate(longitude: -0.0025, latitude: 0)
    private let end = RouteCoordinate(longitude: 0.025, latitude: 0)
    private func native() throws -> (OnDeviceRouter, OnDeviceRouter.Result, OnDeviceRouter.Result, Set<String>) {
        func bytes(_ suffix: String) throws -> Data {
            let name = "initial-distance-plain" + suffix
            let bundle = Bundle(for: FuelExitAlternativeBundle.self)
            let url = bundle.url(forResource: name, withExtension: nil)
                ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
            return try Data(contentsOf: url)
        }
        let pack = try GraphV2Pack(data: bytes(".graph.v4.bin"))
        pack.geometry = try GeometryV1Pack(data: bytes(".geometry.v1.bin"))
        var router = try fixtureRouter(pack: pack); router.matchLimitMeters = 20
        router.endEndpointKind = "customers"
        let a = router.routeDetailed(from: .init(latitude: 0, longitude: -0.005),
            to: station.locationCoordinate, profile: .cleanest, allowUnknown: false)
        guard case .success(let approach) = a else { throw FixtureError.failed("\(a)") }
        let token = try #require(approach.terminalContinuation)
        router.startEndpointKind = "customers"; router.endEndpointKind = nil
        let history = Set((0..<pack.undirectedEdgeCount).map { pack.edgeId($0) }.filter { $0.hasPrefix("w20:") })
            .union(approach.edgeIds)
        let r = router.routeDetailed(from: station.locationCoordinate, to: end.locationCoordinate,
            profile: .cleanest, allowUnknown: false, priorEdgeIds: history,
            arrivalContinuation: token, backtrackFactor: 1, sessionSeed: 77, maxRouteMeters: 20_000)
        guard case .success(let exit) = r else { throw FixtureError.failed("\(r)") }
        return (router,approach,exit,history)
    }
    private func repeated(_ route: OnDeviceRouter.Result, _ history: Set<String>) -> Double {
        route.legs.reduce(0) { $0 + (history.contains($1.edgeId) ? $1.distanceMeters : 0) }
    }
    private func request() -> FuelChainRequest {
        .init(profile: .cleanest, from: station, to: end, allowUnknown: false,
            usableRangeMeters: 180_000, firstLegMaxMeters: 180_000,
            requireFuelStopBeforeEnd: false, minimumFuelStops: 0,
            profileMeters: 10_000, riderLegId: "same-leg", sessionSeed: 77)
    }
    @Test func repeatedThroughRoadGetsOneLegalAlternativeWithProtectedEndpointParents() async throws {
        let (router,approach,exit,history) = try native()
        #expect(repeated(exit,history) > 1_000)
        let token = try #require(approach.terminalContinuation)
        var attempts = 0
        let assessment = try await FuelExitAlternative.assess(initial: .success(exit), approach: approach,
            history: history, originalAvoid: ["owner-closed-road"], cap: 20_000, maximumRepeatedMeters: 1_000,
            repeatedMeters: { repeated($0,history) }) { exclusions in
                attempts += 1
                #expect(exclusions.contains("owner-closed-road"))
                #expect(exclusions.contains { $0.hasPrefix("w20:") })
                #expect(!exclusions.contains { $0.hasPrefix("w10:") || $0.hasPrefix("w11:") })
                return router.routeDetailed(from: station.locationCoordinate, to: end.locationCoordinate,
                    profile: .cleanest, allowUnknown: false, avoidEdgeIds: exclusions,
                    priorEdgeIds: history, arrivalContinuation: token, backtrackFactor: 1,
                    sessionSeed: 77, maxRouteMeters: 20_000)
            }
        #expect(attempts == 1)
        guard case .accepted(let selected) = assessment else { Issue.record("Legal alternative missing"); return }
        #expect(selected.edgeIds.contains { $0.hasPrefix("w30:") })
        #expect(repeated(selected,history) <= 1_000)
        #expect(approach.distanceMeters > 0)
    }
    @Test func failedAlternativeRemainsUnprovedAndDoesNotRenewWindow() async throws {
        let (_,approach,exit,history) = try native()
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        var calls = 0
        let assessment = try await RoutingWorkContext.$deadline.withValue(deadline) {
            try await FuelExitAlternative.assess(initial: .success(exit), approach: approach,
                history: history, originalAvoid: [], cap: 20_000, maximumRepeatedMeters: 1_000,
                repeatedMeters: { repeated($0,history) }) { _ in
                    calls += 1; #expect(RoutingWorkContext.deadline == deadline)
                    return .failure(.searchLimit("timeBudget"))
                }
        }
        #expect(calls == 1)
        guard case .unproved("timeBudget") = assessment else { Issue.record("Limited alternative lost classification"); return }
    }
    @Test func builderConnectorSegmentsDoNotInvalidateRoadHistoryProof() throws {
        let (_,approach,exit,history) = try native()
        let token = try #require(approach.terminalContinuation), req = request()
        let record = try #require(try FuelExitReuseRecord(request: req, from: station, to: end,
            arrival: token, history: history, sourceIdentity: "files", route: exit))
        var decoratedApproach = approach
        var stub = try #require(approach.legs.last)
        stub.edgeId = "soft-stitch-end"; stub.distanceMeters = 7
        decoratedApproach.legs.append(stub)
        decoratedApproach.distanceMeters += 7
        let response = RouteResponse(onDevice: decoratedApproach, priorEdgeIDs: [])
        // Reproduce builder EdgeHistory's segment-ID collection, not native
        // Result.edgeIds, which intentionally omits this final access stub.
        let responseHistory = history.union(response.segments?.compactMap(\.edgeId) ?? [])
            .union(["perm-stitch-end"])
        #expect(responseHistory.contains("soft-stitch-end"))
        #expect(response.distanceMeters == approach.distanceMeters + 7)
        #expect(try record.rejection(request: req, from: station, to: end, arrival: token,
            history: responseHistory, sourceIdentity: "files", cap: 20_000) == nil)
        #expect(try record.matching(request: req, from: station, to: end, arrival: token,
            history: responseHistory, sourceIdentity: "files", cap: 20_000)?.distanceMeters == exit.distanceMeters)
        #expect(try record.rejection(request: req, from: station, to: end, arrival: token,
            history: responseHistory.union(["new-real-road"]), sourceIdentity: "files",
            cap: 20_000) == .additionalRoadHistory)
        #expect(try record.rejection(request: req, from: station, to: end, arrival: nil,
            history: responseHistory, sourceIdentity: "files", cap: 20_000) == .arrival)
        #expect(try record.rejection(request: req, from: station, to: end, arrival: token,
            history: responseHistory, sourceIdentity: "replaced", cap: 20_000) == .sourceIdentity)
        var changed = req; changed.options?.sessionSeed = 99
        #expect(try record.rejection(request: changed, from: station, to: end, arrival: token,
            history: responseHistory, sourceIdentity: "files", cap: 20_000) == .settings)
    }
    @Test func continuationIsSingleUseAndInvalidatedByChangedProofContext() throws {
        let (_,approach,exit,history) = try native()
        let token = try #require(approach.terminalContinuation), req = request()
        let record = try #require(try FuelExitReuseRecord(request: req, from: station, to: end,
            arrival: token, history: history, sourceIdentity: "verified-files-A", route: exit))
        let holder = FuelExitReuseHolder(); holder.saved = record
        let taken = try holder.take(request: req, from: station, to: end, arrival: token,
            history: history, sourceIdentity: "verified-files-A", cap: 20_000)
        #expect(taken?.edgeIds == exit.edgeIds && holder.saved == nil)
        #expect(try holder.take(request: req, from: station, to: end, arrival: token,
            history: history, sourceIdentity: "verified-files-A", cap: 20_000) == nil)
        #expect(try record.matching(request: req, from: station, to: end, arrival: nil,
            history: history, sourceIdentity: "verified-files-A", cap: 20_000) == nil)
        #expect(try record.matching(request: req, from: station, to: end, arrival: token,
            history: history, sourceIdentity: "replaced-files-B", cap: 20_000) == nil)
        #expect(try record.matching(request: req, from: station, to: end, arrival: token,
            history: history.union(["newly-traversed"]), sourceIdentity: "verified-files-A", cap: 20_000) == nil)
        #expect(try record.matching(request: req, from: station, to: end, arrival: token,
            history: history, sourceIdentity: "verified-files-A", cap: exit.distanceMeters - 2) == nil)
        var changed = req; changed.options?.sessionSeed = 78
        #expect(try record.matching(request: changed, from: station, to: end, arrival: token,
            history: history, sourceIdentity: "verified-files-A", cap: 20_000) == nil)
        #expect(throws: (any Error).self) {
            try RoutingWorkContext.$deadline.withValue(ProcessInfo.processInfo.systemUptime - 1) {
                _ = try record.matching(request: req, from: station, to: end, arrival: token,
                    history: history, sourceIdentity: "verified-files-A", cap: 20_000)
            }
        }
    }
    @Test func newBuildScopeCannotConsumePriorBuildContinuation() async throws {
        let (_,approach,exit,history) = try native()
        let record = try #require(try FuelExitReuseRecord(request: request(), from: station, to: end,
            arrival: approach.terminalContinuation, history: history, sourceIdentity: "files", route: exit))
        let first = FuelExitReuseHolder(); first.saved = record
        await FuelExitReuseScope.$current.withValue(first) {
            #expect(FuelExitReuseScope.current?.saved != nil)
            await FuelExitReuseScope.$current.withValue(FuelExitReuseHolder()) {
                #expect(FuelExitReuseScope.current?.saved == nil)
            }
            #expect(FuelExitReuseScope.current?.saved != nil)
        }
        #expect(FuelExitReuseScope.current == nil)
    }
    @Test func alternateCannotChangeMatchedParentOrProjectionButNodeIdentityAllowsAnotherIncidentEdge() throws {
        let (_,_,exit,_) = try native()
        #expect(exit.matchedStart != nil && exit.matchedEnd != nil)
        var changed = exit
        changed.matchedEnd = nil
        #expect(!FuelExitAlternative.sameMatchedEndpoints(exit, changed))
        let edge = OnDeviceRouter.MatchedEndpoint(sourceEpoch: "epoch",
            location: .edge(parent: .init(wayID: 10, fromNodeID: 1, toNodeID: 2),
                alongMeters: 20, longitude: 0, latitude: 0))
        var original = exit; original.matchedStart = edge
        changed = original
        changed.matchedStart = .init(sourceEpoch: "epoch",
            location: .edge(parent: .init(wayID: 99, fromNodeID: 1, toNodeID: 2),
                alongMeters: 20, longitude: 0, latitude: 0))
        #expect(!FuelExitAlternative.sameMatchedEndpoints(original, changed), "Nearby/different parent is not a valid alternative")
        changed.matchedStart = .init(sourceEpoch: "epoch",
            location: .edge(parent: .init(wayID: 10, fromNodeID: 1, toNodeID: 2),
                alongMeters: 21, longitude: 0, latitude: 0))
        #expect(!FuelExitAlternative.sameMatchedEndpoints(original, changed))
        original.matchedStart = .init(sourceEpoch: "epoch", location: .node(42))
        changed = original
        if !changed.legs.isEmpty { changed.legs[0].edgeId = "another-incident-road" }
        #expect(FuelExitAlternative.sameMatchedEndpoints(original, changed), "Verified node identity is independent of departure edge")
    }
    @Test func sourceReplacementDuringCalculationCannotBeStampedAsFreshProof() async throws {
        let (_,_,exit,_) = try native()
        var identity = "original", calls = 0
        let invalid = await FuelExitAlternative.calculateBoundExit(expectedIdentity: "original",
            currentIdentity: { identity }) {
                calls += 1; identity = "replacement"; return .success(exit)
            }
        #expect(calls == 1 && invalid.sourceIdentity == nil)
        guard case .failure(.searchLimit("fuelExitSourceChanged")) = invalid.result else {
            Issue.record("Old route was stamped with replacement identity"); return
        }
        let alreadyChanged = await FuelExitAlternative.calculateBoundExit(expectedIdentity: "original",
            currentIdentity: { identity }) { calls += 1; return .success(exit) }
        #expect(calls == 1 && alreadyChanged.sourceIdentity == nil)
        let stable = await FuelExitAlternative.calculateBoundExit(expectedIdentity: "replacement",
            currentIdentity: { identity }) { .success(exit) }
        #expect(stable.sourceIdentity == "replacement")
    }
    private func syntheticExit(_ base: OnDeviceRouter.Result, repeatedID: String) throws -> OnDeviceRouter.Result {
        let roads = base.legs.filter { $0.edgeIndex != nil }
        var route = base
        let first = try #require(roads.first), last = try #require(roads.last)
        var middle = try #require(roads.first(where: { $0.edgeId != first.edgeId && $0.edgeId != last.edgeId }))
        middle.edgeId = repeatedID; middle.distanceMeters = 2_000
        route.legs = [first,middle,last]; route.edgeIds = route.legs.map(\.edgeId)
        route.distanceMeters = route.legs.reduce(0) { $0 + $1.distanceMeters }
        return route
    }
    @Test func successiveObservedRepeatedCorridorsAccumulateExclusionsUntilValid() async throws {
        let (_,approach,base,_) = try native()
        let first = try syntheticExit(base, repeatedID: "repeat-a")
        let otherRepeat = try syntheticExit(base, repeatedID: "repeat-b")
        let valid = try syntheticExit(base, repeatedID: "new-through-road")
        let history: Set<String> = ["repeat-a","repeat-b"]
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        var attempts = 0
        let result = try await RoutingWorkContext.$deadline.withValue(deadline) {
            try await FuelExitAlternative.assess(initial: .success(first), approach: approach,
                history: history, originalAvoid: ["owner-exclusion"], cap: 20_000, maximumRepeatedMeters: 1_000,
                repeatedMeters: { repeated($0,history) }) { exclusions in
                    attempts += 1
                    #expect(RoutingWorkContext.deadline == deadline)
                    #expect(exclusions.contains("owner-exclusion") && exclusions.contains("repeat-a"))
                    if attempts == 1 { #expect(!exclusions.contains("repeat-b")); return .success(otherRepeat) }
                    #expect(exclusions.contains("repeat-b"))
                    return .success(valid)
                }
        }
        #expect(attempts == 2)
        guard case .accepted(let accepted) = result else { Issue.record("Second nonrepeating alternative was not retained"); return }
        #expect(accepted.edgeIds == valid.edgeIds)
    }
    @Test func noNovelExclusionTerminatesAndExpiredWindowNeverRetries() async throws {
        let (_,approach,base,_) = try native()
        let first = try syntheticExit(base, repeatedID: "repeat-a")
        let history: Set<String> = ["repeat-a"]
        var calls = 0
        let outcome = try await FuelExitAlternative.assess(initial: .success(first), approach: approach,
            history: history, originalAvoid: [], cap: 20_000, maximumRepeatedMeters: 1_000,
            repeatedMeters: { repeated($0,history) }) { _ in
                calls += 1; return .success(first)
            }
        #expect(calls == 1)
        guard case .unproved("station_exit_no_novel_exclusions") = outcome else {
            Issue.record("Repeated exclusion set did not terminate"); return
        }
        do {
            _ = try await RoutingWorkContext.$deadline.withValue(ProcessInfo.processInfo.systemUptime - 1) {
                try await FuelExitAlternative.assess(initial: .success(first), approach: approach,
                    history: history, originalAvoid: [], cap: 20_000, maximumRepeatedMeters: 1_000,
                    repeatedMeters: { repeated($0,history) }) { _ in calls += 1; return .success(first) }
            }
            Issue.record("Expired window returned instead of cancellation")
        } catch { #expect(calls == 1) }
    }
    private enum FixtureError: Error { case failed(String) }
}
private final class FuelExitAlternativeBundle: NSObject {}
