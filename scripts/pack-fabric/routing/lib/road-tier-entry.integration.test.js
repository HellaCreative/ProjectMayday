"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { findPathV2 } = require("./find-path-v2");
const { packAttrs } = require("./pack-v2");
const { ROAD_TIER_MAP } = require("./road-tier");
const { SURFACE_FAMILY_MAP } = require("./surface-family");

function fixture() {
  const nodes = [
    [0, 0],
    [0.009, 0],
    [0.018, 0],
    [0.027, 0],
    [0.0135, 0.005]
  ];
  const edges = [
    { from: 0, to: 1, meters: 1000, id: "start-local", leaf: "secondary" },
    { from: 1, to: 2, meters: 100, id: "brief-trunk-hop", leaf: "trunk" },
    { from: 2, to: 3, meters: 1000, id: "end-local", leaf: "secondary" },
    { from: 1, to: 4, meters: 2000, id: "rural-a", leaf: "secondary" },
    { from: 4, to: 2, meters: 2000, id: "rural-b", leaf: "secondary" }
  ];
  const arcs = Array.from({ length: nodes.length }, () => []);
  edges.forEach((edge, index) => {
    arcs[edge.from].push({ to: edge.to, edge: index });
    arcs[edge.to].push({ to: edge.from, edge: index });
  });
  const nodeOffsets = [0];
  const edgeTargets = [];
  const edgeUndirectedIndex = [];
  for (const list of arcs) {
    for (const arc of list) {
      edgeTargets.push(arc.to);
      edgeUndirectedIndex.push(arc.edge);
    }
    nodeOffsets.push(edgeTargets.length);
  }
  const attr = packAttrs({ s: 0, ac: 0, t: 0, rt: "local", conf: "high" });
  const pack = {
    nodeCount: nodes.length,
    undirectedEdgeCount: edges.length,
    nodeOffsets: Uint32Array.from(nodeOffsets),
    edgeTargets: Uint32Array.from(edgeTargets),
    edgeUndirectedIndex: Uint32Array.from(edgeUndirectedIndex),
    edgeAttrs: Uint16Array.from(edges.map(() => attr)),
    edgeMeters: Uint32Array.from(edges.map((edge) => edge.meters)),
    edgeFrom: Uint32Array.from(edges.map((edge) => edge.from)),
    edgeTo: Uint32Array.from(edges.map((edge) => edge.to)),
    nodeCoords: Float64Array.from(nodes.flat()),
    meta: { urbanCores: [], settlements: [] },
    regionId: "fixture",
    hasLeaves: true,
    roadTierMap: ROAD_TIER_MAP,
    surfaceFamilyMap: SURFACE_FAMILY_MAP,
    edgeId(index) { return edges[index].id; },
    edgeLeaves(index) {
      return {
        surfaceLeaf: "paved",
        roadClassLeaf: edges[index].leaf,
        structureLeaf: null,
        layer: 0
      };
    }
  };
  return {
    format: "v2",
    pack,
    data: { regionId: "fixture" },
    geom: {
      polyline(index) { return [nodes[edges[index].from], nodes[edges[index].to]]; },
      polylineMaybeReversed(index, forward) {
        const line = this.polyline(index);
        return forward ? line : line.slice().reverse();
      }
    },
    enums: {
      SURFACE_NAME: ["paved"],
      ACCESS_NAME: ["motorized_permissive"],
      STRUCTURE_NAME: ["none"]
    }
  };
}

function route(avoidMotorways) {
  const runtime = fixture();
  return findPathV2(
    runtime,
    {
      edgeIndex: 0,
      edgeId: "start-local",
      coord: [0.009, 0],
      segmentIndex: 0,
      distanceAlongM: 1000,
      edgeMeters: 1000,
      roadTrack: "local"
    },
    {
      edgeIndex: 2,
      edgeId: "end-local",
      coord: [0.027, 0],
      segmentIndex: 0,
      distanceAlongM: 1000,
      edgeMeters: 1000,
      roadTrack: "local"
    },
    "cleanest",
    { motorizedPermissive: true, motorizedUnknown: false },
    new Set(),
    undefined,
    {
      pavedOnly: true,
      costMode: "profile",
      variety: false,
      boundedSearch: false,
      corridorMeters: 0,
      hardCorridor: false,
      settlementFallback: false,
      cityWall: false,
      avoidMotorways
    }
  );
}

test("Clean entry toll rejects a brief trunk hop while Allow major highways keeps it", () => {
  const avoided = route(true);
  const allowed = route(false);
  assert.ok(avoided);
  assert.ok(allowed);
  assert.ok(avoided.segments.some((segment) => segment.edgeId === "rural-a"));
  assert.ok(!avoided.segments.some((segment) => segment.edgeId === "brief-trunk-hop"));
  assert.ok(allowed.segments.some((segment) => segment.edgeId === "brief-trunk-hop"));
});
