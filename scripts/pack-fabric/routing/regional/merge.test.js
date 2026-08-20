"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { corridorLocationsForRoute } = require("./merge");
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
