"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { findPathV2 } = require("./find-path-v2");
const { backtrackSummary, firstUsableRecovery } = require("./router");
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

function route(runtime, options = {}) {
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
    "balanced",
    { motorizedPermissive: true, motorizedUnknown: false },
    new Set(),
    undefined,
    {
      costMode: "distance",
      boundedSearch: false,
      corridorMeters: 0,
      hardCorridor: false,
      priorEdgeIds: options.priorEdgeIds || ["arrival"],
      arrivalEdgeId: "arrival",
      backtrackFactor: 4,
      rejectPriorEdges: options.rejectPriorEdges === true,
      startEndpointKind: options.startEndpointKind || null,
      endEndpointKind: options.endEndpointKind || null
    }
  );
}

test("arrival-edge penalty takes an alternative exit when one exists", () => {
  const result = route(runtimeWithAlternative(true), { rejectPriorEdges: true });
  assert.ok(result);
  assert.ok(result.segments.some((segment) => segment.edgeId === "alternative-a"));
  const summary = backtrackSummary(result, ["arrival"]);
  assert.equal(summary.backtrackPct, 0);
});

test("the exact departure edge remains available at a literal single-access endpoint", () => {
  const result = route(runtimeWithAlternative(false), { rejectPriorEdges: true });
  assert.ok(result);
  const summary = backtrackSummary(result, ["arrival"]);
  assert.ok(summary.backtrackPct > 0);
  assert.equal(summary.backtrackReason, "dead_end_or_only_connector");
});

test("a proved no-path route does not reopen a two-kilometre prior fuel approach", () => {
  const result = route(runtimeWithAlternative(false), {
    rejectPriorEdges: true,
    priorEdgeIds: ["old-corridor"],
    endEndpointKind: "customers"
  });
  assert.equal(result, null);
});

test("explicit recovery opens only the suffix reaching the first usable junction", () => {
  const history = ["oldest", "junction-3", "junction-2", "junction-1", "arrival"];
  const attempts = [];
  const result = firstUsableRecovery(history, (allowed, count) => {
    attempts.push(count);
    return allowed.has("junction-2")
      ? { path: { edgeIds: [...allowed] }, diagnostics: { outcome: "completed" } }
      : { path: null, diagnostics: { outcome: "noPath" } };
  });

  assert.ok(result && result.path);
  assert.equal(result.allowedHistoryCount, 3);
  assert.deepEqual([...result.allowedEdgeIds], ["junction-2", "junction-1", "arrival"]);
  assert.ok(attempts.includes(4), "exponential probe should establish a usable upper bound");
});

test("explicit recovery does not widen after an unproved search limit", () => {
  const result = firstUsableRecovery(["older", "arrival"], (_allowed, count) => (
    count === 1
      ? { path: null, diagnostics: { outcome: "searchLimit" } }
      : { path: { edgeIds: ["older"] }, diagnostics: { outcome: "completed" } }
  ));

  assert.equal(result.path, null);
  assert.equal(result.outcome, "searchLimit");
  assert.equal(result.allowedHistoryCount, 1);
});
