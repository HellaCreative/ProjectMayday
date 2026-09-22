import Testing
@testable import DirtRoutingEngine
struct GeographicIntersectionOracleTests {
    @Test func scalarClippingMatchesOriginalAcrossDegenerateAndCrossingSegments() {
        let box = GeographicBox(minLat: -3, maxLat: 7, minLon: -5, maxLon: 11, name: "oracle")
        func original(_ a: Coordinate, _ b: Coordinate) -> Bool {
            let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
            var lo = 0.0, hi = 1.0
            for (p,q) in [(-dx,a.longitude-box.minLon), (dx,box.maxLon-a.longitude),
                          (-dy,a.latitude-box.minLat), (dy,box.maxLat-a.latitude)] {
                if p == 0 { if q < 0 { return false }; continue }
                let r = q / p
                if p < 0 { lo = max(lo,r) } else { hi = min(hi,r) }
                if lo > hi { return false }
            }
            return true
        }
        let points = [-20.0, -5, -3, 0, 7, 11, 20]
        for x in points { for y in points { for u in points { for v in points {
            let a = Coordinate(longitude: x, latitude: y), b = Coordinate(longitude: u, latitude: v)
            #expect(box.intersects(a,b) == original(a,b))
        } } } }
        var seed: UInt64 = 814
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 11) / 9007199254740992 * 100 - 50 }
        for _ in 0..<20_000 {
            let a = Coordinate(longitude: random(), latitude: random()), b = Coordinate(longitude: random(), latitude: random())
            #expect(box.intersects(a,b) == original(a,b))
        }
    }
}
