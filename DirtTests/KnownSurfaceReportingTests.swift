import Testing
@testable import Dirt

@Suite("Known dirt excludes unknown surface")
struct KnownSurfaceReportingTests {
    @Test("Unknown-only road is not reported as known dirt or known pavement")
    func unknownOnly() {
        let stats = SurfaceFamilyStats.honestPercents(rows: [(1000,nil)],distanceMeters: 1000)
        #expect(stats.dirtPercent == 0)
        #expect(stats.pavedPercent == 0)
        #expect(stats.gravelPercent == 0)
        #expect(stats.unknownSurfacePercent == 100)
    }
    @Test("Mixed aggregate retains exact component distances")
    func mixed() {
        var mix = RouteSurfaceComposition()
        mix.add(meters: 400,family: .paved); mix.add(meters: 200,family: .gravel)
        mix.add(meters: 100,family: .loose); mix.add(meters: 300,family: .unknown)
        #expect(mix.totalMeters == 1000)
        #expect(mix.dirtMeters == 300)
        #expect(mix.dirtPercent == 30)
        #expect(mix.pavedPercent == 40)
        #expect(mix.unknownPercent == 30)
    }
    @Test("Ontario Clean measurement has unknown surface, not a dirt fallback")
    func ontarioObservedComposition() {
        let stats = SurfaceFamilyStats.honestPercents(
            rows: [(291492.3277875351,"asphalt"),(88438,nil)],
            distanceMeters: 379930.3277875351)
        #expect(stats.dirtPercent == 0)
        #expect(stats.pavedPercent == 77)
        #expect(stats.unknownSurfacePercent == 23)
    }
}
