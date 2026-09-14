import Foundation
import Testing
@testable import Dirt

struct RegionalTailRefinementTests {
    private struct Prefix { let meters: Double; let token: String }
    private struct Suffix { let meters: Double; let token: String }
    @Test func actualSuffixReservationRebuildsPrefixAndReprovesChangedArrival() async throws {
        var calls: [String] = [], attempts = 0
        let result = try await RegionalTailRefinement.afterCappedNoPath(
            initial: Prefix(meters: 97,token: "old"), initialApproachCap: 97,availableMeters: 100,
            approachMeters: { $0.meters },tailMeters: { $0.meters }, check: { },consumeAttempt: { attempts += 1; return true },
            approach: { cap in
                #expect(cap == 80);calls.append("approach")
                return .success(Prefix(meters: 79,token: "new"))
            },tail: { prefix,cap in
                calls.append("tail-\(prefix.token)-\(Int(cap))")
                return .success(Suffix(meters: prefix.token == "old" ? 20 : 21,token: prefix.token))
            })
        guard case .completed(let prefix,let tail) = result else { Issue.record("Expected repaired journey");return }
        #expect(prefix.token == "new" && tail.token == "new")
        #expect(prefix.meters+tail.meters == 100)
        #expect(attempts == 1 && calls == ["tail-old-100","approach","tail-new-21"])
    }
    @Test func repeatedCapFailureRefinesOnlyWithProgressWithinSharedQuota() async throws {
        var attempts = 0, tailCalls = 0, caps: [Double] = []
        let result = try await RegionalTailRefinement.afterCappedNoPath(
            initial: Prefix(meters: 99,token: "a"), initialApproachCap: 99,availableMeters: 100,
            approachMeters: { $0.meters },tailMeters: { $0.meters },check: {},
            consumeAttempt: { guard attempts < 2 else { return false };attempts += 1;return true },
            approach: { cap in caps.append(cap);return .success(Prefix(meters: cap,token: "b")) },
            tail: { _,cap in
                tailCalls += 1
                return cap == 100 ? .success(Suffix(meters: Double(attempts*10),token: "b")) : .noPath
            })
        guard case .incomplete(let reason) = result else { Issue.record("Must stop at shared quota");return }
        #expect(reason == "regionalSeamWorkLimit" && attempts == 2 && tailCalls == 4 && caps == [90,80])
    }
    @Test func limitedProbeAndNoProgressNeverBecomeAbsenceOrConsumeStaleProof() async throws {
        for limited in [true,false] {
            var approaches = 0
            let result = try await RegionalTailRefinement.afterCappedNoPath(
                initial: Prefix(meters: 90,token: "a"),initialApproachCap: 90,availableMeters: 100,
                approachMeters: { $0.meters },tailMeters: { $0.meters },check: {},consumeAttempt: { true },
                approach: { _ in approaches += 1;return .noPath },
                tail: { _,_ in limited ? .incomplete("fuelWindowTimeCap") : .success(Suffix(meters: 5,token: "a")) })
            guard case .incomplete(let reason) = result else { Issue.record("Must remain unproved");return }
            #expect(reason == (limited ? "fuelWindowTimeCap" : "regionalTailRefinementNoProgress"))
            #expect(approaches == 0)
        }
    }
    @Test func sourceChangeOrCancellationAfterAwaitCannotPublishAndDeadlineIsNotRenewed() async throws {
        enum Stopped: Error { case sourceChanged, cancelled }
        for cancelled in [false,true] {
            var changed = false, checks = 0, approaches = 0
            do {
                _ = try await RegionalTailRefinement.afterCappedNoPath(
                    initial: Prefix(meters: 99,token: "a"),initialApproachCap: 99,availableMeters: 100,
                    approachMeters: { $0.meters },tailMeters: { $0.meters },check: {
                        checks += 1
                        if changed { throw cancelled ? Stopped.cancelled : Stopped.sourceChanged }
                    },consumeAttempt: { true },approach: { _ in approaches += 1;return .noPath },
                    tail: { _,_ in changed = true;return .success(Suffix(meters: 20,token: "a")) })
                Issue.record("Changed calculation returned a proof")
            } catch is Stopped {}
            #expect(checks == 2 && approaches == 0)
        }
    }
}
