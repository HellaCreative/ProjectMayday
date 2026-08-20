"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  qualifiesAsUrbanCore,
  settlementRadiusKm
} = require("./pack-region-urban");
const { boxIntersectsPackBbox } = require("../routing/lib/pack-v2");

test("small OSM towns are settlement avoidance, not hard urban walls", () => {
  assert.equal(qualifiesAsUrbanCore("town", 12_421), false);
  assert.ok(settlementRadiusKm("town", 12_421) >= 1.2);
});

test("adjacent urban boxes are embedded only when they overlap pack fabric", () => {
  const waBbox = [-124.74, 45.53, -116.86, 49.08];
  const abbotsford = { minLat: 48.99, maxLat: 49.12, minLon: -122.43, maxLon: -122.23 };
  const calgary = { minLat: 50.85, maxLat: 51.22, minLon: -114.32, maxLon: -113.85 };
  assert.equal(boxIntersectsPackBbox(abbotsford, waBbox), true);
  assert.equal(boxIntersectsPackBbox(calgary, waBbox), false);
});

test("major towns and cities remain hard urban-core walls", () => {
  assert.equal(qualifiesAsUrbanCore("town", 50_000), true);
  assert.equal(qualifiesAsUrbanCore("city", 40_000), true);
  assert.equal(qualifiesAsUrbanCore("city", 4_450), false);
  assert.equal(qualifiesAsUrbanCore("city", 0), true);
});
