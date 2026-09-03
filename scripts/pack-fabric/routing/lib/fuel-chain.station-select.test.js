"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  planFuelChainOnRuntime,
  rankForwardFuel,
  tankCommitBand,
  compareChainPlans,
  FUEL_CHAIN_SERVICE_VERSION,
  fuelChainRequest
} = require("./fuel-chain");
const { lineRuntime } = require("./fuel-chain.test-fixture");

function station(id, lon) {
  return { id, name: id, lat: 45, lon };
}

function candidateRouter({ candidate, profile }) {
  const dirtPercent = candidate.station.id === "mid-dirt" ? 90 : 10;
  return Promise.resolve({
    status: "complete",
    distanceMeters: candidate.graphMeters,
    stats: { dirtPercent },
    segments: [{ edgeId: `${profile}-${candidate.station.id}`, distanceMeters: candidate.graphMeters }]
  });
}

async function plan(profile) {
  return planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("mid-dirt", 1), station("far-paved", 1.5)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2.5 },
    profile,
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 130_000,
    firstLegMaxMeters: 130_000,
    routeCandidate: candidateRouter
  });
}

test("Dirt preserves forward progress before using surface quality as a tiebreaker", async () => {
  const result = await plan("dirt");
  assert.equal(result.ok, true);
  assert.equal(result.stops[0].id, "far-paved");
  assert.equal(result.stops[0].dirtPercent, 10);
  assert.ok(result.stationCandidates.length >= 2);
});

test("route-first and fuel selection load one shared request runtime", async () => {
  let runtimeLoads = 0;
  let routeCalls = 0;
  const result = await fuelChainRequest({
    legId: "shared-runtime-leg",
    locations: [
      { lat: 44.75, lon: -63.6 },
      { lat: 44.85, lon: -63.4 }
    ],
    profile: "balanced",
    fuel: {
      routeFirstPlan: true,
      usableRangeMeters: 100_000,
      firstLegMaxMeters: 100_000,
      windowTimeBudgetMs: 15_000
    }
  }, {
    loadGraphsForRequest: async () => {
      runtimeLoads += 1;
      return {
        packIdentity: [],
        loadDiagnostics: { fetchMs: 1, decodeMs: 1, gridMs: 1 }
      };
    },
    loadFuelForLocations: async () => ({
      ok: true,
      stations: [station("available", -63.5)],
      regionIds: ["ns"],
      packIdentity: [],
      loadDiagnostics: { fetchMs: 1, cacheHit: false }
    }),
    routeOnRuntime: async (body, selection, runtime) => {
      routeCalls += 1;
      assert.equal(runtime.packIdentity.length, 0);
      assert.equal(selection.ok, true);
      return {
        status: "complete",
        distanceMeters: 20_000,
        geometry: [[-63.6, 44.75], [-63.4, 44.85]],
        debug: { packIdentity: [] }
      };
    }
  });

  assert.equal(result.status, "complete");
  assert.equal(runtimeLoads, 1);
  assert.equal(routeCalls, 1);
  assert.equal(result.routes[0].legId, "shared-runtime-leg");
  assert.equal(result.routes[0].geometryProperties.legId, "shared-runtime-leg");
  assert.equal(result.diagnostics.routeFirstSharedRuntime, true);
});

test("candidate approach and continuation proofs stay on the loaded request runtime", async () => {
  let routeCalls = 0;
  const runtime = lineRuntime();
  const result = await planFuelChainOnRuntime({
    runtime,
    stations: [station("forward-pump", 1.5)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2.5 },
    profile: "balanced",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 130_000,
    firstLegMaxMeters: 130_000,
    graphResolution: { ok: true, mode: "single-v3", regionIds: ["ns"] },
    routeOnLoadedRuntime: async (routeBody, selection, loadedRuntime) => {
      routeCalls += 1;
      assert.equal(selection.regionIds[0], "ns");
      assert.equal(loadedRuntime, runtime);
      const from = routeBody.locations[0];
      const to = routeBody.locations[1];
      const distanceMeters = Math.abs(to.lon - from.lon) * 80_000;
      return {
        status: "complete",
        distanceMeters,
        stats: { dirtPercent: 50 },
        segments: [{ edgeId: `shared-${routeCalls}`, distanceMeters }]
      };
    }
  });

  assert.equal(result.ok, true);
  assert.ok(routeCalls >= 2, "expected an approach and continuation proof");
  assert.equal(result.diagnostics.profileRoutesSharedRuntime, true);
});

test("unknown profile plans as Balanced", async () => {
  const unknown = await plan("scenic");
  const balanced = await plan("balanced");
  assert.equal(unknown.ok, true);
  assert.equal(balanced.ok, true);
  assert.equal(unknown.stops[0].id, balanced.stops[0].id);
});

test("all profiles preserve forward progress after search opens", async () => {
  for (const profile of ["dirt", "balanced", "cleanest"]) {
    const result = await plan(profile);
    assert.equal(result.ok, true, profile);
    assert.equal(result.stops[0].id, "far-paved", profile);
  }
});

test("forward progress outranks an early Dirt-quality pump", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("early-dirt", 0.5), station("comfort-paved", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 130_000,
    firstLegMaxMeters: 130_000,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: candidate.graphMeters,
      stats: { dirtPercent: candidate.station.id === "early-dirt" ? 92 : 8 },
      segments: [{ edgeId: candidate.station.id, distanceMeters: candidate.graphMeters }]
    })
  });
  assert.equal(result.ok, true);
  assert.equal(result.stops[0].id, "comfort-paved");
});

test("forward progress outranks an early Balanced-quality pump", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("early-balanced", 0.5), station("comfort-dirt", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "balanced",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 130_000,
    firstLegMaxMeters: 130_000,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: candidate.graphMeters,
      stats: { dirtPercent: candidate.station.id === "early-balanced" ? 50 : 95 },
      segments: [{ edgeId: candidate.station.id, distanceMeters: candidate.graphMeters }]
    })
  });
  assert.equal(result.ok, true);
  assert.equal(result.stops[0].id, "comfort-dirt");
});

test("forward progress outranks an early Clean-quality pump", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("early-rural", 0.5), station("comfort-town", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "cleanest",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 130_000,
    firstLegMaxMeters: 130_000,
    avoidMotorways: true,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: candidate.graphMeters,
      stats: { dirtPercent: 0 },
      segments: [{
        edgeId: candidate.station.id,
        distanceMeters: candidate.graphMeters,
        trackClass: "secondary"
      }],
      debug: {
        searchMeta: {
          settlementFallbackUsed: candidate.station.id === "comfort-town"
        }
      }
    })
  });
  assert.equal(result.ok, true);
  assert.equal(result.stops[0].id, "comfort-town");
});


test("Clean rejects a full-tank lateral Gulf-class pump in favor of a corridor pump", () => {
  assert.equal(typeof FUEL_CHAIN_SERVICE_VERSION, "string");
  assert.match(FUEL_CHAIN_SERVICE_VERSION, /polygon-owned-endpoints/);
  // Halifax-ish → Tatamagouche-ish geometry: Wallace Gulf is nearly a full tank
  // sideways; Truro sits on the corridor with a shorter complete chain.
  const start = { lat: 44.764823, lon: -63.340271 };
  const destination = { lat: 45.636595, lon: -63.056267 };
  const foundationMeters = 252_989;
  const gulf = {
    station: { id: "osm:n11084635754", name: "Gulf Wallace" },
    location: { lat: 45.962505, lon: -63.883625 },
    graphMeters: 237_278,
    remainingGraphMeters: 119_390,
    dirtAdjacent: false
  };
  const truro = {
    station: { id: "truro-corridor", name: "Truro corridor" },
    location: { lat: 45.365, lon: -63.280 },
    graphMeters: 180_000,
    remainingGraphMeters: 75_000,
    dirtAdjacent: false
  };
  const ranked = rankForwardFuel(
    [gulf, truro],
    start,
    destination,
    237_500,
    new Set(),
    "cleanest",
    null,
    foundationMeters,
    false
  );
  assert.ok(ranked.length >= 1, "expected at least one forward pump");
  assert.equal(ranked[0].station.id, "truro-corridor");
  assert.ok(!ranked.some((row) => row.station.id === gulf.station.id),
    "Gulf Wallace must not remain forward after chain-coherence gates");
});

test("Dirt rejects a remote lateral pump when a forward corridor pump exists", () => {
  const start = { lat: 44.764823, lon: -63.340271 };
  const destination = { lat: 45.644252, lon: -60.983077 };
  const lateral = {
    station: { id: "lateral-loop", name: "Lateral loop" },
    location: { lat: 45.85, lon: -63.2 },
    graphMeters: 210_000,
    remainingGraphMeters: 240_000,
    dirtAdjacent: true
  };
  const forward = {
    station: { id: "forward", name: "Forward" },
    location: { lat: 45.25, lon: -62.1 },
    graphMeters: 160_000,
    remainingGraphMeters: 170_000,
    dirtAdjacent: false
  };
  const ranked = rankForwardFuel(
    [lateral, forward], start, destination, 218_500, new Set(),
    "dirt", null, 430_000, false
  );
  assert.equal(ranked[0].station.id, "forward");
  assert.ok(ranked.some((row) => row.station.id === "lateral-loop"),
    "obstacle-aware fallback should remain behind the coherent pump");
});

test("Nova Scotia regression demotes the northwest overshoot beyond the rider waypoint", () => {
  const start = { lat: 44.764839, lon: -63.340268 };
  const destination = { lat: 45.399717, lon: -62.495696 };
  const overshoot = {
    station: { id: "grotesque-overshoot" },
    location: { lat: 45.707419, lon: -63.284407 },
    graphMeters: 205_000,
    remainingGraphMeters: 90_000
  };
  const onJourney = {
    station: { id: "on-journey" },
    location: { lat: 45.17, lon: -62.82 },
    graphMeters: 125_000,
    remainingGraphMeters: 55_000
  };
  const ranked = rankForwardFuel(
    [overshoot, onJourney], start, destination, 250_000, new Set(),
    "dirt", null, 180_000, false
  );
  assert.equal(ranked[0].station.id, "on-journey");
  assert.ok(!ranked.some((row) => row.station.id === "grotesque-overshoot"));
});

test("tank commit band watches at half range and prefers the 70 percent zone", () => {
  assert.equal(tankCommitBand(225_000, 450_000), 1);
  assert.equal(tankCommitBand(360_000, 450_000), 0);
  assert.equal(tankCommitBand(200_000, 450_000), 2);
  assert.equal(tankCommitBand(449_800, 450_000), 0);
  assert.equal(tankCommitBand(40_000, 100_000, 140_000), 1);
  assert.equal(tankCommitBand(60_000, 100_000, 140_000), 0);
  assert.equal(tankCommitBand(20_000, 100_000, 140_000), 2);
});

test("search-open candidates preserve progress and early pumps remain fallback", () => {
  const start = { lat: 45, lon: 0 };
  const destination = { lat: 45, lon: 5 };
  const comfort = {
    station: { id: "comfort" },
    location: { lat: 45, lon: 1.2 },
    graphMeters: 280_000,
    remainingGraphMeters: 200_000
  };
  const wall = {
    station: { id: "wall" },
    location: { lat: 45, lon: 2.0 },
    graphMeters: 449_800,
    remainingGraphMeters: 80_000
  };
  const early = {
    station: { id: "early" },
    location: { lat: 45, lon: 0.6 },
    graphMeters: 180_000,
    remainingGraphMeters: 300_000
  };
  const ranked = rankForwardFuel(
    [wall, early, comfort], start, destination, 450_000, new Set(), "dirt"
  );
  assert.deepEqual(ranked.map((row) => row.station.id), ["wall", "comfort", "early"]);

  const desperationOnly = rankForwardFuel(
    [wall, { ...wall, station: { id: "wall-closer" }, location: { lat: 45, lon: 1.8 }, graphMeters: 400_000 }],
    start, destination, 450_000, new Set(), "balanced"
  );
  assert.equal(desperationOnly[0].station.id, "wall-closer");
});

test("a complete one-stop chain beats a three-stop chain", () => {
  const town = {
    complete: true,
    stops: [{ id: "town" }],
    graphMeters: [100_000, 80_000],
    quality: {
      meters: 180_000, dirtMeters: 0, cleanFallbackCount: 1,
      cleanMajorRoadMeters: 60_000, backtrackMeters: 0
    }
  };
  const rural = {
    complete: true,
    stops: [{ id: "east-1" }, { id: "east-2" }, { id: "east-3" }],
    graphMeters: [60_000, 60_000, 60_000, 40_000],
    quality: {
      meters: 220_000, dirtMeters: 0, cleanFallbackCount: 0,
      cleanMajorRoadMeters: 0, backtrackMeters: 0
    }
  };
  assert.ok(compareChainPlans(town, rural, "cleanest", 130_000) < 0);
});

test("minimum stop count ranks first after down-and-back stems are rejected", () => {
  const arc = {
    complete: true,
    stops: [{ id: "arc-1" }, { id: "arc-2" }],
    graphMeters: [70_000, 70_000, 40_000],
    quality: {
      meters: 180_000, dirtMeters: 108_000, cleanFallbackCount: 0,
      cleanMajorRoadMeters: 0, backtrackMeters: 0
    }
  };
  const lollipop = {
    complete: true,
    stops: [{ id: "loop" }],
    graphMeters: [90_000, 70_000],
    quality: {
      meters: 160_000, dirtMeters: 112_000, cleanFallbackCount: 0,
      cleanMajorRoadMeters: 0, backtrackMeters: 32_000
    }
  };
  assert.ok(compareChainPlans(lollipop, arc, "dirt", 130_000) < 0);
});
