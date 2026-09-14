import CoreLocation
import Testing
@testable import Dirt

@Suite("Native fallback warning conversion")
struct NativeRouteWarningsTests {
    private func fixture(_ meta: OnDeviceRouter.SearchMeta) -> OnDeviceRouter.Result {
        var result = OnDeviceRouter.Result(coordinates: [.init(latitude: 44,longitude: -63)],
            distanceMeters: 1000,edgeIds: [],legs: [],dirtPercent: 15,pavedPercent: 71,
            unknownAccessPercent: 0,reportedDirtPercent: 15,reportedPavedPercent: 71,unknownSurfacePercent: 14)
        result.searchMeta = meta
        return result
    }
    @Test func allFlagCombinationsReachActualNativeResponse() {
        for bits in 0..<16 {
            var meta = OnDeviceRouter.SearchMeta()
            meta.timedOut = bits & 1 != 0
            meta.urbanCoreFallbackUsed = bits & 2 != 0
            meta.cleanUnpavedFallbackUsed = bits & 4 != 0
            meta.settlementFallbackUsed = bits & 8 != 0
            let local = fixture(meta), response = RouteResponse(onDevice: local,priorEdgeIDs: [])
            let codes = response.warnings?.compactMap(\.code) ?? []
            #expect(codes.contains("route_search_limited") == meta.timedOut)
            #expect(codes.contains("urban_core_fallback") == meta.urbanCoreFallbackUsed)
            #expect(codes.contains("clean_unpaved_fallback") == meta.cleanUnpavedFallbackUsed)
            #expect(codes.contains("settlement_fallback") == meta.settlementFallbackUsed)
            #expect(response.debug?.searchMeta?.cleanUnpavedFallbackUsed == meta.cleanUnpavedFallbackUsed)
            #expect(response.stats?.dirtPercent == 15)
            #expect(response.stats?.unknownSurfacePercent == 14)
            if bits == 0 { #expect(response.warnings == nil) } // Percentages never manufacture warnings.
        }
    }
    @Test func existingCustomAndLimitedWarningsSurviveWithoutGeneratedDuplicates() throws {
        var meta = OnDeviceRouter.SearchMeta(timedOut: true)
        meta.cleanUnpavedFallbackUsed = true
        let originals = try #require(meta.routeWarnings())
        let custom = RouteWarning(code: "owner_custom",message: "Keep this warning.")
        let additional = RouteWarning(code: "clean_unpaved_fallback",message: "Distinct existing detail must survive.")
        let existing = [custom]+originals+[additional]
        let response = RouteResponse(onDevice: fixture(meta),priorEdgeIDs: [],existingWarnings: existing)
        let warnings = try #require(response.warnings)
        #expect(warnings.count == existing.count)
        #expect(warnings.map(\.code) == existing.map(\.code))
        #expect(warnings.map(\.message) == existing.map(\.message))
        #expect(response.hasLimitedRouteSearch)
        let customOnly = RouteResponse(onDevice: fixture(.init()),priorEdgeIDs: [],existingWarnings: [custom])
        #expect(customOnly.warnings?.first?.message == custom.message)
    }
}
