"use strict";

process.env.ROUTING_USE_REGIONAL = "1";

const test = require("node:test");
const assert = require("node:assert/strict");
const { routeRequest, isLowDirtRoute } = require("./router");

const legs = [
  [[44.76549, -63.33983], [45.66744, -62.34420]],
  [[45.66744, -62.34420], [46.10471, -60.20740]]
];

function request(profile, leg) {
  return {
    locations: leg.map(([lat, lon]) => ({ lat, lon })),
    profile,
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false }
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
