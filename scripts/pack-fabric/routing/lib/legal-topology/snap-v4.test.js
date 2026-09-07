"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { buildGraphFromOsm } = require("./osm-graph");
const {
  legalSnap,
  legalSnapDetailed,
  selectConnectedSnapPair
} = require("./snap");
const { tapRadiusMeters, V4_SNAP_CAP_M, V3_SNAP_CAP_M } = require("./tap-radius");
const { findPathV4 } = require("./find-path-v4");
const { encodeFromOsmGraph, decodeGraphV4 } = require("../pack-v4");
const { decodeGeometryV1 } = require("../pack-v2");

function node(id, lon, lat, tags = {}) {
  return { id, lon, lat, tags };
}
function way(id, nodeIds, tags) {
  return { id, nodeIds, tags };
}
function packed(osm) {
  const graph = buildGraphFromOsm(osm);
  const encoded = encodeFromOsmGraph(graph, { regionId: "fix", sourceEpoch: "epoch-1" });
  const pack = decodeGraphV4(encoded.graphBuffer, encoded.geomBuffer);
  const geom = decodeGeometryV1(encoded.geomBuffer);
  return { pack, geom };
}

test("tap radius is zoom-aware and capped at 2000 m for V4", () => {
  const yarmouth = tapRadiusMeters({ zoom: 10, lat: 43.65, graphBinaryVersion: 4 });
  assert.ok(yarmouth >= 1700);
  assert.ok(yarmouth <= V4_SNAP_CAP_M);
  const street = tapRadiusMeters({ zoom: 16, lat: 43.65, graphBinaryVersion: 4 });
  assert.ok(street < 250);
  assert.equal(tapRadiusMeters({ requestedMeters: 5000, graphBinaryVersion: 4 }), V4_SNAP_CAP_M);
  assert.equal(tapRadiusMeters({ requestedMeters: 5000, graphBinaryVersion: 3 }), V3_SNAP_CAP_M);
});

test("Yarmouth harbour coarse-zoom tap prefers the connected town road", () => {
  const osm = {
    nodes: [
      node(1, -65.7749, 43.6486),
      node(2, -65.7755, 43.6490),
      node(10, -65.7535, 43.6534),
      node(11, -65.7528, 43.6539),
      node(20, -63.2015, 45.3904),
      node(21, -63.2100, 45.3904),
      node(22, -64.5, 44.5)
    ],
    ways: [
      way(100, [1, 2], { highway: "service", name: "disconnected-pier" }),
      way(200, [10, 11], { highway: "secondary", name: "town-road" }),
      way(300, [20, 21], { highway: "trunk", name: "start-road" }),
      way(400, [21, 22, 10], { highway: "trunk", name: "inland-connector" })
    ]
  };
  const { pack, geom } = packed(osm);
  const harbour = { lat: 43.648606, lon: -65.774864 };
  const start = { lat: 45.390440, lon: -63.201514 };
  const radius = tapRadiusMeters({ zoom: 10, lat: harbour.lat, graphBinaryVersion: 4 });
  const startCands = legalSnap(pack, geom, start, { maxMeters: radius, intentBearingDeg: 240 });
  const endCands = legalSnap(pack, geom, harbour, { maxMeters: radius, intentBearingDeg: 60 });
  assert.ok(endCands.length >= 2, "harbour tap must see pier and town within zoom radius");
  const picked = selectConnectedSnapPair(pack, startCands, endCands, { allowUnknown: false });
  assert.equal(picked.ok, true);
  assert.notEqual(String(picked.end.osmWayId), "100");
  assert.ok(["200", "400"].includes(String(picked.end.osmWayId)));
  assert.ok(picked.rejections.some((row) => row.reason === "disconnected_component"));
  const ride = findPathV4(pack, geom, start, harbour, {
    zoom: 10,
    intentBearingDeg: 240,
    maxMeters: radius
  });
  assert.equal(ride.ok, true);
  assert.ok(!ride.osmWayIds.map(String).includes("100"));
});

test("divided highway snap keeps heading scores, not nearest edge-index", () => {
  const osm = {
    nodes: [
      node(1, -64.19, 45.80779),
      node(2, -64.21, 45.80779),
      node(3, -64.21, 45.80731),
      node(4, -64.19, 45.80731)
    ],
    ways: [
      way(537982310, [1, 2], { highway: "motorway", oneway: "yes", name: "westbound" }),
      way(537982311, [3, 4], { highway: "motorway", oneway: "yes", name: "eastbound" })
    ]
  };
  const { pack, geom } = packed(osm);
  const mid = { lat: 45.80755, lon: -64.2 };
  const west = legalSnapDetailed(pack, geom, mid, { headingDeg: 270, intentBearingDeg: 270 });
  const east = legalSnapDetailed(pack, geom, mid, { headingDeg: 90, intentBearingDeg: 90 });
  assert.equal(String(west.candidates[0].osmWayId), "537982310");
  assert.equal(west.candidates[0].score <= (west.candidates[1] && west.candidates[1].score || Infinity), true);
  assert.equal(String(east.candidates[0].osmWayId), "537982311");
  assert.ok(west.rejections.some((row) => row.reason === "median_opposite_carriageway" || row.reason === "prohibited_direction"));
});

test("disconnected service road is rejected when a connected candidate exists", () => {
  const osm = {
    nodes: [
      node(1, 0, 0),
      node(2, 0.01, 0),
      node(3, 0.005, 0.0004),
      node(4, 0.006, 0.0004)
    ],
    ways: [
      way(1, [1, 2], { highway: "residential" }),
      way(2, [3, 4], { highway: "service" })
    ]
  };
  const { pack, geom } = packed(osm);
  const start = legalSnap(pack, geom, { lat: 0, lon: 0 }, { maxMeters: 80 });
  const end = legalSnap(pack, geom, { lat: 0.0004, lon: 0.005 }, { maxMeters: 80 });
  const picked = selectConnectedSnapPair(pack, start, end, { allowUnknown: false });
  assert.equal(picked.ok, true);
  assert.equal(String(picked.end.osmWayId), "1");
  assert.ok(picked.rejections.some((row) => row.reason === "disconnected_component"));
});

test("unknown trail is skipped unless Allow Unknown", () => {
  const osm = {
    nodes: [
      node(1, 0, 0),
      node(2, 0.002, 0)
    ],
    ways: [
      way(9, [1, 2], { highway: "track", access: "unknown" })
    ]
  };
  const { pack, geom } = packed(osm);
  const off = legalSnapDetailed(pack, geom, { lat: 0, lon: 0.001 }, { maxMeters: 200, allowUnknown: false });
  const on = legalSnapDetailed(pack, geom, { lat: 0, lon: 0.001 }, { maxMeters: 200, allowUnknown: true });
  const denied = off.rejections.some((row) => row.reason === "unknown_trail" || row.reason === "inaccessible");
  assert.ok(denied || off.candidates.length === 0);
  assert.equal(off.candidates.length, 0);
  assert.ok(on.candidates.length > 0);
});

test("barrier-blocked road is not a legal snap", () => {
  const osm = {
    nodes: [
      node(1, 0, 0, { barrier: "gate", locked: "yes" }),
      node(2, 0.001, 0)
    ],
    ways: [
      way(8, [1, 2], { highway: "residential" })
    ]
  };
  const { pack, geom } = packed(osm);
  const detailed = legalSnapDetailed(pack, geom, { lat: 0, lon: 0.0005 }, { maxMeters: 80 });
  assert.equal(detailed.candidates.length, 0);
  assert.ok(detailed.rejections.some((row) => row.reason === "inaccessible" || row.reason === "prohibited_direction"));
});

test("no valid road within the safe bound is a snap failure", () => {
  const osm = {
    nodes: [
      node(1, 0, 0),
      node(2, 0.001, 0)
    ],
    ways: [
      way(1, [1, 2], { highway: "residential" })
    ]
  };
  const { pack, geom } = packed(osm);
  const far = { lat: 1, lon: 1 };
  const detailed = legalSnapDetailed(pack, geom, far, { maxMeters: 200 });
  assert.equal(detailed.candidates.length, 0);
  const ride = findPathV4(pack, geom, far, { lat: 1.001, lon: 1.001 }, { maxMeters: 200 });
  assert.equal(ride.ok, false);
  assert.ok(ride.reason === "no_snap" || ride.reason === "no_legal_snap" || ride.reason === "no_connected_candidate");
});
