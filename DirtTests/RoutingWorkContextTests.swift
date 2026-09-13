import Foundation
import Testing
@testable import Dirt

struct RoutingWorkContextTests {
    @Test func nestedFuelWindowCannotExtendItsCallerDeadline() throws {
        let outer = ProcessInfo.processInfo.systemUptime + 60
        RoutingWorkContext.$deadline.withValue(outer) {
            #expect(RoutingWorkContext.limitedDeadline(milliseconds: 120_000) == outer)
            #expect(RoutingWorkContext.limitedDeadline(milliseconds: nil) == outer)
        }
        #expect(RoutingWorkContext.deadline == nil)
        RoutingWorkContext.$deadline.withValue(0) {
            do {
                try RoutingWorkContext.check()
                Issue.record("Expired work must not be classified as a completed fuel search")
            } catch RoutingError.fuelUnknown { }
            catch { Issue.record("Unexpected classification: \(error)") }
        }
    }

    @Test func fuelDeadlineReachesDetachedSearch() async {
        let reason = await RoutingWorkContext.$deadline.withValue(0) {
            await RoutingWorkContext.detachedSearch { RoutingWorkContext.stopReason }
        }
        #expect(reason == "fuelWindowTimeCap")
        #expect(RoutingWorkContext.deadline == nil)
    }

    @Test func cancellingCallerStopsDetachedSearch() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let parent = Task {
            await RoutingWorkContext.detachedSearch {
                continuation.yield(())
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline { }
                return Task.isCancelled
            }
        }
        for await _ in stream { break }
        parent.cancel()
        #expect(await parent.value)
        continuation.finish()
    }
}
