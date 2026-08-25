"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  planFuelChainOnRuntime,
  rankForwardFuel,
  tankCommitBand,
  FUEL_CHAIN_SERVICE_VERSION
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

test("Dirt chooses the mid-range dirt-network station over a farther paved station", async () => {
  const result = await plan("dirt");
  assert.equal(result.ok, true);
  assert.equal(result.stops[0].id, "mid-dirt");
  assert.equal(result.stops[0].dirtPercent, 90);
  assert.equal(result.stationCandidates.length, 2);
});

test("unknown profile plans as Balanced", async () => {
  const unknown = await plan("scenic");
  const balanced = await plan("balanced");
  assert.equal(unknown.ok, true);
  assert.equal(balanced.ok, true);
  assert.equal(unknown.stops[0].id, balanced.stops[0].id);
});

test("all profiles prefer a 50-80% tank-window stop over a wall-stretch station", async () => {
  for (const profile of ["dirt", "balanced", "cleanest"]) {
    const result = await plan(profile);
    assert.equal(result.ok, true, profile);
    assert.equal(result.stops[0].id, "mid-dirt", profile);
  }
});

test("Dirt profile quality outranks a merely comfortable paved pump", async () => {
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
  assert.equal(result.stops[0].id, "early-dirt");
});

test("Balanced profile quality outranks a merely comfortable poor-mix pump", async () => {
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
  assert.equal(result.stops[0].id, "early-balanced");
});

test("Clean rural quality outranks a comfortable station that needs town fallback", async () => {
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
  assert.equal(result.stops[0].id, "early-rural");
});


test("Clean rejects a full-tank lateral Gulf-class pump in favor of a corridor pump", () => {
  assert.equal(typeof FUEL_CHAIN_SERVICE_VERSION, "string");
  assert.match(FUEL_CHAIN_SERVICE_VERSION, /profile-quality-fuel-anchors/);
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
  assert.ok(!ranked.some((row) => row.station.id === "lateral-loop"));
});

test("tank commit band is comfort, then too-early, then desperation", () => {
  assert.equal(tankCommitBand(225_000, 450_000), 0);
  assert.equal(tankCommitBand(360_000, 450_000), 0);
  assert.equal(tankCommitBand(200_000, 450_000), 1);
  assert.equal(tankCommitBand(449_800, 450_000), 2);
});

test("comfort-band ranking beats a wall station; desperation only if comfort is empty", () => {
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
  assert.deepEqual(ranked.map((row) => row.station.id), ["comfort", "early", "wall"]);

  const desperationOnly = rankForwardFuel(
    [wall, { ...wall, station: { id: "wall-closer" }, location: { lat: 45, lon: 1.8 }, graphMeters: 400_000 }],
    start, destination, 450_000, new Set(), "balanced"
  );
  assert.equal(desperationOnly[0].station.id, "wall");
});
