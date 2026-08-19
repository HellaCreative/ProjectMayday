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
        #expect(dirtPaved / balancedPaved < 15)
        #expect(dirtTrack < balancedTrack)
        #expect(dirtPaved / dirtTrack > 20)
    }

    @Test func directPrefersDirtOnTheLineNotDirtHuntPrices() {
        let directPaved = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .direct, surfaceCode: 0, roadClassCode: 4
        )
        let dirtPaved = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .dirt, surfaceCode: 0, roadClassCode: 4
        )
        let directTrack = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .direct, surfaceCode: 3, roadClassCode: 8
        )
        let dirtTrack = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .dirt, surfaceCode: 3, roadClassCode: 8
        )
        let directAway = OnDeviceProfileCosts.approachAwayExtra(
            profile: .direct,
            dFromMeters: 200_000,
            dToMeters: 210_000,
            abMeters: 400_000
        )
        let dirtAway = OnDeviceProfileCosts.approachAwayExtra(
            profile: .dirt,
            dFromMeters: 200_000,
            dToMeters: 210_000,
            abMeters: 400_000
        )
        #expect(directPaved < dirtPaved / 3)
        #expect(directTrack > dirtTrack * 8)
        #expect(directPaved / directTrack > 1.1)
        #expect(directPaved / directTrack < 4)
        #expect(directAway > dirtAway * 3)
    }

    @Test func corridorCrossTrackTaxesOffLineArcsForAdventureProfiles() {
        let a = CLLocationCoordinate2D(latitude: 49.73269, longitude: -123.13511)
        let b = CLLocationCoordinate2D(latitude: 50.46739, longitude: -119.14172)
        let onLine = CLLocationCoordinate2D(latitude: 50.1, longitude: -121.14)
        let farNorth = CLLocationCoordinate2D(latitude: 51.4, longitude: -121.14)
        let near = OnDeviceProfileCosts.corridorCrossTrackExtra(
            profile: .direct, point: onLine, lineFrom: a, lineTo: b, edgeMeters: 1000
        )
        let farDirect = OnDeviceProfileCosts.corridorCrossTrackExtra(
            profile: .direct, point: farNorth, lineFrom: a, lineTo: b, edgeMeters: 1000
        )
        let farBalanced = OnDeviceProfileCosts.corridorCrossTrackExtra(
            profile: .balanced, point: farNorth, lineFrom: a, lineTo: b, edgeMeters: 1000
        )
        let farDirt = OnDeviceProfileCosts.corridorCrossTrackExtra(
            profile: .dirt, point: farNorth, lineFrom: a, lineTo: b, edgeMeters: 1000
        )
        let farClean = OnDeviceProfileCosts.corridorCrossTrackExtra(
            profile: .cleanest, point: farNorth, lineFrom: a, lineTo: b, edgeMeters: 1000
        )
        #expect(farDirect > near * 8)
        #expect(farDirect > farBalanced)
        #expect(farBalanced > farDirt)
        #expect(farDirt > 8)
        #expect(farClean == 0)
        let xt = abs(GeoMath.crossTrackMeters(point: farNorth, lineFrom: a, to: b))
        #expect(xt > 40_000)
    }

    @Test func balancedPavedBiasCheapensPavementOnly() {
        let paved = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .balanced, surfaceCode: 0, roadClassCode: 4, pavedBias: 1
        )
        let cheaperPaved = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .balanced, surfaceCode: 0, roadClassCode: 4, pavedBias: 0.7
        )
        let track = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .balanced, surfaceCode: 3, roadClassCode: 8, pavedBias: 1
        )
        let trackBiased = OnDeviceProfileCosts.edgeCostPerKm(
            profile: .balanced, surfaceCode: 3, roadClassCode: 8, pavedBias: 0.7
        )
        #expect(cheaperPaved < paved)
        #expect(abs(cheaperPaved / paved - 0.7) < 0.001)
        #expect(trackBiased == track)
    }

    @Test func cleanCityGridIsCostlierUntilNearB() {
        let far = OnDeviceProfileCosts.cleanCityStreetMult(
            profile: .cleanest,
            roadClassCode: 4, // local
            distanceToDestinationMeters: 20_000
        )
        let near = OnDeviceProfileCosts.cleanCityStreetMult(
            profile: .cleanest,
            roadClassCode: 4,
            distanceToDestinationMeters: 800
        )
        let dirtIgnores = OnDeviceProfileCosts.cleanCityStreetMult(
            profile: .dirt,
            roadClassCode: 4,
            distanceToDestinationMeters: 20_000
        )
        #expect(far > 2)
        #expect(near == 1)
        #expect(dirtIgnores == 1)
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

    @Test func dirtAwayPenaltyIsSoftUntilTheLastCoupleKm() {
        let mid = OnDeviceProfileCosts.approachAwayExtra(
            profile: .dirt,
            dFromMeters: 200_000,
            dToMeters: 210_000,
            abMeters: 400_000
        )
        let near = OnDeviceProfileCosts.approachAwayExtra(
            profile: .dirt,
            dFromMeters: 800,
            dToMeters: 10_800,
            abMeters: 400_000
        )
        let stillHuntingAtTenKm = OnDeviceProfileCosts.approachAwayExtra(
            profile: .dirt,
            dFromMeters: 10_000,
            dToMeters: 20_000,
            abMeters: 400_000
        )
        let balancedMid = OnDeviceProfileCosts.approachAwayExtra(
            profile: .balanced,
            dFromMeters: 200_000,
            dToMeters: 210_000,
            abMeters: 400_000
        )
        #expect(mid < 20)
        #expect(stillHuntingAtTenKm < 20)
        #expect(near > mid)
        #expect(near < 25)
        #expect(mid < balancedMid)
    }

    @Test func majorHighwaysStayAvoidedUntilNearAPinnedHighway() {
        let cleanFar = OnDeviceProfileCosts.majorHighwayAvoidMult(
            profile: .cleanest,
            roadClassCode: 1,
            metersFromStart: 80_000,
            metersToDestination: 80_000,
            startOnMajorHighway: false,
            endOnMajorHighway: true
        )
        let cleanNearB = OnDeviceProfileCosts.majorHighwayAvoidMult(
            profile: .cleanest,
            roadClassCode: 1,
            metersFromStart: 80_000,
            metersToDestination: 800,
            startOnMajorHighway: false,
            endOnMajorHighway: true
        )
        let cleanNearBButPinOffHighway = OnDeviceProfileCosts.majorHighwayAvoidMult(
            profile: .cleanest,
            roadClassCode: 1,
            metersFromStart: 80_000,
            metersToDestination: 800,
            startOnMajorHighway: false,
            endOnMajorHighway: false
        )
        let localFar = OnDeviceProfileCosts.majorHighwayAvoidMult(
            profile: .cleanest,
            roadClassCode: 4,
            metersFromStart: 80_000,
            metersToDestination: 80_000,
            startOnMajorHighway: false,
            endOnMajorHighway: true
        )
        #expect(cleanFar > 10)
        #expect(cleanNearB == 1)
        #expect(cleanNearBButPinOffHighway > 10)
        #expect(localFar == 1)
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
