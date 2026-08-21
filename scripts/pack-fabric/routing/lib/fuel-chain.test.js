"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  fuelNeedForProfileRide,
  planFuelChainOnRuntime,
  rankForwardFuel
} = require("./fuel-chain");

function lineRuntime() {
  const nodes = [];
  for (let i = 0; i <= 8; i += 1) nodes.push([i * 0.5, 45]);
  const edges = [];
  const adjacency = Array.from({ length: nodes.length }, () => []);
  const edgeGrid = new Map();
  const GRID = 0.01;
  for (let i = 0; i < nodes.length - 1; i += 1) {
    const edge = {
      a: i,
      b: i + 1,
      m: 39_313,
      s: 0,
      ac: 0,
      t: 0,
      rt: "local",
      i: `e${i}`,
      c: 0,
      g: [nodes[i], nodes[i + 1]]
    };
    const edgeIndex = edges.length;
    edges.push(edge);
    adjacency[i].push(edgeIndex);
    adjacency[i + 1].push(edgeIndex);
    const x0 = Math.floor(nodes[i][0] / GRID);
    const x1 = Math.floor(nodes[i + 1][0] / GRID);
    const y = Math.floor(45 / GRID);
    for (let x = x0; x <= x1; x += 1) {
      const key = `${x}:${y}`;
      if (!edgeGrid.has(key)) edgeGrid.set(key, []);
      edgeGrid.get(key).push(edgeIndex);
    }
  }
  return {
    data: { nodeCount: nodes.length, nodes, edges, regionId: "fixture" },
    adjacency,
    edgeGrid,
    GRID,
    enums: {
      SURFACE_NAME: ["paved"],
      ACCESS_NAME: ["motorized_permissive"],
      STRUCTURE_NAME: ["none"]
    }
  };
}

function station(id, lon) {
  return { id, name: id, lat: 45, lon };
}

function fixtureRouteCandidate({ candidate }) {
  return Promise.resolve({
    status: "complete",
    distanceMeters: candidate.graphMeters,
    stats: { dirtPercent: 0 },
    segments: []
  });
}

test("fuel chain is constructed forward from graph-reachable pumps", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("f1", 1), station("f2", 2), station("f3", 3)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 90_000,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: candidate.graphMeters,
      stats: { dirtPercent: 0 },
      segments: []
    })
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops.map((row) => row.id), ["f1", "f2", "f3"]);
  assert.equal(result.graphMeters.length, 4);
  assert.ok(result.graphMeters.every((meters) => meters <= 90_000));
});

test("long fuel chain returns a resumable window capped at three stops", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("f1", 1), station("f2", 2), station("f3", 3)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 90_000,
    minimumFuelStops: 4,
    maxStops: 3,
    allowPartialWindow: true,
    timeBudgetMs: 6_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.equal(result.windowComplete, false);
  assert.deepEqual(result.stops.map((row) => row.id), ["f1", "f2", "f3"]);
  assert.equal(result.graphMeters.length, 3);
});

test("fuel ranking rejects a geographically backward pump", () => {
  const ranked = rankForwardFuel(
    [
      { station: station("back", -0.5), location: { lat: 45, lon: -0.5 }, graphMeters: 50_000 },
      { station: station("forward", 1), location: { lat: 45, lon: 1 }, graphMeters: 80_000 }
    ],
    { lat: 45, lon: 0 },
    { lat: 45, lon: 4 },
    100_000,
    new Set(),
    "dirt"
  );

  assert.deepEqual(ranked.map((row) => row.station.id), ["forward"]);
});

test("a depleted waypoint may use one nearby non-forward pump before resuming forward travel", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [
      station("recovery", 1.75),
      station("forward-1", 2.5),
      station("forward-2", 3.5)
    ],
    start: { lat: 45, lon: 2 },
    destination: { lat: 45, lon: 4 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 90_000,
    firstLegMaxMeters: 30_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.deepEqual(
    result.stops.map((row) => row.id),
    ["recovery", "forward-1", "forward-2"]
  );
  assert.ok(result.graphMeters.every((meters) => meters <= 90_000));
});

test("short route does not manufacture a fuel plan", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("f1", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 1 },
    profile: "balanced",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 100_000,
    firstLegMaxMeters: 100_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops, []);
  assert.equal(result.graphMeters.length, 1);
});

test("profile ride length requires Dirt fuel even when shortest reachability fits", async () => {
  const usable = 237_500;
  const stopsNeeded = fuelNeedForProfileRide(300_000, usable, usable);
  assert.equal(stopsNeeded, 1);

  const dirt = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("mid", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: usable,
    firstLegMaxMeters: usable,
    requireFuelStopBeforeEnd: stopsNeeded > 0,
    minimumFuelStops: stopsNeeded,
    routeCandidate: ({ candidate }) => Promise.resolve({
      status: "complete",
      distanceMeters: candidate.graphMeters,
      stats: { dirtPercent: 80 },
      segments: []
    })
  });
  assert.equal(dirt.ok, true);
  assert.deepEqual(dirt.stops.map((row) => row.id), ["mid"]);
  assert.ok(Math.abs(dirt.stops[0].dirtPercent - 80) <= 10);

  const clean = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("mid", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "cleanest",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: usable,
    firstLegMaxMeters: usable,
    requireFuelStopBeforeEnd: fuelNeedForProfileRide(200_000, usable, usable) > 0,
    routeCandidate: fixtureRouteCandidate
  });
  assert.equal(clean.ok, true);
  assert.deepEqual(clean.stops, []);
});

test("refuel-before-waypoint leaves enough fuel for the known next rider leg", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("early", 1), station("late", 1.5)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 2 },
    profile: "dirt",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 237_500,
    firstLegMaxMeters: 237_500,
    requireFuelStopBeforeEnd: true,
    destinationFuelUsedLimitMeters: 40_000,
    routeCandidate: fixtureRouteCandidate
  });

  assert.equal(result.ok, true);
  assert.equal(result.stops.at(-1).id, "late");
  assert.ok(result.graphMeters.at(-1) <= 40_000);
});
