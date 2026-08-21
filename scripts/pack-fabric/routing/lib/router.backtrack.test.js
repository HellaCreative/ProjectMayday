"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { findPathV2 } = require("./find-path-v2");
const { backtrackSummary } = require("./router");
const { packAttrs } = require("./pack-v2");

function runtimeWithAlternative(includeAlternative) {
  const nodes = [
    [0, 0],       // 0: prior road
    [0.009, 0],   // 1: rider waypoint at the end of the arrival spur
    [0.009, 0.0135], // 2: alternative exit
    [0.018, 0]    // 3: destination
  ];
  const edges = [
    { from: 0, to: 1, meters: 1_000, id: "arrival" },
    { from: 0, to: 3, meters: 2_000, id: "old-corridor" }
  ];
  if (includeAlternative) {
    edges.push(
      { from: 1, to: 2, meters: 1_500, id: "alternative-a" },
      { from: 2, to: 3, meters: 2_000, id: "alternative-b" }
    );
  }

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
  const attrs = packAttrs({ s: 0, ac: 0, t: 0, rt: "local", conf: "high" });
  const pack = {
    nodeCount: nodes.length,
    undirectedEdgeCount: edges.length,
    nodeOffsets: Uint32Array.from(nodeOffsets),
    edgeTargets: Uint32Array.from(edgeTargets),
    edgeUndirectedIndex: Uint32Array.from(edgeUndirectedIndex),
    edgeAttrs: Uint16Array.from(edges.map(() => attrs)),
    edgeMeters: Float64Array.from(edges.map((edge) => edge.meters)),
    edgeFrom: Uint32Array.from(edges.map((edge) => edge.from)),
    edgeTo: Uint32Array.from(edges.map((edge) => edge.to)),
    nodeCoords: Float64Array.from(nodes.flat()),
    meta: { urbanCores: [], settlements: [] },
    regionId: "fixture",
    edgeId(index) { return edges[index].id; }
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

function route(runtime) {
  const start = {
    edgeIndex: 0, edgeId: "arrival", coord: [0.009, 0], segmentIndex: 0,
    distanceAlongM: 1_000, edgeMeters: 1_000, roadTrack: "local"
  };
  const end = {
    edgeIndex: 1, edgeId: "old-corridor", coord: [0.018, 0], segmentIndex: 0,
    distanceAlongM: 2_000, edgeMeters: 2_000, roadTrack: "local"
  };
  return findPathV2(
    runtime,
    start,
    end,
    "direct",
    { motorizedPermissive: true, motorizedUnknown: false },
    new Set(),
    undefined,
    {
      costMode: "distance",
      boundedSearch: false,
      corridorMeters: 0,
      hardCorridor: false,
      priorEdgeIds: ["arrival"],
      arrivalEdgeId: "arrival",
      backtrackFactor: 4
    }
  );
}

test("arrival-edge penalty takes an alternative exit when one exists", () => {
  const result = route(runtimeWithAlternative(true));
  assert.ok(result);
  assert.ok(result.segments.some((segment) => segment.edgeId === "alternative-a"));
  const summary = backtrackSummary(result, ["arrival"]);
  assert.equal(summary.backtrackPct, 0);
});

test("arrival-edge penalty remains soft at a literal dead end", () => {
  const result = route(runtimeWithAlternative(false));
  assert.ok(result);
  const summary = backtrackSummary(result, ["arrival"]);
  assert.ok(summary.backtrackPct > 0);
  assert.equal(summary.backtrackReason, "dead_end_or_only_connector");
});
