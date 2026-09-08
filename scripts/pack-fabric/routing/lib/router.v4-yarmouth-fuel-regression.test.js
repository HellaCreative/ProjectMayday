"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "../../../..");
const packRoot = process.env.DIRT_V4_TEST_PACK_ROOT
  ? path.resolve(process.env.DIRT_V4_TEST_PACK_ROOT)
  : path.join(root, "scripts/pack-fabric/app/data/packs/v4/ns");
process.env.ROUTING_USE_REGIONAL = "1";
process.env.ROUTING_PACKS_V2 = "1";
process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({
  ns: path.join(packRoot, "graph.v4.bin")
});

const { fuelChainRequest } = require("./fuel-chain");

function assertNoMeaningfulRetrace(routes) {
  const edgeIds = routes.flatMap((route) => (route.segments || [])
    .map((segment) => String(segment.edgeId || ""))
    .filter(Boolean));
  const collapsed = edgeIds.filter((edgeId, index) =>
    index === 0 || edgeId !== edgeIds[index - 1]
  );
  assert.equal(new Set(collapsed).size, collapsed.length,
    "fuel-aware route must not return to an earlier road edge");
}

test("reported V4 Yarmouth route keeps Dirt and rejects the Coast Gas return", {
  timeout: 30_000
}, async () => {
  const fuel = JSON.parse(fs.readFileSync(path.join(packRoot, "fuel.v1.json"), "utf8"));
  const result = await fuelChainRequest({
    profile: "dirt",
    locations: [
      { lat: 44.764830, lon: -63.340265 },
      { lat: 43.622045, lon: -65.801340 }
    ],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    fuel: {
      usableRangeMeters: 333_000,
      firstLegMaxMeters: 333_000,
      routeFirstPlan: true,
      ensureDestinationFuelEscape: true,
      windowMaxStops: 4,
      allowPartialWindow: true,
      windowTimeBudgetMs: 30_000,
      riderLegId: "device-v4-yarmouth"
    },
    options: { sessionSeed: 0, backtrackFactor: 4 }
  }, {
    loadFuelForLocations: async () => ({
      ok: true,
      regionIds: ["ns"],
      stations: fuel.stations || [],
      packIdentity: []
    })
  });

  assert.equal(result.status, "complete");
  assert.ok((result.routes || []).length > 0);
  assert.ok(!(result.stops || []).some((stop) => String(stop.id) === "osm:n5294604869"));
  const meters = result.routes.reduce(
    (sum, route) => sum + Number(route.distanceMeters || 0), 0
  );
  const knownDirtPercent = result.routes.reduce(
    (sum, route) => sum +
      Number(route.distanceMeters || 0) * Number(route.stats && route.stats.dirtPercent || 0),
    0
  ) / meters;
  assert.ok(knownDirtPercent >= 55,
    `known Dirt regressed to ${knownDirtPercent.toFixed(1)}%; ` +
    `strategy=${result.diagnostics.strategy}; ` +
    `foundation=${result.diagnostics.foundationRouteDirtPercent ?? "-"}%/` +
    `${result.diagnostics.foundationRouteMeters ?? "-"}m; ` +
    `matched=${result.diagnostics.foundationMatchedStations ?? 0}; ` +
    `stops=${(result.stops || []).map((stop) => stop.id).join(",")}; ` +
    `candidates=${JSON.stringify((result.stationCandidates || []).map((candidate) => ({
      id: candidate.id,
      dirt: candidate.dirtPct,
      chainDirt: candidate.chainDirtPct,
      chainMeters: candidate.chainMeters,
      foundationCell: candidate.foundationPriorityCellDistance,
      backtrack: candidate.backtrackMeters,
      continuationBacktrack: candidate.continuationBacktrackMeters,
      urban: candidate.urbanEntry,
      rejected: candidate.rejectedReason
    })))}`);
  assert.equal(result.diagnostics.strategy, "foundation_route_partition");
  assert.equal(result.stops.length, 2, "Yarmouth needs exactly two feasible fuel stops");
  assert.equal(result.diagnostics.foundationMinimumFeasibleStops, result.stops.length);
  assert.equal(result.diagnostics.foundationMinimumStopProof, true);
  assert.deepEqual(result.diagnostics.foundationFewerStopCountsExhausted, [1]);
  assert.deepEqual(
    result.diagnostics.foundationFuelLegMeters,
    result.routes.map((route) => route.distanceMeters)
  );
  result.routes.forEach((route, index) => {
    const limit = index === 0
      ? result.diagnostics.foundationFirstLegLimitMeters
      : result.diagnostics.foundationFullTankLimitMeters;
    assert.ok(route.distanceMeters <= limit + 1,
      `fuel leg ${index + 1} exceeds ${limit}m: ${route.distanceMeters}m`);
  });
  assert.ok(
    result.routes.at(-1).distanceMeters <=
      result.diagnostics.foundationDestinationFuelUsedLimitMeters + 1,
    "destination arrival consumed more than its reserved-fuel limit"
  );
  assert.ok(result.diagnostics.foundationFuelAccess.every((access) =>
    ["same-foundation-directed-edge", "v4-directed-forecourt-through-path"]
      .includes(access.proof) &&
    access.arrivalMeters + access.departureMeters <= 200 + 1
  ), "every station needs a short, legally directed V4 arrival and departure proof");
  assert.ok(result.routes.flatMap((route) => route.segments || []).every((segment) =>
    !String(segment.edgeId || "").startsWith("fuel-access:") &&
    segment.surfaceClass !== "connector"
  ), "fuel partition must not add a straight synthetic connector");
  assert.equal(result.diagnostics.selectedUrbanEntry, false);
  assert.equal(result.diagnostics.ruralAlternativeAvailable, true);
});

test("reported V4 Cape Breton route commits only a fully proved fuel chain", {
  timeout: 30_000
}, async () => {
  const fuel = JSON.parse(fs.readFileSync(path.join(packRoot, "fuel.v1.json"), "utf8"));
  const result = await fuelChainRequest({
    profile: "dirt",
    locations: [
      { lat: 44.764791, lon: -63.340259 },
      { lat: 46.238365, lon: -60.221007 }
    ],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    fuel: {
      usableRangeMeters: 333_000,
      firstLegMaxMeters: 333_000,
      routeFirstPlan: true,
      ensureDestinationFuelEscape: true,
      windowMaxStops: 4,
      allowPartialWindow: true,
      windowTimeBudgetMs: 20_000,
      riderLegId: "device-v4-cape-breton"
    },
    options: { sessionSeed: 0, backtrackFactor: 4, mapZoom: 11.7 }
  }, {
    loadFuelForLocations: async () => ({
      ok: true,
      regionIds: ["ns"],
      stations: fuel.stations || [],
      packIdentity: []
    })
  });

  assert.equal(result.status, "complete");
  assert.equal(result.windowComplete, true);
  assert.ok((result.stops || []).length >= 1);
  assert.equal((result.routes || []).length, (result.stops || []).length + 1);
  assert.notEqual(result.diagnostics.selectedReason, "routed_prefix_timeout");
  assert.ok((result.stationCandidates || []).some((candidate) =>
    candidate.validForward === true && candidate.canFinish === true
  ));
});

test("reported V4 southwest route preserves its Dirt foundation around fuel", {
  timeout: 30_000
}, async () => {
  const fuel = JSON.parse(fs.readFileSync(path.join(packRoot, "fuel.v1.json"), "utf8"));
  const result = await fuelChainRequest({
    profile: "dirt",
    locations: [
      { lat: 44.764830, lon: -63.340265 },
      { lat: 43.678864, lon: -65.794704 }
    ],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    fuel: {
      usableRangeMeters: 382_500,
      firstLegMaxMeters: 382_500,
      routeFirstPlan: true,
      riderLegId: "device-v4-southwest"
    },
    options: { sessionSeed: 0xD1_47_0008, backtrackFactor: 4 }
  }, {
    loadFuelForLocations: async () => ({
      ok: true,
      regionIds: ["ns"],
      stations: fuel.stations || [],
      packIdentity: []
    })
  });

  assert.equal(result.status, "complete");
  const routes = result.routes || [];
  const meters = routes.reduce((sum, route) => sum + Number(route.distanceMeters || 0), 0);
  const knownDirtPercent = routes.reduce(
    (sum, route) => sum +
      Number(route.distanceMeters || 0) * Number(route.stats && route.stats.dirtPercent || 0),
    0
  ) / meters;
  assert.ok(knownDirtPercent >= 55,
    `known Dirt regressed to ${knownDirtPercent.toFixed(1)}%; ` +
    `strategy=${result.diagnostics.strategy}; ` +
    `stops=${(result.stops || []).map((stop) => stop.id).join(",")}; ` +
    `meters=${Math.round(meters)}; ` +
    `candidates=${JSON.stringify((result.stationCandidates || []).map((candidate) => ({
      id: candidate.id,
      dirt: candidate.dirtPct,
      chainDirt: candidate.chainDirtPct,
      chainMeters: candidate.chainMeters,
      validForward: candidate.validForward,
      canFinish: candidate.canFinish,
      urban: candidate.urbanEntry,
      rejected: candidate.rejectedReason
    })))}`);
  assert.equal(result.diagnostics.strategy, "foundation_route_partition");
  assert.equal(Number(result.diagnostics.profileRouteAttempts || 0), 0);
});

test("white-device 260 km profile reuses one Dirt search and proves its fuel-aware route", {
  timeout: 30_000
}, async () => {
  const fuel = JSON.parse(fs.readFileSync(path.join(packRoot, "fuel.v1.json"), "utf8"));
  const started = Date.now();
  const result = await fuelChainRequest({
    profile: "dirt",
    locations: [
      { lat: 44.76484, lon: -63.34023 },
      { lat: 43.47454, lon: -65.60197 }
    ],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    fuel: {
      usableRangeMeters: 234_000,
      firstLegMaxMeters: 234_000,
      routeFirstPlan: true,
      ensureDestinationFuelEscape: true,
      windowMaxStops: 4,
      allowPartialWindow: true,
      windowTimeBudgetMs: 30_000,
      riderLegId: "white-device-v4-260km"
    },
    options: { routeSeed: 0, backtrackFactor: 4 }
  }, {
    loadFuelForLocations: async () => ({
      ok: true,
      regionIds: ["ns"],
      stations: fuel.stations || [],
      packIdentity: []
    })
  });

  const elapsedMs = Date.now() - started;
  assert.equal(result.status, "complete");
  assert.equal(result.windowComplete, true);
  assert.equal(result.diagnostics.strategy, "foundation_route_partition");
  assert.equal(result.diagnostics.routeFirstAttempted, true);
  assert.ok(["completed", "timeCap"].includes(result.diagnostics.routeFirstSearchOutcome),
    "a ceiling result is valid only when the returned route is already complete and marked honestly");
  assert.equal(Number(result.diagnostics.profileRouteAttempts || 0), 0,
    "fuel planning must not independently reroute station legs");
  assert.equal(result.diagnostics.originalFoundationDirtPercent, 67);
  assert.ok(result.diagnostics.originalFoundationRouteMeters >= 650_000);
  assert.equal(result.diagnostics.fuelAwareFoundationAlternative, true);

  const attempts = result.diagnostics.foundationCandidateAttempts || [];
  const selectedAttempt = attempts.find((attempt) => attempt.feasible);
  assert.ok(selectedAttempt, "one complete Dirt candidate must be fuel-feasible");
  assert.ok(attempts.slice(0, attempts.indexOf(selectedAttempt)).every((attempt) =>
    attempt.feasible === false && attempt.dirtPercent >= selectedAttempt.dirtPercent
  ), "every higher-dirt complete candidate must be proved infeasible first");

  const routes = result.routes || [];
  assert.equal(routes.length, (result.stops || []).length + 1);
  assert.equal(result.stops.length, result.diagnostics.foundationMinimumFeasibleStops);
  assert.equal(result.diagnostics.foundationMinimumStopProof, true);
  assert.deepEqual([
    ...(result.diagnostics.foundationConstraintIneligibleStopCounts || []),
    ...(result.diagnostics.foundationFewerStopCountsExhausted || [])
  ].sort((a, b) => a - b), [1],
  "every smaller stop count must be excluded by the range lower bound or exhaustive search");
  routes.forEach((route) => {
    assert.ok(route.distanceMeters <= 234_001,
      `fuel leg exceeds actual usable range: ${route.distanceMeters}m`);
  });
  assert.ok(
    routes.at(-1).distanceMeters <=
      result.diagnostics.foundationDestinationFuelUsedLimitMeters + 1,
    "destination leg must preserve the proved reserve/escape allowance"
  );
  const meters = routes.reduce((sum, route) => sum + Number(route.distanceMeters || 0), 0);
  const knownDirtPercent = routes.reduce((sum, route) => sum +
    Number(route.distanceMeters || 0) * Number(route.stats && route.stats.dirtPercent || 0), 0
  ) / meters;
  assert.ok(knownDirtPercent >= 55,
    `fuel-aware Dirt route regressed to ${knownDirtPercent.toFixed(1)}%`);
  assertNoMeaningfulRetrace(routes);
  assert.ok(routes.flatMap((route) => route.segments || []).every((segment) =>
    !String(segment.edgeId || "").startsWith("fuel-access:") &&
    segment.surfaceClass !== "connector"
  ), "fuel-aware route must contain only packed road geometry");
  assert.ok(elapsedMs < 30_000, `request exceeded fuel window: ${elapsedMs}ms`);
  assert.equal(result.diagnostics.timeBudgetExceeded, false);
  assert.ok((result.packIdentity || []).some((identity) =>
    identity.releaseId === "fabric-v4-20260907-01"
  ));
});
