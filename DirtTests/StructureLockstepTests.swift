import Testing
@testable import Dirt

/// Phase G2 — structure labels lockstep with scripts/pack-fabric/routing/lib/structure.js.
struct StructureLockstepTests {
    @Test func packedStructureCodesMatchJs() {
        #expect(GraphV2Pack.structureNone == 0)
        #expect(GraphV2Pack.structureBridge == 1)
        #expect(GraphV2Pack.structureTunnel == 2)
        #expect(GraphV2Pack.structureFord == 3)
        #expect(GraphV2Pack.structureFerry == 4)
        #expect(GraphV2Pack.structureName(1) == "bridge")
        #expect(GraphV2Pack.structureName(2) == "tunnel")
        #expect(GraphV2Pack.structureName(3) == "ford")
        #expect(GraphV2Pack.structureName(4) == "ferry")
    }

    @Test func labelsDistinguishFordTunnelOverpassUnderpass() {
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureFord,
                structureLeaf: "ford",
                layer: 0
            ) == "Ford"
        )
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureTunnel,
                structureLeaf: "tunnel",
                layer: -1
            ) == "Tunnel"
        )
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureBridge,
                structureLeaf: "bridge",
                layer: 1
            ) == "Overpass"
        )
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureBridge,
                structureLeaf: "bridge",
                layer: -1
            ) == "Underpass"
        )
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureNone,
                structureLeaf: nil,
                layer: 1
            ) == "Overpass"
        )
    }

    @Test func specificLeavesKeepDedicatedLabels() {
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureBridge,
                structureLeaf: "boardwalk",
                layer: 0
            ) == "Boardwalk"
        )
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureBridge,
                structureLeaf: "viaduct",
                layer: 0
            ) == "Viaduct"
        )
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureTunnel,
                structureLeaf: "culvert",
                layer: 0
            ) == "Culvert"
        )
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureFord,
                structureLeaf: "low_water_crossing",
                layer: 0
            ) == "Low-water crossing"
        )
    }

    @Test func fordsAreWaterCrossingsTunnelsAreNot() {
        #expect(
            OnDeviceProfileCosts.isWaterCrossing(
                structureCode: GraphV2Pack.structureFord,
                structureLeaf: "ford"
            )
        )
        #expect(
            OnDeviceProfileCosts.isWaterCrossing(
                structureCode: GraphV2Pack.structureFord,
                structureLeaf: "stepping_stones"
            )
        )
        #expect(
            !OnDeviceProfileCosts.isWaterCrossing(
                structureCode: GraphV2Pack.structureBridge,
                structureLeaf: "bridge"
            )
        )
        #expect(
            !OnDeviceProfileCosts.isWaterCrossing(
                structureCode: GraphV2Pack.structureTunnel,
                structureLeaf: "tunnel"
            )
        )
    }

    @Test func ferryLabelStaysIdenticalToG1() {
        #expect(
            OnDeviceProfileCosts.structureCrossingLabel(
                structureCode: GraphV2Pack.structureFerry,
                structureLeaf: "ferry",
                layer: 0
            ) == OnDeviceProfileCosts.ferryCrossingLabel
        )
    }

    @Test func structureDoesNotCreateADirtOrPavedShare() {
        // Fords keep a surface leaf. Honest Dirt%/Paved% stay surface-family
        // based; structure is a label, not a third percentage bucket.
        let withFord = SurfaceFamilyStats.honestPercents(
            rows: [(1000, "asphalt"), (200, "asphalt")],
            distanceMeters: 1200
        )
        let pavedOnly = SurfaceFamilyStats.honestPercents(
            rows: [(1200, "asphalt")],
            distanceMeters: 1200
        )
        #expect(withFord.pavedPercent == 100)
        #expect(withFord.pavedPercent == pavedOnly.pavedPercent)
        #expect(withFord.dirtPercent == 0)
    }
}
