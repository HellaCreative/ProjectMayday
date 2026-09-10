"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  corridorLocationsForRoute,
  shortestRegionPath
} = require("./merge");

test("Nova Scotia and Newfoundland use their topology-proven direct ferry", () => {
  assert.deepEqual(shortestRegionPath("ns", "nl"), ["ns", "nl"]);

  const points = corridorLocationsForRoute([
    { lon: -60.251, lat: 46.207 },
    { lon: -59.1367, lat: 47.5721 }
  ], { profile: "cleanest", forChain: true });

  assert.equal(points.length, 3);
  assert.deepEqual(points[1].between, ["nl", "ns"]);
});

test("Nova Scotia and Prince Edward Island use their topology-proven direct ferry", () => {
  assert.deepEqual(shortestRegionPath("ns", "pe"), ["ns", "pe"]);

  const points = corridorLocationsForRoute([
    { lon: -63.288, lat: 45.665 },
    { lon: -62.65, lat: 46.2 }
  ], { profile: "cleanest", forChain: true });

  assert.equal(points.length, 3);
  assert.deepEqual(points[1].between, ["ns", "pe"]);
});

test("Maine chains to New Brunswick across the Calais–St. Stephen land border", () => {
  assert.deepEqual(shortestRegionPath("me", "nb"), ["me", "nb"]);
});
const { metroBlocks } = require("../lib/hop-search");

test("Clean long-haul chaining never manufactures city-core waypoints", () => {
  const start = { lon: -63.57, lat: 44.65 };
  const end = { lon: -123.15, lat: 49.70 };
  const points = corridorLocationsForRoute([start, end], {
    profile: "cleanest",
    forChain: true
  });
  assert.ok(points.length > 2);
  for (const point of points.slice(1, -1)) {
    assert.notEqual(point.role, "spine");
    assert.equal(
      metroBlocks(point.lon, point.lat, [start.lon, start.lat], [end.lon, end.lat]),
      false
    );
  }
});

require('node:test')('NS-PE selection includes the bridge region without changing local rides', () => {
  const assert = require('node:assert/strict');
  const { regionsForRoute } = require('./merge');
  assert.deepEqual(regionsForRoute(['ns','pe']), ['nb','ns','pe']);
  assert.deepEqual(regionsForRoute(['pe','ns']), ['nb','ns','pe']);
  assert.deepEqual(regionsForRoute(['ns','nb']), ['nb','ns']);
  assert.deepEqual(regionsForRoute(['pe']), ['pe']);
});
