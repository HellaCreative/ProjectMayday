"use strict";

process.env.ROUTING_USE_REGIONAL = "1";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

process.env.ROUTING_PACKS_V2 = "1";
process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({
  ns: path.resolve(__dirname, "../../../../DirtTests/Fixtures/DirtLocalPacks/ns/graph.v3.bin")
});

const { routeRequest, isLowDirtRoute, restrictedSummary } = require("./router");
const { shortDirtExcursionEdgeIds } = require("./find-path-v2");
const { metroBlocks, metroEdgeBlocks, METRO_CORE_WALL } = require("./hop-search");

const legs = [
  [[44.76549, -63.33983], [45.66744, -62.34420]],
  [[45.66744, -62.34420], [46.10471, -60.20740]]
];

function request(profile, leg) {
  return {
    locations: leg.map(([lat, lon]) => ({ lat, lon })),
    profile,
    // These are profile-objective tests, not access-policy tests. Allow unknown
    // so legacy CanVec reclassification cannot masquerade as a Dirt-quality
    // regression; adapter and pack lockstep tests own the access boundary.
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: true }
  };
}

for (const [index, leg] of legs.entries()) {
  test(`Nova Scotia Dirt objective leg ${index + 1} is at least 70 percent`, async () => {
    const started = Date.now();
    const result = await routeRequest(request("dirt", leg));
    assert.equal(result.status, "complete");
    assert.ok(result.stats.dirtPercent >= 70, `received ${result.stats.dirtPercent}% dirt`);
    assert.equal(result.lowDirt, false);
    assert.ok(Date.now() - started < 12_000, "route must complete under twelve seconds");
  });
}

test("Nova Scotia Balanced objective stays within five points of 50/50", async () => {
  const started = Date.now();
  const result = await routeRequest(request("balanced", legs[1]));
  assert.equal(result.status, "complete");
  assert.ok(result.stats.dirtPercent >= 45 && result.stats.dirtPercent <= 55,
    `received ${result.stats.dirtPercent}% dirt`);
  assert.ok(Date.now() - started < 12_000, "route must complete under twelve seconds");
});

test("a completed low-scoring Dirt route is flagged instead of discarded", () => {
  assert.equal(isLowDirtRoute("dirt", { stats: { dirtPercent: 30 } }), true);
  assert.equal(isLowDirtRoute("balanced", { stats: { dirtPercent: 30 } }), false);
});

test("an expired Dirt quality search reports degradation instead of a paved success", async () => {
  const result = await routeRequest({
    ...request("dirt", legs[0]),
    options: { deadlineAtMs: Date.now() - 1 }
  });
  assert.equal(result.status, "failed");
  assert.equal(result.error, "search_limit");
  assert.ok((result.warnings || []).some((warning) => warning.code === "search_limit"));
  assert.deepEqual(result.segments, []);
  assert.equal(result.debug.fallback, null);
});

test("Dirt objective remains above 70 percent under a 237.5 km tank cap", async () => {
  const result = await routeRequest({
    ...request("dirt", legs[0]),
    options: { maxPathMeters: 237_500 }
  });
  assert.equal(result.status, "complete");
  assert.ok(result.distanceMeters <= 237_500, `received ${result.distanceMeters} m`);
  assert.ok(result.stats.dirtPercent >= 70, `received ${result.stats.dirtPercent}% dirt`);
});

test.skip("second historical leg has no audited 70% route inside 237.5 km", async () => {
  const result = await routeRequest({
    ...request("dirt", legs[1]),
    options: { maxPathMeters: 237_500 }
  });
  assert.equal(result.status, "complete");
  assert.ok(result.distanceMeters <= 237_500, `received ${result.distanceMeters} m`);
  // Do not lower this product assertion. PHASE7-FIX.md records the audited
  // 25% ceiling and why fuel station selection must avoid this endpoint.
  assert.ok(result.stats.dirtPercent >= 70, `received ${result.stats.dirtPercent}% dirt`);
});

test("Balanced and Clean keep their surface contracts under the same cap", async () => {
  const [balanced, clean] = await Promise.all([
    routeRequest({ ...request("balanced", legs[0]), options: { maxPathMeters: 237_500 } }),
    routeRequest({ ...request("cleanest", legs[0]), options: { maxPathMeters: 237_500 } })
  ]);
  assert.equal(balanced.status, "complete");
  assert.ok(balanced.stats.dirtPercent >= 45 && balanced.stats.dirtPercent <= 55,
    `Balanced received ${balanced.stats.dirtPercent}% dirt`);
  assert.equal(clean.status, "complete");
  assert.ok(clean.stats.dirtPercent <= 15, `Clean received ${clean.stats.dirtPercent}% dirt`);
});

test("Dirt stays within the coherent mix band without Halifax or short dirt teeth", {
  timeout: 30_000
}, async () => {
  const locations = [
    { lat: 44.764830, lon: -63.340265 },
    { lat: 44.944419, lon: -63.326158 }
  ];
  const [dirt, balanced] = await Promise.all([
    routeRequest({
      ...request("dirt", locations.map((point) => [point.lat, point.lon])),
      locations,
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    }),
    routeRequest({
      ...request("balanced", locations.map((point) => [point.lat, point.lon])),
      locations,
      accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
    })
  ]);

  assert.equal(dirt.status, "complete");
  assert.equal(balanced.status, "complete");
  assert.ok(
    dirt.stats.dirtPercent + 5 >= balanced.stats.dirtPercent,
    `Dirt ${dirt.stats.dirtPercent}% fell outside five points of Balanced ${balanced.stats.dirtPercent}%`
  );
  assert.equal(dirt.debug.searchMeta.urbanCoreFallbackUsed, undefined);
  assert.equal(balanced.debug.searchMeta.urbanCoreFallbackUsed, undefined);
  assert.equal(shortDirtExcursionEdgeIds(dirt.segments).size, 0);
  assert.equal(dirt.debug.searchMeta.landPathCompass, "remaining-legal-road-meters");
  assert.equal(dirt.debug.searchMeta.corridorReference, "shortest-legal-road-path");
  assert.equal(dirt.debug.searchMeta.corridorCandidates, undefined);

  const start = [locations[0].lon, locations[0].lat];
  const end = [locations[1].lon, locations[1].lat];
  for (const route of [dirt, balanced]) {
    for (let index = 0; index < route.geometry.length; index += 1) {
      const point = route.geometry[index];
      assert.equal(metroBlocks(point[0], point[1], start, end, METRO_CORE_WALL), false);
      if (index > 0) {
        assert.equal(
          metroEdgeBlocks(route.geometry[index - 1], point, start, end, METRO_CORE_WALL),
          false
        );
      }
    }
  }
});

test("reported southwest Nova Scotia ride avoids Halifax and improves its weak opening", {
  timeout: 30_000
}, async () => {
  const locations = [
    { lat: 44.764830, lon: -63.340265 },
    { lat: 43.612692, lon: -65.798147 }
  ];
  const started = Date.now();
  const result = await routeRequest({
    profile: "dirt",
    locations,
    vehicle: "dual-sport-motorcycle",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: { sessionSeed: 0, backtrackFactor: 4 }
  });

  assert.equal(result.status, "complete");
  assert.equal(result.debug.searchMeta.urbanCoreFallbackUsed, undefined);
  assert.equal(result.debug.fallback, null);
  assert.equal(result.quality.urbanCoreMeters, 0);
  assert.ok(
    result.quality.firstSectionDirtPercent >= 30,
    `first quarter regressed to ${result.quality.firstSectionDirtPercent}% known Dirt`
  );
  assert.ok(
    result.quality.knownDirtPercent >= 60,
    `journey regressed to ${result.quality.knownDirtPercent}% known Dirt`
  );
  assert.ok(Date.now() - started < 12_000, "fixed route must complete under twelve seconds");

  const start = [locations[0].lon, locations[0].lat];
  const end = [locations[1].lon, locations[1].lat];
  for (let index = 0; index < result.geometry.length; index += 1) {
    const point = result.geometry[index];
    assert.equal(metroBlocks(point[0], point[1], start, end, METRO_CORE_WALL), false);
    if (index > 0) {
      assert.equal(
        metroEdgeBlocks(result.geometry[index - 1], point, start, end, METRO_CORE_WALL),
        false
      );
    }
  }
});

test("restricted segment diagnostics expose a filter miss", () => {
  assert.deepEqual(restrictedSummary({
    segments: [{ accessClass: "motorized_restricted", distanceMeters: 125 }]
  }), { restrictedMeters: 125, restrictedReason: "filter_miss" });
  assert.deepEqual(restrictedSummary({ segments: [] }), {
    restrictedMeters: 0,
    restrictedReason: null
  });
});
