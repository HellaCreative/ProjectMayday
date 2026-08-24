"use strict";

process.env.ROUTING_USE_REGIONAL = "1";

const test = require("node:test");
const assert = require("node:assert/strict");
const { findPathV2 } = require("./find-path-v2");
const { packAttrs } = require("./pack-v2");
const { METRO_CORE_WALL, resolveMetroFallbackPenalty } = require("./hop-search");

/** Halifax downtown — both pins inside the halifax metro box. */
const HALIFAX_A = [-63.5752, 44.6488];
const HALIFAX_B = [-63.601, 44.672];

function halifaxMetroRuntime() {
  const nodes = [
    HALIFAX_A,
    [-63.588, 44.66],
    HALIFAX_B,
    [-63.62, 44.655]
  ];
  const edges = [
    { from: 0, to: 1, meters: 1_200, id: "a-b", surface: 0 },
    { from: 1, to: 2, meters: 1_400, id: "b-c", surface: 1 },
    { from: 2, to: 3, meters: 1_100, id: "c-d", surface: 0 },
    { from: 0, to: 2, meters: 2_800, id: "a-c", surface: 0 }
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
  const attrs = edges.map((edge) =>
    packAttrs({ s: edge.surface, ac: 1, t: 0, rt: "local", conf: "medium" })
  );
  const pack = {
    nodeCount: nodes.length,
    undirectedEdgeCount: edges.length,
    nodeOffsets: Uint32Array.from(nodeOffsets),
    edgeTargets: Uint32Array.from(edgeTargets),
    edgeUndirectedIndex: Uint32Array.from(edgeUndirectedIndex),
    edgeAttrs: Uint16Array.from(attrs),
    edgeMeters: Uint32Array.from(edges.map((edge) => edge.meters)),
    edgeFrom: Uint32Array.from(edges.map((edge) => edge.from)),
    edgeTo: Uint32Array.from(edges.map((edge) => edge.to)),
    nodeCoords: Float64Array.from(nodes.flat()),
    meta: { urbanCores: METRO_CORE_WALL, settlements: [] },
    regionId: "ns",
    edgeId(index) {
      return edges[index].id;
    }
  };
  return {
    format: "v2",
    pack,
    data: { regionId: "ns" },
    geom: {
      polyline(index) {
        return [nodes[edges[index].from], nodes[edges[index].to]];
      },
      polylineMaybeReversed(index, forward) {
        const line = this.polyline(index);
        return forward ? line : line.slice().reverse();
      }
    },
    enums: {
      SURFACE_NAME: ["paved", "gravel", "access", "track", "unknown"],
      ACCESS_NAME: ["motorized_verified", "motorized_permissive", "motorized_unknown"],
      STRUCTURE_NAME: ["none"]
    }
  };
}

function snap(edgeIndex, coord, alongM, edgeMeters) {
  return {
    edgeIndex,
    edgeId: `edge-${edgeIndex}`,
    coord,
    segmentIndex: 0,
    distanceAlongM: alongM,
    edgeMeters,
    roadTrack: "local"
  };
}

test("metro fallback penalty ignores cleanMetroMultiplier for balanced", () => {
  assert.equal(resolveMetroFallbackPenalty("balanced", 5), 120);
  assert.equal(resolveMetroFallbackPenalty("cleanest", 5), 5);
  assert.equal(resolveMetroFallbackPenalty("cleanest", null), 5);
});

test("balanced search completes with both pins inside metro (no cleanMetroPenalty crash)", () => {
  const runtime = halifaxMetroRuntime();
  const result = findPathV2(
    runtime,
    snap(0, HALIFAX_A, 0, 1_200),
    snap(2, HALIFAX_B, 1_400, 1_400),
    "balanced",
    { motorizedPermissive: true, motorizedUnknown: false },
    new Set(),
    undefined,
    {
      boundedSearch: true,
      cityWall: true,
      cleanMetroMultiplier: 5,
      timeCapMs: 5000,
      popCap: 50_000
    }
  );
  assert.ok(result, "balanced route should complete");
  assert.ok(result.distanceMeters > 0);
  assert.equal(result.searchMeta && result.searchMeta.rideObjective, "surface-balance");
});
