"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  BALANCED_CORRIDOR_M,
  DIRT_CORRIDOR_M,
  projectedProgressMeters,
  maxProgressRegressionMeters,
  progressRegressionForAttempt,
  corridorMetersForProfile,
  pickResourceEnd,
  dirtRideCostPerKm,
  routeShapeMetrics,
  metroBlocks,
  metroEdgeBlocks,
  urbanCoreFallbackMultiplier,
  settlementBlocks,
  settlementFallbackMultiplier
} = require("./hop-search");

test("recognized urban cores are detected unless A or B is inside that core", () => {
  const outsideA = [-123.5, 49.7];
  const outsideB = [-119.1, 50.5];
  const vancouver = [-123.1, 49.25];
  assert.equal(metroBlocks(vancouver[0], vancouver[1], outsideA, outsideB), true);
  assert.equal(metroBlocks(vancouver[0], vancouver[1], vancouver, outsideB), false);
  assert.equal(metroBlocks(vancouver[0], vancouver[1], outsideA, vancouver), false);
});

test("an edge cannot tunnel through an urban core between outside nodes", () => {
  const core = { minLat: 49.0, maxLat: 49.1, minLon: -122.4, maxLon: -122.2 };
  const start = [-122.6, 49.05];
  const end = [-122.0, 49.05];
  assert.equal(metroEdgeBlocks(start, end, start, end, [core]), true);
  assert.equal(metroEdgeBlocks([-122.6, 49.2], [-122.0, 49.2], start, end, [core]), false);
  assert.equal(metroEdgeBlocks(start, end, [-122.3, 49.05], end, [core]), false);
});

test("urban cores are hard-blocked first and strongly penalized on explicit fallback", () => {
  const { hopBlocked } = require("./hop-search");
  const outsideA = [-123.5, 49.7];
  const outsideB = [-119.1, 50.5];
  const vancouver = [-123.1, 49.25];
  assert.equal(hopBlocked(vancouver, outsideA, outsideB, true), true);
  assert.equal(hopBlocked(vancouver, outsideA, outsideB, false), false);
  assert.equal(urbanCoreFallbackMultiplier(vancouver[0], vancouver[1], outsideA, outsideB), 120);
  assert.equal(urbanCoreFallbackMultiplier(vancouver[0], vancouver[1], vancouver, outsideB), 1);
  assert.equal(
    urbanCoreFallbackMultiplier(-122.0, 49.05, outsideA, outsideB, [
      { minLat: 49.0, maxLat: 49.1, minLon: -122.4, maxLon: -122.2 }
    ], [-122.6, 49.05]),
    120
  );
  assert.equal(
    urbanCoreFallbackMultiplier(vancouver[0], vancouver[1], outsideA, outsideB, undefined, null, 5),
    5
  );
});

test("Clean metro multiplier override clamps 1–20 and ignores other profiles", () => {
  const {
    resolveCleanMetroMultiplier,
    resolveMetroFallbackPenalty,
    resolveSettlementFallbackPenalty
  } = require("./hop-search");
  assert.equal(resolveCleanMetroMultiplier("cleanest", 5), 5);
  assert.equal(resolveCleanMetroMultiplier("cleanest", 0.5), 1);
  assert.equal(resolveCleanMetroMultiplier("cleanest", 99), 20);
  assert.equal(resolveCleanMetroMultiplier("cleanest", null), null);
  assert.equal(resolveCleanMetroMultiplier("dirt", 5), null);
  assert.equal(resolveMetroFallbackPenalty("balanced", 5, true), 120);
  assert.equal(resolveMetroFallbackPenalty("cleanest", null, true), 10);
  assert.equal(resolveMetroFallbackPenalty("cleanest", null, false), 2);
  assert.equal(resolveMetroFallbackPenalty("cleanest", 7, true), 7);
  assert.equal(resolveSettlementFallbackPenalty("cleanest", null, true), 10);
  assert.equal(resolveSettlementFallbackPenalty("cleanest", null, false), 2);
  assert.equal(resolveSettlementFallbackPenalty("cleanest", 99, true), 20);
  assert.equal(resolveSettlementFallbackPenalty("balanced", 20, true), 5);
});

test("smaller settlements are avoided unless an endpoint is inside", () => {
  const town = { minLat: 48.0, maxLat: 48.1, minLon: -122.2, maxLon: -122.0, name: "test-town" };
  const outsideA = [-122.5, 48.05];
  const outsideB = [-121.7, 48.05];
  assert.equal(settlementBlocks(-122.1, 48.05, outsideA, outsideB, [town]), true);
  assert.equal(settlementFallbackMultiplier(-122.1, 48.05, outsideA, outsideB, [town]), 5);
  assert.equal(settlementFallbackMultiplier(-122.1, 48.05, outsideA, outsideB, [town], 10), 10);
  assert.equal(settlementFallbackMultiplier(-122.1, 48.05, outsideA, outsideB, [town], 99), 20);
  assert.equal(settlementBlocks(-122.1, 48.05, [-122.1, 48.05], outsideB, [town]), false);
});

test("Clean pavement gate blocks gravel and untagged minor roads", () => {
  const { isBlockedForCleanPavement, isDirtSurface } = require("./hop-search");
  assert.equal(isBlockedForCleanPavement("paved", "local"), false);
  assert.equal(isBlockedForCleanPavement("unknown", "arterial"), false);
  assert.equal(isBlockedForCleanPavement("unknown", "local"), true);
  assert.equal(isBlockedForCleanPavement("unknown", "service"), true);
  assert.equal(isBlockedForCleanPavement("gravel", "local"), true);
  assert.equal(isBlockedForCleanPavement("track", "track"), true);
  // Adventure dirt% still treats unknown+local as paved paint (not dirt).
  assert.equal(isDirtSurface("unknown", "local"), false);
});

test("adventure corridors widen from Balanced to Dirt", () => {
  assert.ok(BALANCED_CORRIDOR_M < DIRT_CORRIDOR_M);
  assert.equal(DIRT_CORRIDOR_M, 60000);
  assert.equal(corridorMetersForProfile("cleanest"), null);
  assert.equal(corridorMetersForProfile("balanced"), BALANCED_CORRIDOR_M);
});

test("Clean has no hard forward regression ceiling", () => {
  assert.equal(maxProgressRegressionMeters("cleanest"), Infinity);
  assert.ok(maxProgressRegressionMeters("balanced") < maxProgressRegressionMeters("dirt"));
});

test("progress is measured along A to B without a reference route", () => {
  const a = [-123, 50];
  const b = [-119, 50];
  const mid = [-121, 50];
  const total = projectedProgressMeters(b, a, b);
  assert.ok(Math.abs(projectedProgressMeters(a, a, b)) < 1);
  assert.ok(Math.abs(projectedProgressMeters(mid, a, b) - total / 2) < 100);
  assert.ok(total > 250000);
});

test("Dirt may regress more than Balanced", () => {
  assert.ok(maxProgressRegressionMeters("balanced") < maxProgressRegressionMeters("dirt"));
});

test("a wider adventure corridor never grants more travel away from the next pin", () => {
  assert.equal(
    progressRegressionForAttempt("dirt", DIRT_CORRIDOR_M),
    progressRegressionForAttempt("dirt", DIRT_CORRIDOR_M * 4)
  );
  assert.equal(progressRegressionForAttempt("dirt", DIRT_CORRIDOR_M), 15000);
  assert.equal(progressRegressionForAttempt("dirt", Infinity), Infinity);
});

test("Balanced selects the destination label closest to 50/50", () => {
  const labels = [
    { lab: 1, len: 100, dirt: 45 },
    { lab: 2, len: 120, dirt: 60 },
    { lab: 3, len: 100, dirt: 70 }
  ];
  assert.equal(pickResourceEnd(labels, "balanced", 7), 2);
});

test("Dirt selects the highest dirt share", () => {
  const labels = [
    { lab: 1, len: 100, dirt: 80 },
    { lab: 2, len: 120, dirt: 108 },
    { lab: 3, len: 100, dirt: 70 }
  ];
  assert.equal(pickResourceEnd(labels, "dirt", 7), 2);
});

test("Dirt pavement is costly but all dirt kilometres still have positive cost", () => {
  const paved = dirtRideCostPerKm("paved", "local", "high");
  const gravel = dirtRideCostPerKm("gravel", "track", "high");
  const resource = dirtRideCostPerKm("resource", "track", "high");
  const inferred = dirtRideCostPerKm("unknown", "track", "low");
  assert.ok(paved > gravel);
  assert.ok(gravel > resource);
  assert.ok(resource > 0);
  assert.ok(inferred > resource);
});

test("route shape reports backward and off-axis riding", () => {
  const start = [-123, 0];
  const end = [-119, 0];
  const straight = routeShapeMetrics([start, [-121, 0], end], start, end);
  const meander = routeShapeMetrics(
    [start, [-121.5, 0.5], [-122, 0.6], [-120, 0.5], end],
    start,
    end
  );
  assert.equal(straight.backwardMeters, 0);
  assert.ok(straight.p95CrossTrackMeters < 10);
  assert.ok(meander.backwardMeters > 0);
  assert.ok(meander.p95CrossTrackMeters > 40000);
});
