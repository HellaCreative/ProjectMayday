"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  isMajorHighwayClass,
  majorHighwayAvoidMult,
  roadClassMultiplier
} = require("./profile-costs");

test("Clean coarse packs avoid freeway, arterial, and ramp when major highways are off", () => {
  assert.equal(isMajorHighwayClass("freeway", "cleanest"), true);
  assert.equal(isMajorHighwayClass("ramp", "cleanest"), true);
  assert.equal(isMajorHighwayClass("arterial", "cleanest"), true);
  assert.equal(isMajorHighwayClass("collector", "cleanest"), false);

  assert.equal(majorHighwayAvoidMult("cleanest", "arterial", 80_000, 80_000, false, false, true), 8);
  assert.equal(majorHighwayAvoidMult("cleanest", "freeway", 80_000, 80_000, false, false, true), 40);
  assert.equal(majorHighwayAvoidMult("cleanest", "ramp", 80_000, 80_000, false, false, true), 40);
  assert.equal(majorHighwayAvoidMult("cleanest", "arterial", 80_000, 80_000, false, false, false), 1);
  assert.equal(majorHighwayAvoidMult("cleanest", "freeway", 80_000, 80_000, false, false, false), 1);
});

test("Balanced and Dirt retain the proven non-Clean major-highway floor", () => {
  assert.equal(isMajorHighwayClass("arterial", "balanced"), true);
  assert.equal(isMajorHighwayClass("arterial", "dirt"), true);

  for (const [profile, road] of [
    ["balanced", "arterial"],
    ["balanced", "ramp"],
    ["balanced", "freeway"],
    ["dirt", "arterial"],
    ["dirt", "ramp"],
    ["dirt", "freeway"]
  ]) {
    const base = roadClassMultiplier(road, profile);
    const multiplier = majorHighwayAvoidMult(
      profile, road, 80_000, 80_000, false, false
    );
    const effective = base * multiplier;
    const expected = Math.max(3, base);
    assert.ok(
      Math.abs(effective - expected) < 1e-12,
      `${profile} ${road} must preserve the baseline floor without retuning higher costs: `
        + `expected ${expected}, received ${effective}`
    );
  }
});

test("unknown or missing profile uses Balanced", () => {
  const { resolveProfile, surfaceMultiplier } = require("./profile-costs");
  assert.equal(resolveProfile(undefined), "balanced");
  assert.equal(resolveProfile(""), "balanced");
  assert.equal(resolveProfile("scenic"), "balanced");
  assert.equal(
    surfaceMultiplier(0, "scenic"),
    surfaceMultiplier(0, "balanced")
  );
});
