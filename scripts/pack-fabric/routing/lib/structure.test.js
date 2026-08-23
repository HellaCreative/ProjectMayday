"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  STRUCTURE_BRIDGE,
  STRUCTURE_TUNNEL,
  STRUCTURE_FORD,
  STRUCTURE_NONE,
  structureFromTags,
  structureCrossingLabel,
  isWaterCrossing,
  segmentStructureFields
} = require("./structure");
const { STRUCTURE_FERRY, FERRY_CROSSING_LABEL } = require("./ferry");

describe("structureFromTags", () => {
  it("maps richer bridge leaves, keeping boardwalk as bridge", () => {
    assert.deepEqual(structureFromTags({ bridge: "boardwalk" }), {
      structureType: "bridge",
      structureLeaf: "boardwalk"
    });
    assert.deepEqual(structureFromTags({ bridge: "viaduct" }), {
      structureType: "bridge",
      structureLeaf: "viaduct"
    });
    assert.deepEqual(structureFromTags({ bridge: "yes" }), {
      structureType: "bridge",
      structureLeaf: "bridge"
    });
  });

  it("treats low_water_crossing as a water crossing (ford class)", () => {
    assert.deepEqual(structureFromTags({ bridge: "low_water_crossing" }), {
      structureType: "ford",
      structureLeaf: "low_water_crossing"
    });
  });

  it("maps all ford values", () => {
    assert.equal(structureFromTags({ ford: "yes" }).structureType, "ford");
    assert.equal(structureFromTags({ ford: "yes" }).structureLeaf, "ford");
    assert.equal(structureFromTags({ ford: "stepping_stones" }).structureLeaf, "stepping_stones");
    assert.equal(structureFromTags({ ford: "stream" }).structureType, "ford");
    assert.equal(structureFromTags({ ford: "no" }).structureType, "none");
  });

  it("maps tunnel leaves including culvert and building_passage", () => {
    assert.deepEqual(structureFromTags({ tunnel: "culvert" }), {
      structureType: "tunnel",
      structureLeaf: "culvert"
    });
    assert.deepEqual(structureFromTags({ tunnel: "building_passage" }), {
      structureType: "tunnel",
      structureLeaf: "building_passage"
    });
    assert.deepEqual(structureFromTags({ tunnel: "yes" }), {
      structureType: "tunnel",
      structureLeaf: "tunnel"
    });
  });

  it("gives ford priority over bridge/tunnel", () => {
    assert.equal(
      structureFromTags({ ford: "yes", bridge: "yes" }).structureType,
      "ford"
    );
  });
});

describe("structureCrossingLabel + waterCrossing", () => {
  it("labels ford / tunnel / overpass / underpass distinctly", () => {
    assert.equal(
      structureCrossingLabel({ structureCode: STRUCTURE_FORD, structureLeaf: "ford", layer: 0 }),
      "Ford"
    );
    assert.equal(
      structureCrossingLabel({ structureCode: STRUCTURE_TUNNEL, structureLeaf: "tunnel", layer: -1 }),
      "Tunnel"
    );
    assert.equal(
      structureCrossingLabel({ structureCode: STRUCTURE_BRIDGE, structureLeaf: "bridge", layer: 1 }),
      "Overpass"
    );
    assert.equal(
      structureCrossingLabel({ structureCode: STRUCTURE_BRIDGE, structureLeaf: "bridge", layer: -1 }),
      "Underpass"
    );
    assert.equal(
      structureCrossingLabel({
        structureCode: STRUCTURE_NONE,
        structureLeaf: null,
        layer: 1
      }),
      "Overpass"
    );
  });

  it("uses specific leaves for boardwalk, viaduct, culvert, low-water", () => {
    assert.equal(
      structureCrossingLabel({ structureCode: STRUCTURE_BRIDGE, structureLeaf: "boardwalk", layer: 0 }),
      "Boardwalk"
    );
    assert.equal(
      structureCrossingLabel({ structureCode: STRUCTURE_BRIDGE, structureLeaf: "viaduct", layer: 0 }),
      "Viaduct"
    );
    assert.equal(
      structureCrossingLabel({ structureCode: STRUCTURE_TUNNEL, structureLeaf: "culvert", layer: 0 }),
      "Culvert"
    );
    assert.equal(
      structureCrossingLabel({
        structureCode: STRUCTURE_FORD,
        structureLeaf: "low_water_crossing",
        layer: 0
      }),
      "Low-water crossing"
    );
  });

  it("flags fords as water crossings; tunnels are not", () => {
    assert.equal(isWaterCrossing({ structureCode: STRUCTURE_FORD, structureLeaf: "ford" }), true);
    assert.equal(
      isWaterCrossing({ structureCode: STRUCTURE_FORD, structureLeaf: "stepping_stones" }),
      true
    );
    assert.equal(
      isWaterCrossing({ structureCode: STRUCTURE_BRIDGE, structureLeaf: "bridge" }),
      false
    );
    assert.equal(
      isWaterCrossing({ structureCode: STRUCTURE_TUNNEL, structureLeaf: "tunnel" }),
      false
    );
  });

  it("keeps the ferry label identical to ferry.js", () => {
    assert.equal(
      structureCrossingLabel({ structureCode: STRUCTURE_FERRY, structureLeaf: "ferry", layer: 0 }),
      FERRY_CROSSING_LABEL
    );
    const fields = segmentStructureFields({
      structureCode: STRUCTURE_FORD,
      structureLeaf: "ford",
      layer: 0
    });
    assert.equal(fields.crossingLabel, "Ford");
    assert.equal(fields.waterCrossing, true);
  });
});
