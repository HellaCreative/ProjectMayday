import Foundation
import Testing
@testable import Dirt

@MainActor
struct OwningRideSurfacePrefixTests {
    private func contribution(_ gravel: Double,_ paved: Double,_ unknown: Double = 0) -> NativeRideSurfaceContext {
        NativeRideSurfaceContext(pavedMeters: paved,gravelMeters: gravel,looseMeters: 0,
            unknownMeters: unknown,ferryMeters: 0,stitchMeters: 0,nativeScoredDirtMeters: gravel)!
    }
    @Test func fuelSeamAndRewindKeepExactOwnerWhileRiderBoundaryResets() throws {
        let owner = UUID(), nextOwner = UUID()
        let initial = OwningRideSurfacePrefix(riderLegID: owner)
            .appending(contribution(0,500),initialApproach: true)
        #expect(initial.contribution?.totalMeters == 0)
        let checkpoint = initial.appending(contribution(12.125,7.875,3))
        let onward = checkpoint.appending(contribution(0,10))
        #expect(onward.contribution?.totalMeters == 33)
        #expect(onward.contribution?.knownUnpavedMeters == 12.125)
        #expect(onward.contribution?.nativeScoredDirtMeters == 12.125)
        #expect(onward.beginning(owner) == onward)
        #expect(onward.beginning(nextOwner).contribution?.totalMeters == 0)
        // Backtracking restores a value snapshot; the abandoned branch cannot leak.
        let replacement = checkpoint.appending(contribution(5,0))
        #expect(replacement.contribution?.totalMeters == 28)
        let reopened = try JSONDecoder().decode(OwningRideSurfacePrefix.self,
            from: JSONEncoder().encode(replacement))
        #expect(reopened == replacement)
        #expect(checkpoint.appending(nil).contribution == nil)
    }
    @Test func optionsAndCacheIdentityDistinguishSamePinsWithDifferentPrefix() throws {
        let owner = UUID()
        let a = OwningRideSurfacePrefix(riderLegID: owner,contribution: contribution(10,0))
        let b = OwningRideSurfacePrefix(riderLegID: owner,contribution: contribution(0,10))
        let requestA = RouteRequestOptions(owningRideSurfacePrefix: a)
        let requestB = RouteRequestOptions(owningRideSurfacePrefix: b)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(requestA) != encoder.encode(requestB))
        var key = RouteResponseCache.Key(from: .init(longitude: -63,latitude: 45),
            to: .init(longitude: -62,latitude: 45),profile: .balanced,allowUnknown: false,
            avoidEdgeIDs: [],priorEdgeIDs: [],arrivalEdgeID: nil,owningRideSurfacePrefix: a,
            backtrackFactor: 4,sessionSeed: 1,directExtraBudgetMeters: nil,regionalHopMinimumMeters: [],
            sourceName: "pack",packRevision: "verified",cleanMetroMultiplier: nil,
            avoidMotorways: false,preferBackRoads: false,startEndpointKind: nil,endEndpointKind: nil)
        let firstKey = key;key.owningRideSurfacePrefix = b
        #expect(firstKey != key)
        let old = try JSONDecoder().decode(RouteRequestOptions.self,from: Data("{}".utf8))
        #expect(old.owningRideSurfacePrefix == nil)
    }
}
