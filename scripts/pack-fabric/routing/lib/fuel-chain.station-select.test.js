"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { planFuelChainOnRuntime } = require("./fuel-chain");
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

test("Direct may keep the farther forward station", async () => {
  const result = await plan("direct");
  assert.equal(result.ok, true);
  assert.equal(result.stops[0].id, "far-paved");
});
