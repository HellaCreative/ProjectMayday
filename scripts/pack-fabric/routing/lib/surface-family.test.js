#!/usr/bin/env node
"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  surfaceFamilyOf,
  honestSurfaceStatsFromLeaves,
  SURFACE_FAMILY
} = require("./surface-family");

describe("surface-family E1", () => {
  it("maps locked taxonomy leaves", () => {
    assert.equal(surfaceFamilyOf("asphalt"), SURFACE_FAMILY.PAVED);
    assert.equal(surfaceFamilyOf("unpaved"), SURFACE_FAMILY.GRAVEL);
    assert.equal(surfaceFamilyOf("dirt"), SURFACE_FAMILY.LOOSE);
    assert.equal(surfaceFamilyOf(null), SURFACE_FAMILY.UNKNOWN);
    assert.equal(surfaceFamilyOf("asphalt;gravel"), SURFACE_FAMILY.UNKNOWN);
  });

  it("rider Dirt% counts gravel + loose + unknown (not paved)", () => {
    const stats = honestSurfaceStatsFromLeaves(
      [
        { meters: 100, surfaceLeaf: "asphalt" },
        { meters: 100, surfaceLeaf: "gravel" },
        { meters: 50, surfaceLeaf: "dirt" },
        { meters: 50, surfaceLeaf: null }
      ],
      300
    );
    assert.equal(stats.pavedPercent, 33);
    assert.equal(stats.gravelPercent, 33);
    assert.equal(stats.dirtPercent, 67);
    assert.equal(stats.unknownSurfacePercent, 17);
  });
});
