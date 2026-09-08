"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  chooseDirtRideCandidate,
  shortDirtExcursionEdgeIds,
  MINIMUM_EARNED_DIRT_EXCURSION_METERS,
  DIRT_BASE_SEARCH_BUDGET_MS,
  DIRT_MAX_SEARCH_BUDGET_MS,
  DIRT_PROVINCE_SCALE_ROUTE_METERS,
  BALANCED_BASE_SEARCH_BUDGET_MS,
  BALANCED_MAX_SEARCH_BUDGET_MS,
  LARGE_GRAPH_BASE_SEARCH_BUDGET_MS,
  CLEAN_BASE_SEARCH_BUDGET_MS,
  CLEAN_MAX_SEARCH_BUDGET_MS,
  balancedSearchBudgetMs,
  profileSearchBudgetMs,
  profileSearchPopCap,
  dirtRecoveryPathCap,
  balancedCorridorMultipliers,
  createBalancedLabelState
} = require("./find-path-v2");

function segment(edgeId, surfaceClass, distanceMeters, structureType = "none") {
  return { edgeId, surfaceClass, distanceMeters, structureType };
}

function candidate({
  dirt,
  paved,
  backward = 0,
  lateral = 0,
  route = 300_000,
  width,
  firstSection = dirt,
  minimumSection = dirt,
  longestPavedRun = paved,
  urbanCore = 0
}) {
  return {
    ride: { id: width },
    width,
    dirtPercent: dirt,
    pavedMeters: paved,
    firstSectionDirtPercent: firstSection,
    minimumSectionDirtPercent: minimumSection,
    longestPavedRunMeters: longestPavedRun,
    urbanCoreMeters: urbanCore,
    routeMeters: route,
    backwardMeters: backward,
    lateralMeters: lateral
  };
}

test("large Balanced label state allocates reached pages and preserves sentinels", () => {
  const state = createBalancedLabelState(10_000_001);
  assert.equal(state.sparse, true);
  assert.equal(state.pageCount(), 0);
  assert.equal(state.distance(9_000_000), Infinity);
  assert.equal(state.score(9_000_000), Infinity);
  assert.equal(state.previous(9_000_000), -1);
  assert.equal(state.peak(9_000_000), -Infinity);

  state.setDistance(9_000_000, 1234.5);
  state.setScore(9_000_000, 987.25);
  state.setDirt(9_000_000, 456.75);
  state.setPeak(9_000_000, 321);
  state.setPrevious(9_000_000, 8_999_999);
  state.setPreviousData(9_000_000, 42);
  state.setPreviousForward(9_000_000, 1);
  assert.equal(state.distance(9_000_000), 1234.5);
  assert.equal(state.score(9_000_000), 987.25);
  assert.equal(state.dirt(9_000_000), 456.75);
  assert.equal(state.peak(9_000_000), 321);
  assert.equal(state.previous(9_000_000), 8_999_999);
  assert.equal(state.previousData(9_000_000), 42);
  assert.equal(state.previousForward(9_000_000), 1);
  assert.equal(state.applyRelax("reset", 9_000_000), true);
  assert.equal(state.slots(9_000_000), 1);
  assert.equal(state.applyRelax("improve", 9_000_000), true);
  assert.equal(state.slots(9_000_000), 2);
  assert.equal(state.createsCycle(9_000_000, 8_999_999), true);
  assert.ok(state.pageCount() < 3);
});

test("Dirt prefers consistent journey quality when aggregate dirt is effectively tied", () => {
  const frontLoadedPavement = candidate({
    dirt: 68,
    paved: 130_000,
    minimumSection: 12,
    longestPavedRun: 46_000,
    width: 60_000
  });
  const consistentAdventure = candidate({
    dirt: 67,
    paved: 145_000,
    minimumSection: 38,
    longestPavedRun: 24_000,
    width: 120_000
  });
  assert.equal(
    chooseDirtRideCandidate([frontLoadedPavement, consistentAdventure]).width,
    120_000
  );
});

test("Dirt candidate selection works back from 100 percent, not shortest distance", () => {
  const directish = candidate({ dirt: 58, paved: 260_000, backward: 10_000, lateral: 30_000, width: 50_000 });
  const adventure = candidate({ dirt: 72, paved: 210_000, backward: 35_000, lateral: 80_000, width: 150_000 });
  assert.equal(chooseDirtRideCandidate([directish, adventure]).width, 150_000);
});

test("Dirt rejects purposeless meander when dirt yield is effectively tied", () => {
  const coherent = candidate({ dirt: 71, paved: 190_000, backward: 8_000, lateral: 25_000, width: 100_000 });
  const meander = candidate({ dirt: 72, paved: 191_000, backward: 70_000, lateral: 160_000, width: 150_000 });
  assert.equal(chooseDirtRideCandidate([meander, coherent]).width, 100_000);
});

test("Dirt uses less pavement before meander when dirt percentages are close", () => {
  const morePavement = candidate({ dirt: 70, paved: 220_000, backward: 0, lateral: 0, width: 50_000 });
  const lessPavement = candidate({ dirt: 71, paved: 180_000, backward: 20_000, lateral: 20_000, width: 100_000 });
  assert.equal(chooseDirtRideCandidate([morePavement, lessPavement]).width, 100_000);
});

test("Dirt does not consume a wider corridor when ride quality is identical", () => {
  const wide = candidate({ dirt: 70, paved: 180_000, backward: 10_000, lateral: 20_000, width: 200_000 });
  const narrow = candidate({ dirt: 70, paved: 180_000, backward: 10_000, lateral: 20_000, width: 50_000 });
  assert.equal(chooseDirtRideCandidate([wide, narrow]).width, 50_000);
});

test("Dirt rejects a large loop for a single-digit dirt gain", () => {
  const coherent = candidate({ dirt: 70, paved: 120_000, backward: 4_000, route: 250_000, width: 50_000 });
  const loop = candidate({ dirt: 77, paved: 110_000, backward: 80_000, route: 340_000, width: 200_000 });
  assert.equal(chooseDirtRideCandidate([loop, coherent]).width, 50_000);
});

test("sub-kilometre known dirt excursion is re-priced, including unknown gaps", () => {
  const edges = shortDirtExcursionEdgeIds([
    segment("paved-a", "paved", 2_000),
    segment("gravel-a", "gravel", 450),
    segment("unknown-a", "unknown", 800),
    segment("track-a", "track", 500),
    segment("paved-b", "paved", 2_000)
  ]);
  assert.deepEqual([...edges].sort(), ["gravel-a", "track-a", "unknown-a"]);
});

test("one kilometre of known unpaved riding earns the Dirt diversion", () => {
  const edges = shortDirtExcursionEdgeIds([
    segment("paved-a", "paved", 2_000),
    segment("gravel-a", "gravel", 400),
    segment("unknown-a", "unknown", 800),
    segment("track-a", "track", MINIMUM_EARNED_DIRT_EXCURSION_METERS - 400),
    segment("paved-b", "paved", 2_000)
  ]);
  assert.equal(edges.size, 0);
});

test("unknown surface never earns the kilometre", () => {
  const edges = shortDirtExcursionEdgeIds([
    segment("paved-a", "paved", 2_000),
    segment("unknown-a", "unknown", 1_500),
    segment("paved-b", "paved", 2_000)
  ]);
  assert.deepEqual([...edges], ["unknown-a"]);
});

test("route endpoint dirt remains eligible for pins and necessary connectors", () => {
  const edges = shortDirtExcursionEdgeIds([
    segment("paved-a", "paved", 2_000),
    segment("gravel-a", "gravel", 300),
    segment("destination", "track", 300)
  ]);
  assert.equal(edges.size, 0);
});

test("ordinary Balanced routes keep the established bounded search budget", () => {
  assert.equal(
    balancedSearchBudgetMs(250_000, 250_000),
    BALANCED_BASE_SEARCH_BUDGET_MS
  );
  assert.deepEqual(
    balancedCorridorMultipliers(250_000),
    [1, 2, 3, 4, 6, 8]
  );
});

test("long routes on province-sized graphs receive a bounded adaptive search budget", () => {
  const budget = balancedSearchBudgetMs(1_016_620, 1_470_000);
  assert.ok(budget > BALANCED_BASE_SEARCH_BUDGET_MS,
    `expected an adaptive province-scale budget, got ${budget}`);
  assert.ok(budget <= BALANCED_MAX_SEARCH_BUDGET_MS);
  assert.deepEqual(
    balancedCorridorMultipliers(1_016_620),
    [2, 3, 4, 6, 8]
  );
});

test("short routes on province-sized graphs do not inherit small-region ceilings", () => {
  const nodes = 1_470_000;
  const dirtBudget = profileSearchBudgetMs("dirt", 67_000, nodes);
  const balancedBudget = profileSearchBudgetMs("balanced", 67_000, nodes);
  const cleanBudget = profileSearchBudgetMs("cleanest", 67_000, nodes);

  assert.ok(dirtBudget >= 16_000 && dirtBudget <= DIRT_MAX_SEARCH_BUDGET_MS);
  assert.ok(
    balancedBudget >= 10_000 &&
      balancedBudget <= LARGE_GRAPH_BASE_SEARCH_BUDGET_MS
  );
  assert.ok(
    cleanBudget >= CLEAN_BASE_SEARCH_BUDGET_MS &&
      cleanBudget <= CLEAN_MAX_SEARCH_BUDGET_MS
  );
  assert.ok(profileSearchPopCap("dirt", nodes, true) > 200_000);
  assert.ok(profileSearchPopCap("balanced", nodes) > 400_000);
});

test("province-scale Dirt rides may use the full ceiling without making it a delay", () => {
  assert.equal(
    profileSearchBudgetMs("dirt", DIRT_PROVINCE_SCALE_ROUTE_METERS, 750_000),
    DIRT_MAX_SEARCH_BUDGET_MS
  );
  assert.ok(
    profileSearchBudgetMs("dirt", DIRT_PROVINCE_SCALE_ROUTE_METERS - 1, 750_000) <
      DIRT_MAX_SEARCH_BUDGET_MS
  );
});

test("small graphs retain established profile budgets and exploration caps", () => {
  const nodes = 250_000;
  assert.equal(
    profileSearchBudgetMs("dirt", 67_000, nodes),
    DIRT_BASE_SEARCH_BUDGET_MS
  );
  assert.equal(
    profileSearchBudgetMs("balanced", 67_000, nodes),
    BALANCED_BASE_SEARCH_BUDGET_MS
  );
  assert.equal(
    profileSearchBudgetMs("cleanest", 67_000, nodes),
    CLEAN_BASE_SEARCH_BUDGET_MS
  );
  assert.equal(profileSearchPopCap("dirt", nodes, true), 200_000);
  assert.equal(profileSearchPopCap("dirt", nodes, false), 400_000);
});

test("Dirt recovery scales a coherent detour allowance under the hard tank cap", () => {
  assert.equal(dirtRecoveryPathCap(51_864), 91_864);
  assert.equal(dirtRecoveryPathCap(110_275), 165_412.5);
  assert.equal(dirtRecoveryPathCap(382_484, 382_500), 382_500);
});
