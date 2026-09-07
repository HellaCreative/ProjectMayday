"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "../../../..");
const packRoot = path.join(root, "scripts/pack-fabric/app/data/packs/v4/ns");
process.env.ROUTING_USE_REGIONAL = "1";
process.env.ROUTING_PACKS_V2 = "1";
process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({
  ns: path.join(packRoot, "graph.v4.bin")
});

const { fuelChainRequest } = require("./fuel-chain");

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
    `known Dirt regressed to ${knownDirtPercent.toFixed(1)}%`);
  assert.equal(result.diagnostics.strategy, "foundation_route_partition");
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
