import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct OnDeviceProfileCostsTests {
    @Test func dirtPavedIsCostlierThanBalancedButNotAConnectorWall() {
        let dirtPaved = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .dirt, surfaceCode: 0, roadClassCode: 4
        )
        let balancedPaved = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .balanced, surfaceCode: 0, roadClassCode: 4
        )
        let dirtTrack = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .dirt, surfaceCode: 3, roadClassCode: 8
        )
        let balancedTrack = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .balanced, surfaceCode: 3, roadClassCode: 8
        )
        #expect(dirtPaved > balancedPaved)
        #expect(dirtPaved / balancedPaved < 6)
        #expect(dirtTrack < balancedTrack)
        #expect(dirtPaved / dirtTrack > 20)
    }

    @Test func directHighwayStaysNearCleanNotDirt() {
        let directFreeway = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .direct, surfaceCode: 0, roadClassCode: 1
        )
        let cleanFreeway = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .cleanest, surfaceCode: 0, roadClassCode: 1
        )
        let dirtFreeway = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .dirt, surfaceCode: 0, roadClassCode: 1
        )
        #expect(abs(directFreeway - cleanFreeway) < abs(directFreeway - dirtFreeway))
        #expect(dirtFreeway > directFreeway * 4)
    }

    @Test func untaggedHighwayPaintsAsPavedNotDirt() {
        let arterial = OnDeviceProfileCosts.riderPaintSurface(
            surfaceName: "unknown", roadClassName: "arterial"
        )
        let local = OnDeviceProfileCosts.riderPaintSurface(
            surfaceName: "unknown", roadClassName: "local"
        )
        let track = OnDeviceProfileCosts.riderPaintSurface(
            surfaceName: "unknown", roadClassName: "track"
        )
        let gravel = OnDeviceProfileCosts.riderPaintSurface(
            surfaceName: "gravel", roadClassName: "local"
        )
        #expect(arterial == "paved")
        #expect(local == "paved")
        #expect(track == "unknown")
        #expect(gravel == "gravel")
        #expect(!OnDeviceProfileCosts.isAdventureSurface(arterial))
        #expect(OnDeviceProfileCosts.isAdventureSurface("gravel"))
        #expect(!OnDeviceProfileCosts.isAdventureSurface("unknown"))
    }

    @Test func untaggedHighwayCostsAsPavedOnDirt() {
        let unknownArterial = OnDeviceProfileCosts.surfaceWeight(
            profile: .dirt, surfaceCode: 4, roadClassCode: 2
        )
        let pavedArterial = OnDeviceProfileCosts.surfaceWeight(
            profile: .dirt, surfaceCode: 0, roadClassCode: 2
        )
        let unknownLocal = OnDeviceProfileCosts.surfaceWeight(
            profile: .dirt, surfaceCode: 4, roadClassCode: 4
        )
        let pavedLocal = OnDeviceProfileCosts.surfaceWeight(
            profile: .dirt, surfaceCode: 0, roadClassCode: 4
        )
        #expect(unknownArterial == pavedArterial)
        #expect(unknownLocal == pavedLocal)
    }

    @Test func dirtAwayPenaltyIsSoftUntilTheLastTwelveKm() {
        let mid = OnDeviceProfileCosts.approachAwayExtra(
            profile: .dirt,
            dFromMeters: 200_000,
            dToMeters: 210_000,
            abMeters: 400_000
        )
        let near = OnDeviceProfileCosts.approachAwayExtra(
            profile: .dirt,
            dFromMeters: 4_000,
            dToMeters: 14_000,
            abMeters: 400_000
        )
        let balancedMid = OnDeviceProfileCosts.approachAwayExtra(
            profile: .balanced,
            dFromMeters: 200_000,
            dToMeters: 210_000,
            abMeters: 400_000
        )
        #expect(mid < 1.0)
        #expect(near > mid)
        #expect(mid < balancedMid)
    }

    @Test func dirtLateJoinIsMilderThanBalancedWasRelativeToPavedTax() {
        let dirt = OnDeviceProfileCosts.pavementLateJoinMult(
            profile: .dirt,
            surfaceCode: 0,
            distanceToDestinationMeters: 80_000,
            abMeters: 100_000
        )
        let balanced = OnDeviceProfileCosts.pavementLateJoinMult(
            profile: .balanced,
            surfaceCode: 0,
            distanceToDestinationMeters: 80_000,
            abMeters: 100_000
        )
        #expect(dirt > 1)
        #expect(dirt < 2)
        #expect(balanced > 1)
    }
}

@MainActor
struct CrossPackSeamTests {
    @Test func vancouverCalgarySeamSitsOnTheDivide() {
        let vancouver = CLLocationCoordinate2D(latitude: 49.28, longitude: -123.12)
        let calgary = CLLocationCoordinate2D(latitude: 51.05, longitude: -114.07)
        let seed = CrossPackSeam.seed(from: vancouver, to: calgary, left: "bc", right: "ab")
        #expect(abs(seed.longitude - (-116.4)) < 0.35)
        #expect(seed.latitude > 49.5)
        #expect(seed.latitude < 51.2)
    }

    @Test func bcAbCandidatesIncludeChordAndBorderSamples() {
        let vancouver = CLLocationCoordinate2D(latitude: 49.28, longitude: -123.12)
        let calgary = CLLocationCoordinate2D(latitude: 51.05, longitude: -114.07)
        let seeds = CrossPackSeam.candidates(from: vancouver, to: calgary, left: "bc", right: "ab")
        #expect(seeds.count >= 2)
        #expect(seeds.count <= 5)
        #expect(GraphPackStore.packsShareABorder("bc", "ab"))
    }

    @Test func concatenatingAddsDirtAndPavedMeters() throws {
        let hop1 = OnDeviceRouter.Result(
            coordinates: [
                CLLocationCoordinate2D(latitude: 49.0, longitude: -116.5),
                CLLocationCoordinate2D(latitude: 49.1, longitude: -116.4)
            ],
            distanceMeters: 1000,
            edgeIds: ["a"],
            legs: [
                .init(
                    coordinates: [
                        CLLocationCoordinate2D(latitude: 49.0, longitude: -116.5),
                        CLLocationCoordinate2D(latitude: 49.1, longitude: -116.4)
                    ],
                    distanceMeters: 1000,
                    surfaceName: "gravel",
                    edgeId: "a"
                )
            ],
            dirtPercent: 100,
            pavedPercent: 0,
            unknownAccessPercent: 0
        )
        let hop2 = OnDeviceRouter.Result(
            coordinates: [
                CLLocationCoordinate2D(latitude: 49.1, longitude: -116.4),
                CLLocationCoordinate2D(latitude: 49.2, longitude: -116.3)
            ],
            distanceMeters: 1000,
            edgeIds: ["b"],
            legs: [
                .init(
                    coordinates: [
                        CLLocationCoordinate2D(latitude: 49.1, longitude: -116.4),
                        CLLocationCoordinate2D(latitude: 49.2, longitude: -116.3)
                    ],
                    distanceMeters: 1000,
                    surfaceName: "paved",
                    edgeId: "b"
                )
            ],
            dirtPercent: 0,
            pavedPercent: 100,
            unknownAccessPercent: 0
        )
        let merged = try #require(OnDeviceRouter.Result.concatenating([hop1, hop2]))
        #expect(merged.dirtPercent == 50)
        #expect(merged.pavedPercent == 50)
        #expect(merged.distanceMeters == 2000)
    }

    @Test func osmCoreEdgesExcludeProvincialCapillary() {
        #expect(GraphV2Pack.isOsmCoreEdge("osm-abc"))
        #expect(GraphV2Pack.isOsmCoreEdge("pack-stitch-1"))
        #expect(GraphV2Pack.isProvincialCapillaryEdge("bc-dra-ff"))
        #expect(!GraphV2Pack.isOsmCoreEdge("bc-dra-ff"))
        #expect(!GraphV2Pack.isOsmCoreEdge("ab-access-1"))
        #expect(!GraphV2Pack.isOsmCoreEdge("soft-stitch-x"))
    }
}
