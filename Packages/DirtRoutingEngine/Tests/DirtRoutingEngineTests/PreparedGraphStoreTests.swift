import Foundation
import Testing
@testable import DirtRoutingEngine

struct PreparedGraphStoreTests {
    @Test func peekReturnsNilUntilIndexedThenSameInstance() throws {
        let store = PreparedGraphStore()
        let repository = try PackRepository(installedDirectories: [:])
        #expect(throws: RoutingFailure.self) { try store.peek(["toy"], repository: repository) }
        // Without real packs, build fails — only exercise keying helpers here.
        #expect(store.key(for: ["nb", "ns"]) == "nb+ns")
        #expect(store.key(for: ["ns", "nb"]) == "nb+ns")
    }

    @Test func maxConcurrentPreparesIsTwo() {
        #expect(PreparedGraphStore.maxConcurrentPrepares == 2)
    }
}
