import Foundation
import Testing
@testable import Dirt

struct InitialFuelBoundMemoTests {
    private final class Owner {}
    private func input(source: String = "verified-files", latitude: Double = 1,
        radius: Double = 550, incumbent: Double = 7_000, states: Int = 32_768,
        queue: Int = 65_536, borders: Int = 32_768) -> InitialFuelBoundMemo.Input {
        .init(sourceIdentity: source, origin: .init(latitude: 0, longitude: 0, meters: 0),
            stations: [.init(latitude: latitude, longitude: 2, meters: radius)],
            incumbentMeters: incumbent, maximumStates: states,
            maximumQueueEntries: queue, maximumBorderNodes: borders)
    }
    @Test func exactInputsReuseAndEveryChangedProofInputRecomputes() throws {
        let memo = InitialFuelBoundMemo(), owner = Owner(), index = Owner()
        var calculations = 0, checks = 0
        func read(_ key: InitialFuelBoundMemo.Input) throws -> [Double]? {
            try memo.value(owner: owner, index: index, input: key, validate: { checks += 1 }) {
                calculations += 1; return [100]
            }
        }
        #expect(try read(input()) == [100])
        #expect(try read(input()) == [100])
        #expect(calculations == 1 && checks == 4)
        for changed in [input(source: "changed"), input(latitude: 3), input(radius: 1_000),
            input(incumbent: 6_000), input(states: 1), input(queue: 2), input(borders: 3)] {
            _ = try read(changed)
        }
        #expect(calculations == 8)
        _ = try memo.value(owner: Owner(), index: index, input: input(), validate: {}) { calculations += 1; return [100] }
        #expect(calculations == 9)
    }
    @Test func incompleteResultsAndCancelledOrChangedSourcesNeverProduceCacheHits() throws {
        let memo = InitialFuelBoundMemo(), owner = Owner(), index = Owner()
        var calls = 0
        for _ in 0..<2 {
            #expect(try memo.value(owner: owner, index: index, input: input(), validate: {}) {
                calls += 1; return nil
            } == nil)
        }
        #expect(calls == 2)
        _ = try memo.value(owner: owner, index: index, input: input(), validate: {}) { [100] }
        #expect(throws: CancellationError.self) {
            _ = try memo.value(owner: owner, index: index, input: input(),
                validate: { throw CancellationError() }) { Issue.record("Cancelled hit recomputed"); return [0] }
        }
        #expect(throws: RoutingPageError.sourceChanged) {
            _ = try memo.value(owner: owner, index: index, input: input(),
                validate: { throw RoutingPageError.sourceChanged }) { return [0] }
        }
        var invalidated = false
        #expect(throws: RoutingPageError.sourceChanged) {
            _ = try memo.value(owner: owner, index: index, input: input(source: "replacement"),
                validate: { if invalidated { throw RoutingPageError.sourceChanged } }) {
                invalidated = true; return [200]
            }
        }
        _ = try memo.value(owner: owner, index: index, input: input(source: "replacement"), validate: {}) {
            calls += 1; return [200]
        }
        #expect(calls == 3, "Changed source during computation must not publish")
    }
    @Test func memoDoesNotOwnPackOrIndexAndOversizedInputIsNotRetained() throws {
        let memo = InitialFuelBoundMemo()
        weak var weakOwner: Owner?, weakIndex: Owner?
        do {
            let owner = Owner(), index = Owner(); weakOwner = owner; weakIndex = index
            _ = try memo.value(owner: owner, index: index, input: input(), validate: {}) { [100] }
        }
        #expect(weakOwner == nil && weakIndex == nil)
        let owner = Owner(), index = Owner()
        let key = InitialFuelBoundMemo.Input(sourceIdentity: "files",
            origin: .init(latitude: 0, longitude: 0, meters: 0),
            stations: Array(repeating: .init(latitude: 0, longitude: 0, meters: 1),
                count: InitialFuelBoundMemo.maximumStations + 1),
            incumbentMeters: 100, maximumStates: 10, maximumQueueEntries: 10, maximumBorderNodes: 10)
        var calls = 0
        for _ in 0..<2 {
            _ = try memo.value(owner: owner, index: index, input: key, validate: {}) {
                calls += 1; return Array(repeating: 0, count: key.stations.count)
            }
        }
        #expect(calls == 2)
    }
}
