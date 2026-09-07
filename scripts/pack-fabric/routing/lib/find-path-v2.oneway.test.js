"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { findPathV2 } = require("./find-path-v2");
const { encodeFromV1, decodeGraphV2, decodeGeometryV1 } = require("./pack-v2");

function onewayRuntime() {
  const data = {
    nodeCount: 2,
    nodes: [
      [-64.1880, 45.8071],
      [-64.1890, 45.8071]
    ],
    regionId: "fixture",
    enums: {
      ACCESS_NAME: [
        "motorized_verified",
        "motorized_permissive",
        "motorized_unknown",
        "motorized_restricted",
        "motorized_excluded"
      ],
      SURFACE_NAME: ["paved", "gravel", "access", "track", "unknown"],
      STRUCTURE_NAME: ["none", "bridge", "tunnel", "ford", "ferry"]
    },
    edges: [
      {
        i: "eastbound-104",
        a: 0,
        b: 1,
        m: 100,
        s: 0,
        ac: 0,
        t: 0,
        rt: "freeway",
        conf: "high",
        d: "forward",
        g: [
          [-64.1880, 45.8071],
          [-64.1890, 45.8071]
        ]
      }
    ]
  };
  const { graphBuffer, geomBuffer } = encodeFromV1(data);
  const pack = decodeGraphV2(graphBuffer);
  const geom = decodeGeometryV1(geomBuffer);
  return {
    format: "v2",
    pack,
    geom,
    data: { regionId: "fixture" },
    enums: data.enums
  };
}

const SEARCH = {
  costMode: "distance",
  variety: false,
  boundedSearch: false,
  cityWall: false,
  corridorMeters: 0,
  hardCorridor: false,
  settlementFallback: false,
  pavedOnly: false
};

const POLICY = { motorizedPermissive: true, motorizedUnknown: false };

function match(edgeIndex, coord, distanceAlongM) {
  return {
    edgeIndex,
    edgeId: "eastbound-104",
    coord,
    segmentIndex: 0,
    distanceAlongM,
    edgeMeters: 100,
    roadTrack: "freeway"
  };
}

test("legal travel along a one-way edge completes", () => {
  const runtime = onewayRuntime();
  const path = findPathV2(
    runtime,
    match(0, [-64.1882, 45.8071], 20),
    match(0, [-64.1888, 45.8071], 80),
    "balanced",
    POLICY,
    new Set(),
    undefined,
    SEARCH
  );
  assert.ok(path);
  assert.ok(path.distanceMeters > 0);
});

test("balanced bounded search still completes legal one-way travel", () => {
  const runtime = onewayRuntime();
  const path = findPathV2(
    runtime,
    match(0, [-64.1882, 45.8071], 20),
    match(0, [-64.1888, 45.8071], 80),
    "balanced",
    POLICY,
    new Set(),
    undefined,
    { sessionSeed: 1 }
  );
  assert.ok(path);
  assert.ok(path.distanceMeters > 0);
});

test("snap and virtual legs cannot reverse a one-way carriageway", () => {
  const runtime = onewayRuntime();
  const path = findPathV2(
    runtime,
    match(0, [-64.1888, 45.8071], 80),
    match(0, [-64.1882, 45.8071], 20),
    "balanced",
    POLICY,
    new Set(),
    undefined,
    SEARCH
  );
  assert.equal(path, null);
});
