"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { scopeSeams, scopeCandidate } = require("./scope-v4-candidate");

test("scoped release removes unavailable neighbors but preserves selected directed proof facts", () => {
  const proof = { osmWayId: "17", localEdgeId: "17:1:2", direction: "reverse", restriction: { via: [1, 2] } };
  const original = { regionId: "nv", sourceEpoch: "unchanged", fabricReleaseId: "old",
    roadNeighbors: ["az", "ca-n"], neighbors: { az: [proof], "ca-n": [{ unavailable: true }] } };
  const before = JSON.stringify(original);
  const scoped = scopeSeams(original, new Set(["nv", "az"]), "new");
  assert.deepEqual(scoped.neighbors, { az: [proof] });
  assert.deepEqual(scoped.roadNeighbors, ["az"]);
  assert.equal(scoped.sourceEpoch, "unchanged");
  assert.equal(scoped.fabricReleaseId, "new");
  assert.equal(JSON.stringify(original), before);
  assert.throws(() => scopeSeams(original, new Set(["az"]), "new"), /outside selected scope/);
});

test("scoping refuses to overwrite any existing destination", () => {
  assert.throws(() => scopeCandidate({ source: __dirname, root: __dirname,
    releaseId: "fabric-v4-20260921-01", exclude: ["ca-n", "ca-s"] }), /destination already exists/);
});
