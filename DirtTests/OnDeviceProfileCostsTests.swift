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

    @Test func adventureCrossTrackTaxesOffLineArcs() {
        let a = CLLocationCoordinate2D(latitude: 49.73269, longitude: -123.13511)
        let b = CLLocationCoordinate2D(latitude: 50.46739, longitude: -119.14172)
        let onLine = CLLocationCoordinate2D(latitude: 50.1, longitude: -121.14)
        let farNorth = CLLocationCoordinate2D(latitude: 51.4, longitude: -121.14)
        let near = OnDeviceProfileCosts.corridorCrossTrackExtra(
            profile: .balanced, point: onLine, lineFrom: a, lineTo: b, edgeMeters: 1000
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
        #expect(farBalanced > near * 8)
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
        #expect(OnDeviceProfileCosts.isAdventureSurface(track))
    }

    @Test func selectedRoutePaintSeparatesSurfaceFromMotorAccess() {
        let unknownAccessTrail = OnDeviceProfileCosts.selectedRoutePaintKey(
            surfaceName: "unknown",
            roadClassName: "track",
            accessName: "motorized_unknown"
        )
        let permissiveUntaggedTrack = OnDeviceProfileCosts.selectedRoutePaintKey(
            surfaceName: "unknown",
            roadClassName: "track",
            accessName: "motorized_permissive"
        )
        let permissiveResourceRoad = OnDeviceProfileCosts.selectedRoutePaintKey(
            surfaceName: "access",
            roadClassName: "resource",
            accessName: "motorized_permissive"
        )
        let permissiveUntaggedLocal = OnDeviceProfileCosts.selectedRoutePaintKey(
            surfaceName: "unknown",
            roadClassName: "local",
            accessName: "motorized_permissive"
        )
        #expect(unknownAccessTrail == "unknown_access")
        #expect(permissiveUntaggedTrack == "unknown")
        #expect(permissiveResourceRoad == "access")
        #expect(permissiveUntaggedLocal == "paved")
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
        // Forward fan: ~9.5/km mid-ride (×10 in pavement ≈ 95/km).
        #expect(mid > 80)
        #expect(mid < 120)
        #expect(stillHuntingAtTenKm > 80)
        #expect(near > mid)
        #expect(mid < balancedMid)
    }

    @Test func cleanAwayGravityDoesNotDominateExtraPavement() {
        let cleanAway = OnDeviceProfileCosts.approachAwayExtra(
            profile: .cleanest,
            dFromMeters: 20_000,
            dToMeters: 35_000,
            abMeters: 15_000
        )
        let balancedAway = OnDeviceProfileCosts.approachAwayExtra(
            profile: .balanced,
            dFromMeters: 50_000,
            dToMeters: 51_000,
            abMeters: 100_000
        )
        #expect(cleanAway > 0)
        #expect(cleanAway <= 15 * 2.5)
        #expect(cleanAway < 60 * 1.18)
        #expect(balancedAway >= 150)
    }

    @Test func cleanPavementGateBlocksMinorUnknownAndGravel() {
        #expect(OnDeviceProfileCosts.isBlockedForCleanPavement(surfaceName: "paved", roadClassName: "local") == false)
        #expect(OnDeviceProfileCosts.isBlockedForCleanPavement(surfaceName: "unknown", roadClassName: "arterial") == false)
        #expect(OnDeviceProfileCosts.isBlockedForCleanPavement(surfaceName: "unknown", roadClassName: "local") == true)
        #expect(OnDeviceProfileCosts.isBlockedForCleanPavement(surfaceName: "gravel", roadClassName: "collector") == true)
    }

    @Test func cleanMajorHighwayIsFreewayAndRampNotArterial() {
        #expect(OnDeviceProfileCosts.isMajorHighway("freeway", profile: .cleanest))
        #expect(OnDeviceProfileCosts.isMajorHighway("ramp", profile: .cleanest))
        #expect(!OnDeviceProfileCosts.isMajorHighway("arterial", profile: .cleanest))
        #expect(OnDeviceProfileCosts.isMajorHighway("arterial", profile: .balanced))
        #expect(OnDeviceProfileCosts.isMajorHighway("arterial", profile: .dirt))

        let cleanArterial = OnDeviceProfileCosts.majorHighwayAvoidMult(
            profile: .cleanest,
            roadClassCode: 2, // arterial
            metersFromStart: 80_000,
            metersToDestination: 80_000,
            startOnMajorHighway: false,
            endOnMajorHighway: false
        )
        let cleanFreeway = OnDeviceProfileCosts.majorHighwayAvoidMult(
            profile: .cleanest,
            roadClassCode: 1, // freeway
            metersFromStart: 80_000,
            metersToDestination: 80_000,
            startOnMajorHighway: false,
            endOnMajorHighway: false
        )
        let cleanRamp = OnDeviceProfileCosts.majorHighwayAvoidMult(
            profile: .cleanest,
            roadClassCode: 10, // ramp
            metersFromStart: 80_000,
            metersToDestination: 80_000,
            startOnMajorHighway: false,
            endOnMajorHighway: false
        )
        let balancedArterial = OnDeviceProfileCosts.majorHighwayAvoidMult(
            profile: .balanced,
            roadClassCode: 2,
            metersFromStart: 80_000,
            metersToDestination: 80_000,
            startOnMajorHighway: false,
            endOnMajorHighway: false
        )
        let dirtArterial = OnDeviceProfileCosts.majorHighwayAvoidMult(
            profile: .dirt,
            roadClassCode: 2,
            metersFromStart: 80_000,
            metersToDestination: 80_000,
            startOnMajorHighway: false,
            endOnMajorHighway: false
        )
        #expect(cleanArterial == 1)
        #expect(cleanFreeway > 1)
        #expect(cleanRamp > 1)
        #expect(balancedArterial > 1)
        // Dirt arterial is already 9.5× — the extra avoid target does not apply.
        #expect(dirtArterial == 1)
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
        #expect(cleanFar > 2.5)
        #expect(cleanNearB == 1)
        #expect(cleanNearBButPinOffHighway > 2.5)
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
    private func anchor(
        neighbor: String = "ab",
        longitude: Double,
        latitude: Double,
        way: String = "42",
        gap: Double = 0
    ) -> GraphV2Pack.CrossPackSeamAnchor {
        .init(
            neighborRegionId: neighbor,
            longitude: longitude,
            latitude: latitude,
            osmWayId: way,
            localEdgeId: "left",
            remoteEdgeId: "right",
            gapMeters: gap
        )
    }

    @Test func ranksPackAuthoredSeamsByABChord() throws {
        let vancouver = CLLocationCoordinate2D(latitude: 49.28, longitude: -123.12)
        let calgary = CLLocationCoordinate2D(latitude: 51.05, longitude: -114.07)
        let nearChord = anchor(longitude: -116.35, latitude: 50.80)
        let farNorth = anchor(longitude: -120.0, latitude: 57.0)
        let ranked = CrossPackSeam.candidates(
            from: vancouver,
            to: calgary,
            anchors: [farNorth, nearChord],
            urbanCores: []
        )
        #expect(try #require(ranked.first).osmWayId == nearChord.osmWayId)
        #expect(try #require(ranked.first).longitude == nearChord.longitude)
    }

    @Test func rejectsUnprovenOrGappedSeams() {
        let from = CLLocationCoordinate2D(latitude: 49.2, longitude: -119.5)
        let to = CLLocationCoordinate2D(latitude: 48.9, longitude: -119.2)
        let good = anchor(neighbor: "wa", longitude: -119.4, latitude: 49.0)
        let missingWay = anchor(neighbor: "wa", longitude: -119.3, latitude: 49.0, way: "")
        let gapped = anchor(neighbor: "wa", longitude: -119.2, latitude: 49.0, gap: 2.1)
        let seams = CrossPackSeam.candidates(
            from: from,
            to: to,
            anchors: [missingWay, gapped, good],
            urbanCores: []
        )
        #expect(seams.count == 1)
        #expect(seams.first?.longitude == good.longitude)
        #expect(GraphPackStore.packsShareABorder("bc", "ab"))
        #expect(GraphPackStore.packsShareABorder("bc", "wa"))
    }

    @Test func southernBorderCoordinatesResolveToWashingtonBeforeBCOrAlberta() {
        let oroville = CLLocationCoordinate2D(latitude: 48.94, longitude: -119.44)
        #expect(GraphPackStore.primaryRegionId(containing: oroville) == "wa")
    }

    @Test func eitherSideOf49thResolvesToItsOwnPack() {
        let bc = CLLocationCoordinate2D(latitude: 49.01, longitude: -119.44)
        let wa = CLLocationCoordinate2D(latitude: 48.99, longitude: -119.44)
        #expect(GraphPackStore.primaryRegionId(containing: bc) == "bc")
        #expect(GraphPackStore.primaryRegionId(containing: wa) == "wa")
    }

    @Test func westernNovaScotiaStaysNSDespiteNBBboxOverlap() {
        let halifax = CLLocationCoordinate2D(latitude: 44.6488, longitude: -63.5752)
        let digby = CLLocationCoordinate2D(latitude: 44.6221, longitude: -65.7587)
        let kentville = CLLocationCoordinate2D(latitude: 45.0770, longitude: -64.4935)
        let moncton = CLLocationCoordinate2D(latitude: 46.0878, longitude: -64.7782)
        let saintJohn = CLLocationCoordinate2D(latitude: 45.2733, longitude: -66.0633)
        let amherst = CLLocationCoordinate2D(latitude: 45.833, longitude: -64.213)
        let sackville = CLLocationCoordinate2D(latitude: 45.918, longitude: -64.368)
        #expect(GraphPackStore.primaryRegionId(containing: halifax) == "ns")
        #expect(GraphPackStore.primaryRegionId(containing: digby) == "ns")
        #expect(GraphPackStore.primaryRegionId(containing: kentville) == "ns")
        #expect(GraphPackStore.primaryRegionId(containing: amherst) == "ns")
        #expect(GraphPackStore.primaryRegionId(containing: moncton) == "nb")
        #expect(GraphPackStore.primaryRegionId(containing: saintJohn) == "nb")
        #expect(GraphPackStore.primaryRegionId(containing: sackville) == "nb")
        #expect(GraphPackStore.endpointsCrossProvince([halifax, digby]) == false)
        #expect(GraphPackStore.endpointProvinceIds(containingAny: [halifax, digby]) == ["ns"])
        #expect(GraphPackStore.endpointsCrossProvince([halifax, moncton]) == true)
        #expect(GraphPackStore.endpointsCrossProvince([amherst, sackville]) == true)
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
            unknownAccessPercent: 0,
            reportedDirtPercent: 100,
            reportedPavedPercent: 0,
            unknownSurfacePercent: 0
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
            unknownAccessPercent: 0,
            reportedDirtPercent: 0,
            reportedPavedPercent: 100,
            unknownSurfacePercent: 0
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
