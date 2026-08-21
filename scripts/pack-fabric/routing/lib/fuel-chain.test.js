"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { planFuelChainOnRuntime, rankForwardFuel } = require("./fuel-chain");

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

test("short route does not manufacture a fuel plan", async () => {
  const result = await planFuelChainOnRuntime({
    runtime: lineRuntime(),
    stations: [station("f1", 1)],
    start: { lat: 45, lon: 0 },
    destination: { lat: 45, lon: 1 },
    profile: "balanced",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    usableRangeMeters: 100_000,
    firstLegMaxMeters: 100_000
  });

  assert.equal(result.ok, true);
  assert.deepEqual(result.stops, []);
  assert.equal(result.graphMeters.length, 1);
});
