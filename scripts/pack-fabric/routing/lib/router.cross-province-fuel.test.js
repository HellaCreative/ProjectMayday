"use strict";

process.env.ROUTING_USE_REGIONAL = "1";

const test = require("node:test");
const assert = require("node:assert/strict");
const { routeRequest } = require("./router");
const { planCrossRegionFuelChain } = require("./fuel-chain");

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

test("one-stop fuel window hands every regional minimum to the committed route", async () => {
  const start = { lat: 44.764863437891236, lon: -63.340304626331005 };
  const pump = {
    id: "osm:w330696506",
    lat: 45.908655,
    lon: -64.374146,
    name: "Esso"
  };
  const destination = { lat: 46.192496, lon: -64.242925 };
  const segmentResults = [
    {
      ok: true,
      stops: [],
      graphMeters: [218_050.6],
      stationCandidates: [],
      windowComplete: true,
      diagnostics: {}
    },
    {
      ok: true,
      stops: [pump],
      graphMeters: [8_730.8],
      stationCandidates: [],
      windowComplete: false,
      diagnostics: {}
    }
  ];
  const fuelWindow = await planCrossRegionFuelChain({
    profile: "cleanest",
    locations: [start, destination],
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: { cleanMetroMultiplier: 2, avoidMotorways: true }
  }, {
    mode: "canada-chain",
    regionIds: ["ns", "nb"]
  }, {
    usableRangeMeters: 248_000,
    firstLegMaxMeters: 248_000,
    windowMaxStops: 1,
    allowPartialWindow: true,
    windowTimeBudgetMs: 5_800,
    forwardFeeler: true
  }, {
    resolveChainSeamWaypoints: async () => ({
      ok: true,
      waypoints: [
        { ...start, resolvedRegionId: "ns" },
        {
          lat: 45.92,
          lon: -64.35,
          role: "seam",
          between: ["nb", "ns"],
          resolvedRegionId: "ns"
        },
        { ...destination, resolvedRegionId: "nb" }
      ]
    }),
    loadRegionFuel: async (regionId) => ({
      stations: [pump],
      packIdentity: { regionId }
    }),
    loadGraphsForRequest: async () => ({ packIdentity: [] }),
    planFuelChainOnRuntime: async () => segmentResults.shift()
  });

  assert.deepEqual(fuelWindow.graphMeters, [218_050.6, 8_730.8]);
  const result = await routeRequest({
    profile: "cleanest",
    locations: [start, pump],
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: {
      sessionSeed: 42,
      backtrackFactor: 4,
      cleanMetroMultiplier: 2,
      avoidMotorways: true,
      maxPathMeters: 248_000,
      regionalHopMinimumMeters: fuelWindow.graphMeters
    }
  });

  assert.equal(result.status, "complete", result.message || result.error);
  assert.ok(result.distanceMeters <= 248_000, `received ${result.distanceMeters} m`);
  assert.deepEqual(new Set(result.debug.regionIds), new Set(["ns", "nb"]));
});
