import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Bounded full-edge urban predicate memo")
struct UrbanEdgeMemoTests {
    private let from=CLLocationCoordinate2D(latitude: 0,longitude: 0)
    private let to=CLLocationCoordinate2D(latitude: 10,longitude: 10)
    private var boxes: [UrbanCore.Box] { [.init(minLat: 4,maxLat: 6,minLon: 4,maxLon: 6,name: "fixture")] }
    @Test("True and false proofs are reused within the bound context")
    func values() throws {
        let owner=NSObject(),memo=try #require(UrbanEdgeMemo(owner: owner,from: from,to: to,boxes: boxes))
        var calls=0
        #expect(try memo.value(edge: 1) { calls += 1;return true })
        #expect(try memo.value(edge: 1) { Issue.record("Cache hit recomputed");return false })
        #expect(try !memo.value(edge: 2) { calls += 1;return false })
        #expect(try !memo.value(edge: 2) { Issue.record("Cache hit recomputed");return true })
        #expect(calls == 2)
        #expect(memo.matches(owner: owner,from: from,to: to))
        #expect(!memo.matches(owner: NSObject(),from: from,to: to))
        #expect(!memo.matches(owner: owner,from: to,to: from))
        #expect(memo.payloadBytes <= 1_048_576)
    }
    @Test("Fixed table collisions recompute rather than changing a proof")
    func collision() throws {
        let memo=try #require(UrbanEdgeMemo(owner: NSObject(),from: from,to: to,boxes: boxes,maximumPayloadBytes: 8))
        var calls=0
        #expect(try memo.value(edge: 0) { calls += 1;return true })
        #expect(try !memo.value(edge: 1) { calls += 1;return false })
        #expect(try memo.value(edge: 0) { calls += 1;return true })
        #expect(calls == 3)
        #expect(memo.payloadBytes <= 8)
    }
    @Test("Read errors and cancellation are not cached as urban decisions")
    func errors() throws {
        let memo=try #require(UrbanEdgeMemo(owner: NSObject(),from: from,to: to,boxes: boxes))
        #expect(throws: RoutingPageError.cancelled) {
            _=try memo.value(edge: 7) { throw RoutingPageError.cancelled }
        }
        var computed=false
        #expect(try !memo.value(edge: 7) { computed=true;return false })
        #expect(computed)
    }
    @Test("Endpoint-containing boxes stay exempt and allocate no unused table")
    func exemptions() throws {
        #expect(UrbanEdgeMemo(owner: NSObject(),from: .init(latitude: 5,longitude: 5),to: to,boxes: boxes) == nil)
        #expect(UrbanEdgeMemo(owner: NSObject(),from: from,to: to,boxes: [],maximumPayloadBytes: 8) == nil)
        #expect(UrbanEdgeMemo(owner: NSObject(),from: from,to: to,boxes: boxes,maximumPayloadBytes: 0) == nil)
    }
    @Test("Fallback endpoint geometry remains uncached")
    func noFullGeometry() throws {
        let memo=try #require(UrbanEdgeMemo(owner: NSObject(),from: from,to: to,boxes: boxes))
        var calls=0
        for _ in 0..<2 {
            #expect(try !memo.value(edge: 7,shouldStore: { false }) { calls += 1;return false })
        }
        #expect(calls == 2)
    }

}
