"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { evaluateMotorcycleAccess, throughAllowed } = require("./motorcycle-access");
const { travelDirectionV4 } = require("./direction");
const { evaluateBarrier } = require("./barriers");
const {
  parseRestrictionRelation,
  compileRestrictionIndex,
  indexedTurnAllowed,
  advanceRestrictionState
} = require("./restrictions");
const {
  parseConditionalExpression,
  evaluateNormalizedRule,
  collectConditionalRules,
  accessCodeFromRules
} = require("./conditional");
const { buildGraphFromOsm, countsFromGraph } = require("./osm-graph");
const { legalSnap } = require("./snap");
const { seamCandidates, assertSeamLegal } = require("./seams");
const { findPathV4 } = require("./find-path-v4");
const { encodeFromOsmGraph, decodeGraphV4, rejectMixedContract, sha256, GRAPH_V4_MAGIC } = require("../pack-v4");
const { decodeGeometryV1, GRAPH_MAGIC, unpackSurface } = require("../pack-v2");
const { buildPackManifestV2, validatePackManifestV2 } = require("../pack-manifest-v2");

function node(id, lon, lat, tags = {}) {
  return { id, lon, lat, tags };
}
function way(id, nodeIds, tags) {
  return { id, nodeIds, tags };
}
function rel(id, members, tags) {
  return { id, members, tags };
}

function packed(osm, provenance = { regionId: "fix", sourceEpoch: "epoch-1" }) {
  const graph = buildGraphFromOsm(osm);
  const encoded = encodeFromOsmGraph(graph, provenance);
  const pack = decodeGraphV4(encoded.graphBuffer, encoded.geomBuffer);
  const geom = decodeGeometryV1(encoded.geomBuffer);
  return { graph, encoded, pack, geom };
}

test("1. forward, reverse, two-way, motorway, roundabout direction", () => {
  assert.equal(travelDirectionV4({ oneway: "yes" }), "forward");
  assert.equal(travelDirectionV4({ oneway: "-1" }), "reverse");
  assert.equal(travelDirectionV4({ oneway: "no", highway: "motorway" }), "both");
  assert.equal(travelDirectionV4({ highway: "motorway" }), "forward");
  assert.equal(travelDirectionV4({ junction: "roundabout" }), "forward");
  assert.equal(travelDirectionV4({ oneway: "reversible" }), "closed");
  assert.equal(travelDirectionV4({ "oneway:conditional": "yes @ (Mo-Fr)" }), "closed");
});

test("2. Highway 104 both ways and median-safe snap", () => {
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
  assert.equal(pack.hasLeaves, true);
  assert.equal(unpackSurface(pack.edgeAttrs[0]), 0);
  const mid = { lat: 45.80755, lon: -64.2 };
  const west = legalSnap(pack, geom, mid, { headingDeg: 270, intentBearingDeg: 270 });
  const east = legalSnap(pack, geom, mid, { headingDeg: 90, intentBearingDeg: 90 });
  const none = legalSnap(pack, geom, mid, {});
  assert.equal(west[0].osmWayId, "537982310");
  assert.equal(east[0].osmWayId, "537982311");
  const ids = new Set(none.map((c) => c.osmWayId));
  assert.ok(ids.has("537982310") && ids.has("537982311"));
  const westRide = findPathV4(pack, geom, { lat: 45.80779, lon: -64.191 }, { lat: 45.80779, lon: -64.209 }, {
    startHeadingDeg: 270,
    intentBearingDeg: 270
  });
  assert.equal(westRide.ok, true);
  assert.ok(westRide.osmWayIds.includes("537982310"));
  assert.ok(!westRide.osmWayIds.includes("537982311"));
  const eastRide = findPathV4(pack, geom, { lat: 45.80731, lon: -64.209 }, { lat: 45.80731, lon: -64.191 }, {
    startHeadingDeg: 90,
    intentBearingDeg: 90
  });
  assert.equal(eastRide.ok, true);
  assert.ok(eastRide.osmWayIds.includes("537982311"));
  assert.ok(!eastRide.osmWayIds.includes("537982310"));
  assert.equal(westRide.unprovenStitches, 0);
});

test("3-5. turn restrictions including via-way, motorcycle except, malformed", () => {
  const osm = {
    nodes: [
      node(10, 0, 0),
      node(11, 0.001, 0),
      node(12, 0.002, 0),
      node(13, 0.001, 0.001),
      node(14, 0.001, -0.001)
    ],
    ways: [
      way(21, [10, 11], { highway: "residential" }),
      way(22, [11, 12], { highway: "residential" }),
      way(23, [11, 13], { highway: "residential" }),
      way(24, [11, 14], { highway: "residential" })
    ],
    relations: [
      rel(91, [
        { type: "way", ref: 21, role: "from" },
        { type: "node", ref: 11, role: "via" },
        { type: "way", ref: 23, role: "to" }
      ], { type: "restriction", restriction: "no_left_turn" }),
      rel(92, [
        { type: "way", ref: 21, role: "from" },
        { type: "node", ref: 11, role: "via" },
        { type: "way", ref: 24, role: "to" }
      ], { type: "restriction", restriction: "no_right_turn" }),
      rel(93, [
        { type: "way", ref: 21, role: "from" },
        { type: "node", ref: 11, role: "via" },
        { type: "way", ref: 22, role: "to" }
      ], { type: "restriction", restriction: "no_straight_on" }),
      rel(94, [
        { type: "way", ref: 23, role: "from" },
        { type: "node", ref: 11, role: "via" },
        { type: "way", ref: 24, role: "to" }
      ], { type: "restriction", restriction: "no_u_turn" }),
      rel(95, [
        { type: "way", ref: 21, role: "from" },
        { type: "way", ref: 22, role: "via" },
        { type: "way", ref: 22, role: "to" }
      ], { type: "restriction", restriction: "only_straight_on" }),
      rel(96, [
        { type: "way", ref: 21, role: "from" },
        { type: "node", ref: 11, role: "via" },
        { type: "way", ref: 22, role: "to" }
      ], { type: "restriction", restriction: "no_entry" }),
      rel(97, [
        { type: "way", ref: 22, role: "from" },
        { type: "node", ref: 11, role: "via" },
        { type: "way", ref: 21, role: "to" }
      ], { type: "restriction", restriction: "no_exit" }),
      rel(98, [
        { type: "way", ref: 21, role: "from" },
        { type: "node", ref: 11, role: "via" },
        { type: "way", ref: 23, role: "to" }
      ], { type: "restriction", restriction: "no_left_turn", except: "motorcycle" }),
      rel(99, [{ type: "way", ref: 21, role: "from" }], { type: "restriction", restriction: "no_left_turn" })
    ]
  };
  const { graph, pack, geom } = packed(osm);
  assert.ok(graph.rejected.some((r) => r.reason === "incomplete_from_to"));
  assert.ok(graph.rejected.some((r) => r.reason === "except_motorcycle"));
  const left = findPathV4(pack, geom, { lat: 0, lon: 0 }, { lat: 0.001, lon: 0.001 }, {
    maxMeters: 40
  });
  assert.equal(left.ok, false);
  const malformed = parseRestrictionRelation(rel(1, [], { type: "restriction", restriction: "no_left_turn" }));
  assert.equal(malformed.ok, false);
});

test("compiled restriction index scopes via-way turns to the complete approach", () => {
  const restrictions = [
    { fromEdge: 10, toEdge: 11, viaNode: 2, only: false, vehicleMask: 1 },
    { fromEdge: 20, toEdge: 21, viaNode: 3, only: true, vehicleMask: 1 },
    { fromEdge: 30, toEdge: 33, viaEdges: [31, 32], only: false, vehicleMask: 1 },
    { fromEdge: 40, toEdge: 43, viaEdges: [41, 42], only: true, vehicleMask: 1 }
  ];
  const index = compileRestrictionIndex(restrictions);
  assert.equal(compileRestrictionIndex(restrictions), index);
  assert.equal(indexedTurnAllowed(index, 10, 11, 2), false);
  assert.equal(indexedTurnAllowed(index, 10, 12, 2), true);
  assert.equal(indexedTurnAllowed(index, 20, 21, 3), true);
  assert.equal(indexedTurnAllowed(index, 20, 22, 3), false);
  // Merely reaching the final via edge from another approach is legal.
  assert.equal(indexedTurnAllowed(index, 32, 33, 9), true);

  let state = advanceRestrictionState(index, [], 30, 31, 9);
  assert.equal(state.allowed, true);
  state = advanceRestrictionState(index, state.active, 31, 32, 10);
  assert.equal(state.allowed, true);
  assert.equal(advanceRestrictionState(index, state.active, 32, 33, 11).allowed, false);
  assert.equal(advanceRestrictionState(index, [], 32, 33, 11).allowed, true);

  state = advanceRestrictionState(index, [], 40, 41, 9);
  assert.equal(state.allowed, true);
  assert.equal(advanceRestrictionState(index, [], 40, 44, 9).allowed, false);
  state = advanceRestrictionState(index, state.active, 41, 42, 10);
  assert.equal(state.allowed, true);
  assert.equal(advanceRestrictionState(index, state.active, 42, 44, 11).allowed, false);
  assert.equal(advanceRestrictionState(index, state.active, 42, 43, 11).allowed, true);
});

test("via-way relation stores its exact edge chain and does not block another approach", () => {
  const osm = {
    nodes: [
      node(1, 0, 0),
      node(2, 0.001, 0),
      node(3, 0.002, 0),
      node(4, 0.003, 0),
      node(5, 0.004, 0),
      node(6, 0.001, 0.001),
      node(7, 0.002, 0.001)
    ],
    ways: [
      way(10, [1, 2], { highway: "residential" }),
      way(11, [2, 3, 4], { highway: "residential" }),
      way(12, [4, 5], { highway: "residential" }),
      way(13, [6, 2], { highway: "residential" }),
      way(14, [3, 7], { highway: "residential" })
    ],
    relations: [
      rel(100, [
        { type: "way", ref: 10, role: "from" },
        { type: "way", ref: 11, role: "via" },
        { type: "way", ref: 12, role: "to" }
      ], { type: "restriction", restriction: "no_straight_on" })
    ]
  };
  const { graph, pack, geom } = packed(osm);
  assert.equal(graph.restrictions.length, 1);
  assert.equal(graph.restrictions[0].viaEdges.length, 2);
  assert.deepEqual(graph.restrictions[0].viaWayIds, ["11", "11"]);

  const forbidden = findPathV4(pack, geom, { lat: 0, lon: 0 }, { lat: 0, lon: 0.004 }, { maxMeters: 40 });
  assert.equal(forbidden.ok, false);
  const otherApproach = findPathV4(
    pack,
    geom,
    { lat: 0.001, lon: 0.001 },
    { lat: 0, lon: 0.004 },
    { maxMeters: 40 }
  );
  assert.equal(otherApproach.ok, true);
  assert.ok(otherApproach.osmWayIds.includes("12"));
});

test("6. motorcycle=no defeats positive ATV", () => {
  const access = evaluateMotorcycleAccess({ motorcycle: "no", atv: "yes", highway: "path" });
  assert.equal(access.forward.code, 2);
  assert.equal(throughAllowed(access.forward.code, { allowUnknown: true }), false);
});

test("7. directional motorcycle access", () => {
  const access = evaluateMotorcycleAccess({ "motorcycle:forward": "yes", "motorcycle:backward": "no" });
  assert.equal(access.forward.code, 0);
  assert.equal(access.reverse.code, 2);
});

test("8. destination/customers endpoint-only", () => {
  const dest = evaluateMotorcycleAccess({ access: "destination" });
  assert.equal(dest.forward.code, 3);
  assert.equal(throughAllowed(3, { isEndpoint: false }), false);
  assert.equal(throughAllowed(3, { isEndpoint: true }), true);
  assert.equal(throughAllowed(4, { isEndpoint: true, endpointKind: "customers" }), true);
  assert.equal(throughAllowed(4, { isEndpoint: true }), false);
});

test("9. gates: allowed, blocked, type-default, ambiguous fail-closed", () => {
  assert.equal(evaluateBarrier({ barrier: "gate", access: "yes" }).decision, "allow");
  assert.equal(evaluateBarrier({ barrier: "gate", motorcycle: "no" }).decision, "block");
  assert.equal(evaluateBarrier({ barrier: "bollard" }).decision, "block");
  assert.equal(evaluateBarrier({ barrier: "gate" }).decision, "fail_closed");
});

test("10. smoothness=impassable blocked", () => {
  assert.equal(evaluateMotorcycleAccess({ smoothness: "impassable", highway: "track" }).impassable, true);
  assert.equal(evaluateMotorcycleAccess({ smoothness: "impassable" }).forward.code, 2);
});

test("11-12. conditional open/closed, unsupported fail-closed, seasonal/winter/ice", () => {
  const winter = parseConditionalExpression("no @ winter");
  assert.equal(evaluateNormalizedRule(winter, new Date("2026-01-15T12:00:00Z")), "closed");
  assert.equal(evaluateNormalizedRule(winter, new Date("2026-07-15T12:00:00Z")), "open");
  const bad = parseConditionalExpression("no @ (PH)");
  assert.equal(bad.evaluable, false);
  const flags = collectConditionalRules({ seasonal: "yes", winter_road: "yes", ice_road: "yes" });
  assert.ok(flags.rules.some((r) => r.seasonal));
  assert.equal(flags.rules.find((r) => r.seasonal).evaluable, false);
  assert.equal(accessCodeFromRules(0, flags.rules, new Date("2026-07-15T12:00:00Z")), 5);
  const timed = collectConditionalRules({ "motorcycle:conditional": "yes @ (Jun-Aug)" });
  assert.equal(accessCodeFromRules(0, timed.rules, new Date("2026-07-15T12:00:00Z")), 5);
});

test("13. coincident-but-distinct OSM nodes are not joined", () => {
  const osm = {
    nodes: [
      node(1, -64.1, 45.8, {}),
      node(2, -64.101, 45.8, {}),
      node(3, -64.1, 45.8, {}),
      node(4, -64.101, 45.801, { layer: "1" })
    ],
    ways: [
      way(10, [1, 2], { highway: "residential" }),
      way(11, [3, 4], { highway: "residential", bridge: "yes", layer: "1" })
    ]
  };
  const { graph } = packed(osm);
  assert.equal(graph.nodes.length, 4);
  const ids = graph.nodes.map((n) => n.osmNodeId).sort();
  assert.deepEqual(ids, ["1", "2", "3", "4"]);
});

test("14. no stitch/median bypass; zero unproven stitches", () => {
  const { graph } = packed({
    nodes: [node(1, 0, 0), node(2, 0.001, 0)],
    ways: [way(1, [1, 2], { highway: "residential" })]
  });
  assert.equal(graph.unprovenStitches, 0);
  assert.equal(countsFromGraph(graph).unprovenStitches, 0);
});

test("V4 seams require identical OSM edge, access, layer and safety proof", () => {
  const { pack } = packed({
    nodes: [node(1, 0, 0), node(2, 0.001, 0)],
    ways: [way(10, [1, 2], { highway: "residential", surface: "paved" })]
  });
  const candidates = seamCandidates(pack, pack);
  assert.ok(candidates.length >= 1);
  assert.strictEqual(
    seamCandidates(pack, pack), candidates,
    "the immutable pack pair must reuse its completed seam proof"
  );
  assert.equal(assertSeamLegal(pack, pack, candidates[0]), true);

  const changedAccess = { ...pack, edgeAccess: Buffer.from(pack.edgeAccess) };
  changedAccess.edgeAccess[0] = 2;
  assert.equal(seamCandidates(pack, changedAccess).length, 0);
  assert.throws(() => assertSeamLegal(pack, changedAccess, candidates[0]));
});

test("15. deterministic identical hashes", () => {
  const osm = {
    nodes: [node(1, -63.2, 45.39), node(2, -63.21, 45.39)],
    ways: [way(9, [1, 2], { highway: "primary", oneway: "yes" })]
  };
  const a = packed(osm);
  const b = packed(osm);
  assert.equal(sha256(a.encoded.graphBuffer), sha256(b.encoded.graphBuffer));
  assert.equal(sha256(a.encoded.geomBuffer), sha256(b.encoded.geomBuffer));
});

test("16. corruption, capability, mixed-contract rejection", () => {
  const osm = {
    nodes: [node(1, 0, 0), node(2, 0.001, 0)],
    ways: [way(1, [1, 2], { highway: "residential" })]
  };
  const { encoded, pack } = packed(osm);
  const v3ish = Buffer.from(encoded.graphBuffer);
  v3ish.writeUInt32LE(GRAPH_MAGIC, 0);
  assert.throws(() => decodeGraphV4(v3ish, encoded.geomBuffer));
  const corrupt = Buffer.from(encoded.graphBuffer);
  corrupt.writeUInt32LE(0, 116);
  assert.throws(() => decodeGraphV4(corrupt, encoded.geomBuffer));
  const other = { ...pack, provenance: { sourceEpoch: "other" }, graphBinaryVersion: 4 };
  assert.throws(() => rejectMixedContract([pack, other]));
  const manifest = buildPackManifestV2({
    fabricReleaseId: "ns-v4-test",
    regionId: "ns",
    graph: { name: "graph.v4.bin", bytes: 1, sha256: "a".repeat(64) },
    geometry: { name: "geometry.v1.bin", bytes: 1, sha256: "b".repeat(64) },
    fuel: { name: "fuel.v1.json", bytes: 1, sha256: "c".repeat(64) },
    sourceEpoch: "epoch-1",
    timezone: "America/Halifax"
  });
  assert.equal(validatePackManifestV2(manifest), true);
  assert.throws(() => validatePackManifestV2({ schema: "pack-manifest.v1" }));
});

test("V4 magic is not V3 magic", () => {
  assert.notEqual(GRAPH_V4_MAGIC, GRAPH_MAGIC);
});
