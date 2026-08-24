"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  isMajorHighwayClass,
  majorHighwayAvoidMult
} = require("./profile-costs");

test("Clean isMajorHighway — freeway yes, arterial no, ramp yes-as-freeway", () => {
  assert.equal(isMajorHighwayClass("freeway", "cleanest"), true);
  assert.equal(isMajorHighwayClass("ramp", "cleanest"), true);
  assert.equal(isMajorHighwayClass("arterial", "cleanest"), false);
  assert.equal(isMajorHighwayClass("collector", "cleanest"), false);

  assert.equal(majorHighwayAvoidMult("cleanest", "arterial", 80_000, 80_000, false, false), 1);
  assert.ok(majorHighwayAvoidMult("cleanest", "freeway", 80_000, 80_000, false, false) > 1);
  assert.ok(majorHighwayAvoidMult("cleanest", "ramp", 80_000, 80_000, false, false) > 1);
});

test("Balanced and Dirt still tax arterial as major highway", () => {
  assert.equal(isMajorHighwayClass("arterial", "balanced"), true);
  assert.equal(isMajorHighwayClass("arterial", "dirt"), true);
  assert.ok(majorHighwayAvoidMult("balanced", "arterial", 80_000, 80_000, false, false) > 1);
  assert.ok(majorHighwayAvoidMult("dirt", "arterial", 80_000, 80_000, false, false) > 1);
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
