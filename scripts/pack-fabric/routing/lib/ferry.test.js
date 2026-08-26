"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  parseOsmDuration,
  ferryCrossingSeconds,
  ferryRelaxStepCost,
  isFerryStructureCode,
  ferryCrossingLabel,
  STRUCTURE_FERRY,
  FERRY_SPEED_KMH,
  FERRY_COST_REFERENCE_KMH
} = require("./ferry");
const { applyHonestSurfaceStats } = require("./surface-family");

test("parseOsmDuration requires HH:MM or an explicit unit", () => {
  assert.equal(parseOsmDuration("1:30"), 5400);
  assert.equal(parseOsmDuration("5 min"), 300);
  assert.equal(parseOsmDuration("600 sec"), 600);
  assert.equal(parseOsmDuration("1.5 hours"), 5400);
  assert.equal(parseOsmDuration("5"), null);
  assert.equal(parseOsmDuration("600"), null);
  assert.equal(parseOsmDuration(""), null);
});

test("ferryCrossingSeconds prefers OSM duration over distance estimate", () => {
  assert.equal(ferryCrossingSeconds(2000, "10 min"), 600);
  const est = ferryCrossingSeconds(1800, null);
  assert.equal(est, Math.max(60, Math.round((1.8 / FERRY_SPEED_KMH) * 3600)));
});

test("ferryRelaxStepCost converts crossing time to search units", () => {
  const sec = 3600;
  assert.equal(ferryRelaxStepCost(sec), FERRY_COST_REFERENCE_KMH);
  assert.equal(ferryRelaxStepCost(360), FERRY_COST_REFERENCE_KMH / 10);
  assert.equal(ferryRelaxStepCost(0), 0);
});

test("ferry structure code and label are stable", () => {
  assert.equal(isFerryStructureCode(STRUCTURE_FERRY), true);
  assert.equal(isFerryStructureCode(3), false);
  assert.equal(ferryCrossingLabel(), "Ferry crossing");
});

test("honest surface stats exclude ferry legs from denominator", () => {
  const base = {
    dirtPercent: 0,
    pavedPercent: 100,
    gravelPercent: 0,
    unknownSurfacePercent: 0
  };
  const rows = [
    { meters: 1000, surfaceLeaf: "asphalt" },
    { meters: 500, surfaceLeaf: "n/a" }
  ];
  const withFerry = applyHonestSurfaceStats(base, rows, 1500, true);
  const withoutFerry = applyHonestSurfaceStats(
    base,
    [{ meters: 1000, surfaceLeaf: "asphalt" }],
    1000,
    true
  );
  assert.equal(withFerry.pavedPercent, 67);
  assert.equal(withoutFerry.pavedPercent, 100);
});
