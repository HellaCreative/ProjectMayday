#!/usr/bin/env node
"use strict";

// Fixed-coordinate reproductions captured from the September 3 device logs.
// These deliberately exercise the production-sized v3 packs and fuel
// sidecars, not synthetic graphs.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const REPO_ROOT = path.resolve(__dirname, "../../..");
const packPath = (region, name) => path.join(
  REPO_ROOT, "scripts/pack-fabric/app/data/packs/v1", region, name
);

process.env.ROUTING_USE_REGIONAL = "1";
process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({
  ns: packPath("ns", "graph.v3.bin"),
  nb: packPath("nb", "graph.v3.bin"),
  qc: packPath("qc", "graph.v3.bin"),
  on: packPath("on", "graph.v3.bin")
});

const { fuelChainRequest } = require("../routing/lib/fuel-chain");

const fuelByRegion = new Map();
function fuelFor(region) {
  if (!fuelByRegion.has(region)) {
    fuelByRegion.set(region, JSON.parse(fs.readFileSync(
      packPath(region, "fuel.v1.json"), "utf8"
    )));
  }
  return fuelByRegion.get(region);
}

function loadFuel(region) {
  return async () => ({
    ok: true,
    regionIds: [region],
    stations: fuelFor(region).stations || [],
    packIdentity: []
  });
}

async function loadRegionFuel(region) {
  return {
    regionId: region,
    stations: fuelFor(region).stations || [],
    packIdentity: { regionId: region }
  };
}

function weightedDirt(routes) {
  const meters = routes.reduce((sum, route) => sum + Number(route.distanceMeters || 0), 0);
  if (!(meters > 0)) return 0;
  return routes.reduce((sum, route) => sum +
    Number(route.distanceMeters || 0) * Number(route.stats && route.stats.dirtPercent || 0), 0
  ) / meters;
}

async function runCase({ id, region, profile, from, to, usableMeters, preferredStationIds = [] }) {
  const started = Date.now();
  const result = await fuelChainRequest({
    profile,
    locations: [from, to],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: {
      motorizedPermissive: true,
      motorizedUnknown: false
    },
    fuel: {
      usableRangeMeters: usableMeters,
      firstLegMaxMeters: usableMeters,
      routeFirstPlan: true,
      riderLegId: id,
      preferredStationIds,
      windowTimeBudgetMs: 30_000
    },
    options: {
      sessionSeed: 0xD1_47_0008,
      backtrackFactor: 4
    }
  }, { loadFuelForLocations: loadFuel(region) });
  const elapsedMs = Date.now() - started;
  assert.equal(result.status, "complete", `${id}: ${result.error || result.message}`);
  const routes = result.routes || [];
  assert.ok(routes.length > 0, `${id}: no routed legs`);
  assert.ok(routes.every((route) => Number(route.distanceMeters) <= usableMeters + 1),
    `${id}: a fuel hop exceeded ${usableMeters}m`);
  assert.ok(elapsedMs < 25_000, `${id}: ${elapsedMs}ms exceeded the regression ceiling`);
  return {
    id,
    elapsedMs,
    stopIds: (result.stops || []).map((stop) => String(stop.id)),
    meters: Math.round(routes.reduce(
      (sum, route) => sum + Number(route.distanceMeters || 0), 0
    )),
    dirtPct: Math.round(weightedDirt(routes) * 10) / 10,
    strategy: result.diagnostics && result.diagnostics.strategy,
    profileRoutes: Number(result.diagnostics && result.diagnostics.profileRouteAttempts || 0),
    foundationPriorityStations: Number(
      result.diagnostics && result.diagnostics.foundationPriorityStations || 0
    ),
    candidates: result.stationCandidates || []
  };
}

async function runCrossRegionCase({ id, profile, from, to, usableMeters }) {
  const started = Date.now();
  const result = await fuelChainRequest({
    profile,
    locations: [from, to],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: {
      motorizedPermissive: true,
      motorizedUnknown: false
    },
    fuel: {
      usableRangeMeters: usableMeters,
      firstLegMaxMeters: usableMeters,
      routeFirstPlan: true,
      ensureDestinationFuelEscape: true,
      windowMaxStops: 4,
      allowPartialWindow: true,
      windowTimeBudgetMs: 20_000,
      riderLegId: id
    },
    options: {
      sessionSeed: 0xD1_47_0008,
      backtrackFactor: 4
    }
  }, { loadRegionFuel });
  const elapsedMs = Date.now() - started;
  assert.equal(result.status, "complete", `${id}: ${result.error || result.message}`);
  assert.ok((result.stops || []).length > 0,
    `${id}: a resumable long-distance fuel window returned no pumps`);
  assert.equal(result.windowComplete, false,
    `${id}: a four-stop window unexpectedly claimed to finish the 2,000+ km ride`);
  assert.ok((result.graphMeters || []).every((meters) => Number(meters) <= usableMeters + 1),
    `${id}: a regional fuel hop exceeded ${usableMeters}m`);
  assert.ok(elapsedMs < 35_000, `${id}: ${elapsedMs}ms exceeded the regression ceiling`);
  return {
    id,
    elapsedMs,
    stopIds: (result.stops || []).map((stop) => String(stop.id)),
    meters: Math.round((result.graphMeters || []).reduce(
      (sum, meters) => sum + Number(meters || 0), 0
    )),
    dirtPct: null,
    strategy: result.diagnostics && result.diagnostics.strategy,
    selectedReason: result.diagnostics && result.diagnostics.selectedReason,
    profileRoutes: Number(result.diagnostics && result.diagnostics.profileRouteAttempts || 0),
    foundationPriorityStations: 0,
    candidates: result.stationCandidates || []
  };
}

async function main() {
  const longCrossRegion = await runCrossRegionCase({
    id: "device-ns-to-ottawa-long-window",
    profile: "dirt",
    from: { lat: 44.764830, lon: -63.340265 },
    to: { lat: 45.645111, lon: -75.907752 },
    usableMeters: 374_000
  });

  const novaScotia = await runCase({
    id: "device-ns-halifax-to-southwest",
    region: "ns",
    profile: "dirt",
    from: { lat: 44.764830, lon: -63.340265 },
    to: { lat: 43.678864, lon: -65.794704 },
    usableMeters: 382_500
  });
  assert.equal(novaScotia.strategy, "foundation_route_partition");
  assert.equal(novaScotia.profileRoutes, 0);

  const centralOntario = await runCase({
    id: "device-on-kingston-to-orillia",
    region: "on",
    profile: "dirt",
    from: { lat: 44.632662, lon: -75.651839 },
    to: { lat: 44.601681, lon: -79.308263 },
    usableMeters: 382_500
  });
  assert.equal(centralOntario.strategy, "foundation_route_partition");
  assert.equal(centralOntario.profileRoutes, 0);
  assert.ok(centralOntario.dirtPct >= 75,
    `central Ontario Dirt fell to ${centralOntario.dirtPct}%`);

  const northernBalanced = await runCase({
    id: "device-on-north-balanced",
    region: "on",
    profile: "balanced",
    from: { lat: 48.717124, lon: -85.788718 },
    to: { lat: 49.690947, lon: -87.041404 },
    usableMeters: 212_500
  });
  const northernDirt = await runCase({
    id: "device-on-north-dirt",
    region: "on",
    profile: "dirt",
    from: { lat: 48.717124, lon: -85.788718 },
    to: { lat: 49.690947, lon: -87.041404 },
    usableMeters: 212_500,
    preferredStationIds: northernBalanced.stopIds
  });
  assert.deepEqual(northernDirt.stopIds, northernBalanced.stopIds,
    "Dirt abandoned the corridor fuel stop selected by Balanced");
  assert.ok(northernDirt.dirtPct >= northernBalanced.dirtPct + 5,
    `Dirt ${northernDirt.dirtPct}% did not improve on Balanced ${northernBalanced.dirtPct}%`);
  assert.ok(northernDirt.candidates.some((candidate) =>
    Number.isFinite(Number(candidate.foundationPriorityCellDistance))
  ), "Dirt did not retain a route-adjacent fuel candidate");

  console.table([
    longCrossRegion, novaScotia, centralOntario, northernBalanced, northernDirt
  ].map((row) => ({
    case: row.id,
    ms: row.elapsedMs,
    meters: row.meters,
    dirt: row.dirtPct == null ? "window" : `${row.dirtPct}%`,
    stops: row.stopIds.join(",") || "none",
    strategy: row.strategy,
    selected: row.selectedReason || "-",
    profileRoutes: row.profileRoutes,
    routePriority: row.foundationPriorityStations
  })));
}

main().catch((error) => {
  console.error(error && error.stack || error);
  process.exitCode = 1;
});
