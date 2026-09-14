import Foundation
import CoreLocation
import Testing
@testable import Dirt

struct NativeRideSurfaceContextTests {
    private func leg(_ meters: Double, _ leaf: String?, coarse: String = "unknown",
                     id: String = "road", structure: String? = nil) -> OnDeviceRouter.Leg {
        OnDeviceRouter.Leg(coordinates: [], distanceMeters: meters, surfaceName: coarse,
            edgeId: id, surfaceLeaf: leaf, structureType: structure)
    }
    @Test func clippedTraversalAmountsStayExactAndUnknownNeverBecomesDirt() throws {
        let value = try #require(NativeRideSurfaceContext.localContribution(legs: [
            leg(0.125, "gravel"), leg(17.375, "dirt"), leg(20.25, "asphalt"),
            leg(5.5, nil, coarse: "paved"), leg(7, "asphalt", structure: "ferry"),
            leg(2.75, "dirt", id: "soft-stitch-end"),
            leg(1, "gravel", id: "perm-stitch-junction")], hasSurfaceLeaves: true))
        #expect(value.knownUnpavedMeters == 17.5)
        #expect(value.pavedMeters == 20.25 && value.unknownMeters == 5.5)
        #expect(value.ferryMeters == 7 && value.stitchMeters == 3.75)
        #expect(value.totalMeters == 54)
        let roundTrip = try JSONDecoder().decode(NativeRideSurfaceContext.self,
            from: JSONEncoder().encode(value))
        #expect(roundTrip == value)
    }
    @Test func addingLocalContributionsDoesNotDuplicateInheritedPrefix() throws {
        let a = try #require(NativeRideSurfaceContext.localContribution(legs: [leg(12.5,"gravel")], hasSurfaceLeaves: true))
        let b = try #require(NativeRideSurfaceContext.localContribution(legs: [leg(3.25,"asphalt"),leg(1,nil)], hasSurfaceLeaves: true))
        let sum = try #require(a.adding(b))
        #expect(sum.totalMeters == 16.75 && sum.knownUnpavedMeters == 12.5)
        #expect(sum.pavedMeters == 3.25 && sum.unknownMeters == 1)
    }
    @Test func concatenationPreservesEachPacksLeafAuthority() throws {
        func result(_ row: OnDeviceRouter.Leg, leaves: Bool) -> OnDeviceRouter.Result {
            OnDeviceRouter.Result(coordinates: [
                CLLocationCoordinate2D(latitude: 45, longitude: -63),
                CLLocationCoordinate2D(latitude: 45.01, longitude: -63)],
                distanceMeters: row.distanceMeters, edgeIds: [row.edgeId], legs: [row],
                dirtPercent: 0, pavedPercent: 0, unknownAccessPercent: 0,
                reportedDirtPercent: 0, reportedPavedPercent: 0, unknownSurfacePercent: 0,
                hasSurfaceLeaves: leaves)
        }
        // V4 untagged remains unknown even when a legacy hop lacks leaves.
        let first = result(leg(5,nil,coarse: "paved"),leaves: true)
        let second = result(leg(10,nil,coarse: "gravel"),leaves: false)
        let combined = try #require(OnDeviceRouter.Result.concatenating([first,second]))
        let value = try #require(combined.localSurfaceContribution)
        #expect(value.totalMeters == 15 && value.knownUnpavedMeters == 10)
        #expect(value.unknownMeters == 5 && value.pavedMeters == 0)
    }
    @Test func explicitUnavailableHopCannotBeReclassifiedDuringMixedConcatenation() throws {
        func hop(leaves: Bool) -> OnDeviceRouter.Result {
            .init(coordinates: [.init(latitude: 45,longitude: -63),.init(latitude: 45.01,longitude: -63)],
                distanceMeters: 10,edgeIds: ["road"],legs: [leg(10,nil,coarse: "paved")],
                dirtPercent: 0,pavedPercent: 100,unknownAccessPercent: 0,
                reportedDirtPercent: 0,reportedPavedPercent: 100,unknownSurfacePercent: 0,
                hasSurfaceLeaves: leaves)
        }
        var unavailable = hop(leaves: true)
        unavailable.aggregatedSurfaceContribution = .unavailable
        let combined = try #require(OnDeviceRouter.Result.concatenating([unavailable,hop(leaves: false)]))
        #expect(combined.localSurfaceContribution == nil)
        let nested = try #require(OnDeviceRouter.Result.concatenating([combined,hop(leaves: true)]))
        #expect(nested.localSurfaceContribution == nil)
        #expect(nested.distanceMeters == 30)
    }
    @Test func scoredNumeratorCannotExceedTraversalTotalOrDestroyKnownSurfaceFacts() throws {
        #expect(NativeRideSurfaceContext(pavedMeters: 0,gravelMeters: 100,looseMeters: 0,
            unknownMeters: 0,ferryMeters: 0,stitchMeters: 0,nativeScoredDirtMeters: 100.01) == nil)
        let exact = try #require(NativeRideSurfaceContext.localContribution(legs: [leg(100,"gravel")],hasSurfaceLeaves: true))
        let withheld = try #require(exact.withNativeScoredDirtMeters(110))
        #expect(withheld.knownUnpavedMeters == 100 && withheld.nativeScoredDirtMeters == nil)
        let roundoff = try #require(exact.withNativeScoredDirtMeters(100.0.nextUp))
        #expect(roundoff.nativeScoredDirtMeters == 100.0.nextUp)
        let invalid = Data(#"{"pavedMeters":0,"gravelMeters":100,"looseMeters":0,"unknownMeters":0,"ferryMeters":0,"stitchMeters":0,"nativeScoredDirtMeters":101}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NativeRideSurfaceContext.self,from: invalid) }
    }
    @Test func oldSavedResponseRemainsAbsentRatherThanInventingExactMeters() throws {
        let old = Data(#"{"status":"complete","distanceMeters":100,"dirtPercent":50}"#.utf8)
        let response = try JSONDecoder().decode(RouteResponse.self,from: old)
        #expect(response.localSurfaceContribution == nil)
        #expect(response.distanceMeters == 100)
    }
    @Test func invalidDistanceIsUnavailableAndLegacyUnknownStaysUnknown() throws {
        #expect(NativeRideSurfaceContext.localContribution(legs: [leg(-1,"dirt")],hasSurfaceLeaves: true) == nil)
        let value = try #require(NativeRideSurfaceContext.localContribution(legs: [leg(5,nil)],hasSurfaceLeaves: false))
        #expect(value.unknownMeters == 5 && value.knownUnpavedMeters == 0 && value.pavedMeters == 0)
    }
}
