"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  coordinateInUrbanBoxes,
  coordinateNearUrbanBoxes,
  remainingChainPathCap,
  reservedChainHopCap,
  topologySeamFromIndex,
  topologySeamCandidatesFromIndex,
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

test("deployment seam index returns later shared vertices when the nearest pin is unusable", () => {
  const near = { coordinate: [-64.27833, 45.87375], osmWayId: "one-way-104", gapMeters: 0 };
  const later = { coordinate: [-64.26109, 45.88166], osmWayId: "two-way-shared", gapMeters: 0 };
  const index = {
    regions: {
      ns: { neighbors: { nb: [near, later] }, urbanCores: [] },
      nb: { neighbors: { ns: [near, later] }, urbanCores: [] }
    }
  };
  const seed = { lon: -64.35, lat: 45.92 };
  const candidates = topologySeamCandidatesFromIndex(seed, ["ns", "nb"], index);
  assert.equal(candidates.length, 2);
  assert.equal(candidates[0].osmWayId, "one-way-104");
  assert.equal(candidates[1].osmWayId, "two-way-shared");
  const primary = topologySeamFromIndex(seed, ["ns", "nb"], index);
  assert.equal(primary.osmWayId, "one-way-104");
  assert.equal(primary.candidates.length, 2);
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


test("V4 border selection follows the rider endpoints instead of a distant preset crossing", () => {
  const row = (osmWayId, lon, access) => ({ osmWayId, coordinate: [lon, 48], gapMeters: 0, edge: { accessForward: access, accessReverse: access } });
  const rows = [row("distant-preset", -69, 0), row("near-public-bridge", -66, 0), row("near-unknown", -65.99, 1), row("closed", -66, 2)];
  const index = { regions: { qc: { neighbors: { nb: rows } }, nb: { neighbors: { qc: rows } } } };
  for (const [start, end] of [[[-66.01, 47.99], [-65.99, 48.01]], [[-65.99, 48.01], [-66.01, 47.99]]]) {
    const seed = { lon: -69, lat: 48, routeStart: { lon: start[0], lat: start[1] }, routeEnd: { lon: end[0], lat: end[1] } };
    const strict = topologySeamCandidatesFromIndex(seed, ["qc", "nb"], index);
    assert.equal(strict[0].osmWayId, "near-public-bridge");
    assert.ok(!strict.some(row => ["near-unknown", "closed"].includes(row.osmWayId)));
    const unknown = topologySeamCandidatesFromIndex({ ...seed, allowUnknown: true }, ["qc", "nb"], index);
    assert.ok(unknown.some(row => row.osmWayId === "near-unknown"));
    assert.ok(!unknown.some(row => row.osmWayId === "closed"));
  }
});

test("shared halo fragments do not qualify as a connection to the rider's road network", () => {
  const { buildGraphFromOsm } = require("./legal-topology/osm-graph");
  const { encodeFromOsmGraph, decodeGraphV4 } = require("./pack-v4");
  const graph = buildGraphFromOsm({ nodes: [[1, 0], [2, 0.01], [3, 0.02], [4, 0.03]].map(([id, lon]) => ({ id, lon, lat: 48, tags: {} })), ways: [[10, [1, 2]], [20, [3, 4]]].map(([id, nodeIds]) => ({ id, nodeIds, tags: { highway: "secondary", motor_vehicle: "yes" } })) });
  const encoded = encodeFromOsmGraph(graph, { regionId: "fixture", sourceEpoch: "test" });
  const pack = decodeGraphV4(encoded.graphBuffer, encoded.geomBuffer);
  const candidates = [{ osmNodeId: "3", osmWayId: "20" }, { osmNodeId: "2", osmWayId: "10" }];
  const pinIndex = Array.from({ length: pack.edgeCount }, (_, i) => i).find(i => String(pack.osmWayIds[i]) === "10");
  const { pinConnectedSeamCandidates } = require("./router");
  assert.deepEqual(pinConnectedSeamCandidates(pack, candidates, [{ edgeIndex: pinIndex }], false), [candidates[1]]);
});
