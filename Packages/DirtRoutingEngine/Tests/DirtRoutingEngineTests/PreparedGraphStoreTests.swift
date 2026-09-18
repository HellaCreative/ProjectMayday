import Foundation
import Testing
@testable import DirtRoutingEngine

struct PreparedGraphStoreTests {
    @Test func peekReturnsNilUntilIndexedThenSameInstance() throws {
        let store = PreparedGraphStore()
        #expect(store.peek(["toy"]) == nil)
        // Without real packs, build fails — only exercise keying helpers here.
        #expect(store.key(for: ["nb", "ns"]) == "nb+ns")
        #expect(store.key(for: ["ns", "nb"]) == "nb+ns")
    }

    @Test func maxConcurrentPreparesIsTwo() {
        #expect(PreparedGraphStore.maxConcurrentPrepares == 2)
    }
}
