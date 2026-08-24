"use strict";

process.env.ROUTING_USE_REGIONAL = "1";

const test = require("node:test");
const assert = require("node:assert/strict");
const { routeRequest } = require("./router");

test("NS to NB Dirt fuel leg reserves the final province hop", async () => {
  const result = await routeRequest({
    profile: "dirt",
    locations: [
      { lat: 44.7648664631436, lon: -63.340243694682044, label: "Point 1" },
      { lat: 45.887118, lon: -64.498294, label: "Fuel" }
    ],
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: {
      sessionSeed: 42,
      backtrackFactor: 4,
      maxPathMeters: 279_000,
      regionalHopMinimumMeters: [218_046.15222602652, 45_300.21996504375]
    }
  });

  assert.equal(result.status, "complete", result.message || result.error);
  assert.ok(result.distanceMeters <= 279_000, `received ${result.distanceMeters} m`);
  assert.deepEqual(new Set(result.debug.regionIds), new Set(["ns", "nb"]));
});
