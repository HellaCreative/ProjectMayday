"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { matchPoint } = require("./router");

function runtime(includePermissive) {
  const edges = [{
    i: "restricted-nearest",
    ac: 2,
    s: 0,
    t: 0,
    c: 0,
    m: 222,
    rt: "track",
    g: [[-0.001, 0], [0.001, 0]]
  }];
  if (includePermissive) {
    edges.push({
      i: "permissive-within-500m",
      ac: 0,
      s: 0,
      t: 0,
      c: 0,
      m: 222,
      rt: "track",
      g: [[-0.001, 0.001], [0.001, 0.001]]
    });
  }
  return {
    format: "v1",
    path: "fixture/ns/graph.v1.json",
    data: { regionId: "ns", edges },
    edgeGrid: new Map([["0:0", edges.map((_, index) => index)]]),
    GRID: 0.01,
    enums: {
      SURFACE_NAME: ["gravel"],
      ACCESS_NAME: [
        "motorized_permissive",
        "motorized_unknown",
        "motorized_restricted",
        "motorized_excluded"
      ],
      STRUCTURE_NAME: ["none"]
    }
  };
}

const policy = { motorizedPermissive: true, motorizedUnknown: false };
const location = { lon: 0, lat: 0 };

test("Dirt snap skips a nearer ineligible edge for an eligible edge within 500 m", () => {
  const match = matchPoint(
    runtime(true), location, policy, 500, new Set(), null, "dirt", "start"
  );
  assert.equal(match.ok, true);
  assert.equal(match.edgeId, "permissive-within-500m");
  assert.equal(match.accessClass, "motorized_permissive");
  assert.ok(match.distanceM < 500);
});

test("Dirt snap reports snap_no_eligible_edge when the radius has none", () => {
  const match = matchPoint(
    runtime(false), location, policy, 500, new Set(), null, "dirt", "start"
  );
  assert.equal(match.ok, false);
  assert.equal(match.reason, "snap_no_eligible_edge");
  assert.equal(match.matchLimitMeters, 500);
});

test("Clean endpoint snap keeps a motorized gravel road eligible", () => {
  const match = matchPoint(
    runtime(true), location, policy, 500, new Set(), null, "cleanest", "end"
  );
  assert.equal(match.ok, true);
  assert.equal(match.edgeId, "permissive-within-500m");
  assert.equal(match.surfaceClass, "gravel");
});
