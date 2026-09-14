import Foundation
import Testing
@testable import Dirt

@Suite("Bounded complete station spatial coverage")
struct StationCoverageCacheTests {
    private enum Stop: Error { case positive }
    @Test("Completed coverage is unique and reused, while each field is reevaluated")
    func repeatedFields() throws {
        let cache=StationCoverageCache(),owner=NSObject(),index=NSObject()
        var builds=0,seen: [Int]=[]
        func run() throws {
            try cache.enumerate(owner: owner,index: index,latitude: 1,longitude: 2,meters: 550,
                cancelled: { false },visit: { seen.append($0) }) { emit in
                builds += 1
                for edge in [3,1,3,2] { try emit(edge) }
            }
        }
        try run();#expect(seen == [3,1,3,2])
        seen=[];try run();#expect(seen == [1,2,3]);#expect(builds == 1)
        // Different field can find a positive edge in the same coverage.
        #expect(throws: Stop.positive) {
            try cache.enumerate(owner: owner,index: index,latitude: 1,longitude: 2,meters: 550,
                cancelled: { false },visit: { if $0 == 2 { throw Stop.positive } }) { _ in Issue.record("Unexpected rescan") }
        }
    }
    @Test("Positive short circuit and cancellation cannot publish incomplete coverage")
    func partial() throws {
        let cache=StationCoverageCache(),owner=NSObject(),index=NSObject()
        #expect(throws: Stop.positive) {
            try cache.enumerate(owner: owner,index: index,latitude: 1,longitude: 2,meters: 550,
                cancelled: { false },visit: { _ in throw Stop.positive }) { emit in try emit(1);try emit(2) }
        }
        var rescanned=false,seen: [Int]=[]
        try cache.enumerate(owner: owner,index: index,latitude: 1,longitude: 2,meters: 550,
            cancelled: { false },visit: { seen.append($0) }) { emit in rescanned=true;try emit(1);try emit(2) }
        #expect(rescanned);#expect(seen == [1,2])
        #expect(throws: RoutingPageError.cancelled) {
            try cache.enumerate(owner: owner,index: index,latitude: 1,longitude: 2,meters: 550,
                cancelled: { true },visit: { _ in Issue.record("Cancelled hit visited a candidate") }) { _ in Issue.record("Unexpected build") }
        }
    }
    @Test("Radius and index identity are exact cache boundaries")
    func identity() throws {
        let cache=StationCoverageCache(),owner=NSObject(),a=NSObject(),b=NSObject()
        var builds=0
        for (index,radius) in [(a,550.0),(a,2000.0),(b,550.0)] {
            try cache.enumerate(owner: owner,index: index,latitude: 1,longitude: 2,meters: radius,
                cancelled: { false },visit: { _ in }) { emit in builds += 1;try emit(1) }
        }
        #expect(builds == 3)
    }
    @Test("Oversized coverage remains complete but is not retained")
    func cap() throws {
        var limits=StationCoverageCache.Limits();limits.maximumEntryEdges=2
        let cache=StationCoverageCache(limits: limits),owner=NSObject(),index=NSObject()
        var builds=0
        for _ in 0..<2 {
            var seen: [Int]=[]
            try cache.enumerate(owner: owner,index: index,latitude: 1,longitude: 2,meters: 550,
                cancelled: { false },visit: { seen.append($0) }) { emit in
                builds += 1;for edge in 0..<3 { try emit(edge) }
            }
            #expect(seen == [0,1,2])
        }
        #expect(builds == 2)
    }
    @Test("Cached edge IDs do not keep regional pack or index owners alive")
    func weakOwners() throws {
        let cache=StationCoverageCache()
        var owner: NSObject?=NSObject(),index: NSObject?=NSObject()
        weak var weakOwner=owner
        weak var weakIndex=index
        try cache.enumerate(owner: owner!,index: index!,latitude: 1,longitude: 2,meters: 550,
            cancelled: { false },visit: { _ in }) { emit in try emit(1) }
        owner=nil;index=nil
        #expect(weakOwner == nil);#expect(weakIndex == nil)
    }
}
