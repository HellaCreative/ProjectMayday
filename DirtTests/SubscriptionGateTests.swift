import Testing
@testable import Dirt

@Suite("DIRT PRO feature gates")
@MainActor
struct SubscriptionGateTests {
    @Test("Local route saves stay free")
    func localSaveNeverPresentsPaywall() {
        let gate = makeGate(freeStartsUsed: TrialGateModel.freeStartAllowance)

        #expect(gate.requestSave())
        #expect(gate.presentation == nil)
        #expect(gate.pendingReason == nil)
    }

    @Test("GPX export requires an active subscription")
    func exportPresentsSoftPaywall() {
        let gate = makeGate()

        #expect(!gate.requestExport())
        #expect(gate.presentation == .soft)
        #expect(gate.pendingReason == .export)
        #expect(gate.dismissMessage() == "Subscribe to export GPX")
    }

    @Test("Two navigation starts are free, then Start is gated")
    func navigationAllowanceIsConsumedOnlyWhenRideBegins() {
        var persisted: [Int] = []
        let gate = makeGate { persisted.append($0) }

        #expect(gate.requestStart())
        #expect(gate.freeStartsRemaining == 2)

        gate.consumeFreeStartIfNeeded()
        #expect(gate.freeStartsRemaining == 1)
        #expect(gate.requestStart())

        gate.consumeFreeStartIfNeeded()
        #expect(gate.freeStartsRemaining == 0)
        #expect(!gate.requestStart())
        #expect(gate.presentation == .soft)
        #expect(gate.pendingReason == .start)
        #expect(persisted == [1, 2])
    }

    @Test("Subscribers bypass export and navigation gates")
    func subscriptionUnlocksPaidActions() {
        let gate = makeGate(freeStartsUsed: TrialGateModel.freeStartAllowance)
        gate.markSubscribed()

        #expect(gate.requestSave())
        #expect(gate.requestExport())
        #expect(gate.requestStart())
        #expect(gate.presentation == nil)
        #expect(gate.pendingReason == nil)
    }

    @Test("Tester unlock is impossible without debug or explicit pre-release opt-in")
    func testerUnlockBuildPolicy() {
        #expect(!BuildChannel.testerUnlockAllowed(debugBuild: false, preReleaseOptIn: false))
        #expect(BuildChannel.testerUnlockAllowed(debugBuild: true, preReleaseOptIn: false))
        #expect(BuildChannel.testerUnlockAllowed(debugBuild: false, preReleaseOptIn: true))
    }

    private func makeGate(
        freeStartsUsed: Int = 0,
        persist: @escaping (Int) -> Void = { _ in }
    ) -> TrialGateModel {
        TrialGateModel(
            initialFreeStartsUsed: freeStartsUsed,
            persistFreeStarts: persist
        )
    }
}
