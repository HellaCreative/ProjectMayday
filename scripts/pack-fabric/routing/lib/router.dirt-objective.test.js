"use strict";

process.env.ROUTING_USE_REGIONAL = "1";

const test = require("node:test");
const assert = require("node:assert/strict");
const { routeRequest, isLowDirtRoute, restrictedSummary } = require("./router");

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
    assert.ok(Date.now() - started < 3000, "route must complete under three seconds");
  });
}

test("Nova Scotia Balanced objective stays within five points of 50/50", async () => {
  const started = Date.now();
  const result = await routeRequest(request("balanced", legs[1]));
  assert.equal(result.status, "complete");
  assert.ok(result.stats.dirtPercent >= 45 && result.stats.dirtPercent <= 55,
    `received ${result.stats.dirtPercent}% dirt`);
  assert.ok(Date.now() - started < 3000, "route must complete under three seconds");
});

test("a completed low-scoring Dirt route is flagged instead of discarded", () => {
  assert.equal(isLowDirtRoute("dirt", { stats: { dirtPercent: 30 } }), true);
  assert.equal(isLowDirtRoute("balanced", { stats: { dirtPercent: 30 } }), false);
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

test("restricted segment diagnostics expose a filter miss", () => {
  assert.deepEqual(restrictedSummary({
    segments: [{ accessClass: "motorized_restricted", distanceMeters: 125 }]
  }), { restrictedMeters: 125, restrictedReason: "filter_miss" });
  assert.deepEqual(restrictedSummary({ segments: [] }), {
    restrictedMeters: 0,
    restrictedReason: null
  });
});
