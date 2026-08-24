"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  coordinateInUrbanBoxes,
  coordinateNearUrbanBoxes,
  remainingChainPathCap,
  reservedChainHopCap,
  topologySeamFromIndex,
  echoLegId
} = require("./router");
const { echoLegId: echoFuelLegId } = require("../../api/fuel-chain");

test("route seam echoes canonical legId at response and geometry level", () => {
  const result = echoLegId({ status: "complete", geometry: [[-63, 45], [-62, 46]] }, "leg-2");
  assert.equal(result.legId, "leg-2");
  assert.equal(result.geometryProperties.legId, "leg-2");
});

test("fuel-chain API echoes canonical legId without changing its result", () => {
  const original = { status: "complete", stops: [] };
  const result = echoFuelLegId(original, "leg-2");
  assert.equal(result.legId, "leg-2");
  assert.equal(original.legId, undefined);
});

test("an intermediate seam inside an urban core is rejected", () => {
  const abbotsford = { minLat: 49.0, maxLat: 49.14, minLon: -122.45, maxLon: -122.15 };
  assert.equal(coordinateInUrbanBoxes([-122.2163631, 49.0153497], [abbotsford]), true);
  assert.equal(coordinateInUrbanBoxes([-119.696083, 48.987387], [abbotsford]), false);
});

test("an intermediate seam beside an urban core keeps a five-kilometre buffer", () => {
  const abbotsford = { minLat: 48.99, maxLat: 49.12, minLon: -122.43, maxLon: -122.25 };
  assert.equal(coordinateNearUrbanBoxes([-122.2163631, 49.0153497], [abbotsford]), true);
  assert.equal(coordinateNearUrbanBoxes([-119.696083, 48.987387], [abbotsford]), false);
});

test("fuel distance ceiling is cumulative across regional hops", () => {
  assert.equal(remainingChainPathCap({ maxPathMeters: 237_500 }, 0), 237_500);
  assert.equal(remainingChainPathCap({ maxPathMeters: 237_500 }, 151_250), 86_250);
  assert.equal(remainingChainPathCap({}, 151_250), null);
});

test("fuel distance ceiling reserves every later regional hop", () => {
  const options = {
    maxPathMeters: 279_000,
    regionalHopMinimumMeters: [218_046, 45_300]
  };
  assert.equal(reservedChainHopCap(options, 0, 0, 2), 233_700);
  assert.equal(reservedChainHopCap(options, 230_000, 1, 2), 49_000);
  assert.equal(reservedChainHopCap({ maxPathMeters: 279_000 }, 0, 0, 2), 279_000);
});

test("deployment seam index resolves a shared non-urban OSM vertex without loading graphs", () => {
  const coordinate = [-120, 49];
  const row = { coordinate, osmWayId: "42", gapMeters: 0 };
  const index = {
    regions: {
      bc: { neighbors: { wa: [row] }, urbanCores: [] },
      wa: { neighbors: { bc: [row] }, urbanCores: [] }
    }
  };
  const seam = topologySeamFromIndex({ lon: -120.1, lat: 49 }, ["bc", "wa"], index);
  assert.equal(seam.ok, true);
  assert.equal(seam.authoritative, true);
  assert.equal(seam.osmWayId, "42");
  assert.equal(seam.seamMethod, "same-osm-way-and-vertex-index");
});

test("deployment seam index rejects authored seams inside an urban wall", () => {
  const coordinate = [-120, 49];
  const row = { coordinate, osmWayId: "42", gapMeters: 0 };
  const wall = { minLon: -120.01, maxLon: -119.99, minLat: 48.99, maxLat: 49.01 };
  const index = {
    regions: {
      bc: { neighbors: { wa: [row] }, urbanCores: [wall] },
      wa: { neighbors: { bc: [row] }, urbanCores: [] }
    }
  };
  const seam = topologySeamFromIndex({ lon: -120.1, lat: 49 }, ["bc", "wa"], index);
  assert.equal(seam.ok, false);
  assert.equal(seam.authoritative, true);
  assert.equal(seam.reason, "no_non_urban_shared_osm_seam");
});
