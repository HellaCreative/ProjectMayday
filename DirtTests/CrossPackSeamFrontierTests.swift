import CoreLocation
import Testing
@testable import Dirt

@Suite("Regional seam search frontier")
@MainActor
struct CrossPackSeamFrontierTests {
    private func anchor(_ id: Int) -> GraphV2Pack.CrossPackSeamAnchor {
        .init(neighborRegionId: "nb", longitude: -64, latitude: 45,
            osmWayId: String(id), localEdgeId: "\(id):1:2", remoteEdgeId: "\(id):1:2",
            gapMeters: 0, osmNodeId: Int64(id))
    }

    @Test("Eight unusable approaches do not hide the ninth usable crossing")
    func ninthCrossing() {
        var frontier = CrossPackSeam.CandidateFrontier((1...9).map(anchor))
        var attempts = 0
        var reached: String?
        while reached == nil {
            switch frontier.next(remainingAttempts: 24 - attempts, stopReason: nil) {
            case .candidate(let crossing):
                attempts += 1
                // Simulates exact native approach/exit proofs: the first eight
                // fail, while the ninth is connected. Frontier policy must not
                // substitute its ranking for those proofs.
                if crossing.osmWayId == "9" { reached = crossing.osmWayId }
            case .exhausted:
                Issue.record("A ninth candidate was omitted before its proof ran")
                return
            case .limited(let reason):
                Issue.record("Unexpected limit within the existing 24-attempt budget: \(reason)")
                return
            }
        }
        #expect(reached == "9")
        #expect(attempts == 9)
    }

    @Test("An unexamined crossing at the work limit remains incomplete")
    func workLimitIsNotExhaustion() {
        var frontier = CrossPackSeam.CandidateFrontier((1...9).map(anchor))
        for _ in 0..<8 {
            guard case .candidate = frontier.next(remainingAttempts: 1, stopReason: nil) else {
                Issue.record("Expected the next candidate")
                return
            }
        }
        guard case .limited(let reason) = frontier.next(remainingAttempts: 0, stopReason: nil) else {
            Issue.record("Unexamined seam must produce a work limit, not exhaustion")
            return
        }
        #expect(reason == "regionalSeamWorkLimit")
        #expect(frontier.remainingCount == 1)
        guard case .candidate(let ninth) = frontier.next(remainingAttempts: 1, stopReason: nil) else {
            Issue.record("The limit must not consume its unexamined candidate")
            return
        }
        #expect(ninth.osmWayId == "9")
        guard case .exhausted = frontier.next(remainingAttempts: 0, stopReason: nil) else {
            Issue.record("All candidates were now examined")
            return
        }
    }

    @Test("Cancellation preserves the unexamined frontier")
    func cancellation() {
        var frontier = CrossPackSeam.CandidateFrontier([anchor(1)])
        guard case .limited(let reason) = frontier.next(remainingAttempts: 24, stopReason: "cancelled") else {
            Issue.record("Cancellation must stay incomplete")
            return
        }
        #expect(reason == "cancelled")
        #expect(frontier.remainingCount == 1)
    }

    @Test("Necessary urban crossings remain available to native profile and fallback checks")
    func urbanCrossingNotDiscarded() {
        let point = CLLocationCoordinate2D(latitude: 45, longitude: -64)
        let candidates = CrossPackSeam.candidates(from: point, to: point,
            anchors: [anchor(9)],
            urbanCores: [.init(minLat: 44.99, maxLat: 45.01, minLon: -64.01, maxLon: -63.99, name: "fixture")])
        #expect(candidates.map(\.osmWayId) == ["9"])
    }

    @Test("A failed selected region chain does not prove an alternate chain impossible")
    func alternateChainRemainsUnsearched() {
        #expect(GraphPackStore.hasUnsearchedRegionAlternative(for: ["ns", "nb"],
            allowedRegionIds: ["ns", "nb", "pe"]))
        #expect(!GraphPackStore.hasUnsearchedRegionAlternative(for: ["ns", "nb"],
            allowedRegionIds: ["ns", "nb"]))
        #expect(GraphPackStore.hasUnsearchedRegionAlternative(for: ["ns", "nb", "qc"],
            allowedRegionIds: ["ns", "nb", "qc", "nl"]))
    }
}
