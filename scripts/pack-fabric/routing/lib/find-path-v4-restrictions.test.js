"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { buildGraphFromOsm } = require("./legal-topology/osm-graph");
const { encodeFromOsmGraph, decodeGraphV4 } = require("./pack-v4");
const { decodeGeometryV1 } = require("./pack-v2");
const { findPathV2 } = require("./find-path-v2");

function fixture() {
  const osm = {
    nodes: [
      { id: 1, lon: 0, lat: 0 },
      { id: 2, lon: 0.001, lat: 0 },
      { id: 3, lon: 0.002, lat: 0 },
      { id: 4, lon: 0.003, lat: 0 },
      { id: 5, lon: 0.004, lat: 0 },
      { id: 6, lon: 0.001, lat: 0.001 },
      { id: 7, lon: 0.002, lat: 0.001 }
    ],
    ways: [
      { id: 10, nodeIds: [1, 2], tags: { highway: "residential" } },
      { id: 11, nodeIds: [2, 3, 4], tags: { highway: "residential" } },
      { id: 12, nodeIds: [4, 5], tags: { highway: "residential" } },
      { id: 13, nodeIds: [6, 2], tags: { highway: "residential" } },
      { id: 14, nodeIds: [3, 7], tags: { highway: "residential" } }
    ],
    relations: [{
      id: 100,
      members: [
        { type: "way", ref: 10, role: "from" },
        { type: "way", ref: 11, role: "via" },
        { type: "way", ref: 12, role: "to" }
      ],
      tags: { type: "restriction", restriction: "no_straight_on" }
    }]
  };
  const graph = buildGraphFromOsm(osm);
  const encoded = encodeFromOsmGraph(graph, { regionId: "fixture", sourceEpoch: "fixture" });
  const pack = decodeGraphV4(encoded.graphBuffer, encoded.geomBuffer);
  const geom = decodeGeometryV1(encoded.geomBuffer);
  const edgeForWay = (wayId) => pack.osmWayIds.findIndex((id) => id === String(wayId));
  return {
    runtime: {
      format: "v2",
      pack,
      geom,
      data: { regionId: "fixture" },
      enums: pack.enums
    },
    edgeForWay,
    pack
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

function match(pack, edgeIndex, coord, atEnd) {
  const edgeMeters = Number(pack.edgeMeters[edgeIndex]);
  return {
    edgeIndex,
    edgeId: pack.edgeId(edgeIndex),
    coord,
    segmentIndex: 0,
    distanceAlongM: atEnd ? edgeMeters - 1 : 1,
    edgeMeters,
    roadTrack: "local"
  };
}

test("optimized V4 search enforces a complete via-way restriction without global exit blocking", () => {
  const { runtime, edgeForWay, pack } = fixture();
  const end = match(pack, edgeForWay(12), [0.00399, 0], true);
  const forbidden = findPathV2(
    runtime,
    match(pack, edgeForWay(10), [0.00001, 0], false),
    end,
    "cleanest",
    { motorizedPermissive: true, motorizedUnknown: false },
    new Set(),
    undefined,
    SEARCH
  );
  assert.equal(forbidden, null);

  const legalOtherApproach = findPathV2(
    runtime,
    match(pack, edgeForWay(13), [0.001, 0.00099], false),
    end,
    "cleanest",
    { motorizedPermissive: true, motorizedUnknown: false },
    new Set(),
    undefined,
    SEARCH
  );
  assert.ok(legalOtherApproach);
  assert.ok(legalOtherApproach.segments.some((segment) => segment.edgeId.includes("w12:")));
});
