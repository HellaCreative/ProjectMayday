"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { assemble, replaceSeams, assertUnchangedNeighbor } = require("./replace-v4-regions");
test("replacement changes both sides of selected seams and preserves unrelated proofs", () => {
  const proof = { direction: "forward", restrictions: [123], sourceWay: "12345" };
  const original = { regionId: "nv", sourceEpoch: "epoch", fabricReleaseId: "old", roadNeighbors: ["az","ca-s"],
    neighbors: { az: [proof], "ca-s": [{ stale: true }] } };
  const updated = { ...original, roadNeighbors: ["ca-s"], neighbors: { "ca-s": [proof], az: [{ unrelated: true }] } };
  const snapshot = JSON.stringify(original);
  const combined = replaceSeams(original, updated, new Set(["ca-s"]), "new");
  assert.deepEqual(combined.neighbors, { az: [proof], "ca-s": [proof] });
  assert.deepEqual(combined.roadNeighbors, ["az", "ca-s"]);
  assert.equal(JSON.stringify(original), snapshot);
  assert.deepEqual(replaceSeams({ ...original, regionId: "ca-s", neighbors: { nv: [] } },
    { ...updated, regionId: "ca-s", neighbors: { nv: [proof] }, roadNeighbors: ["nv"] }, new Set(["ca-s"]), "new").neighbors, { nv: [proof] });
});
test("missing reciprocal proof and mismatched identity fail closed", () => {
  const s = { regionId: "nv", sourceEpoch: "epoch", neighbors: { "ca-s": [] }, roadNeighbors: [] };
  for (const replacement of [null, { ...s, neighbors: {} }, { ...s, sourceEpoch: "old" }, { ...s, regionId: "az" }])
    assert.throws(() => replaceSeams(s, replacement, new Set(["ca-s"]), "new"));
});
test("replacement seam neighbors must retain exact graph and sidecar identities", () => {
  const r = { id: "az", packManifest: { graph: { sha256: "g" }, geometry: { sha256: "p" }, fuel: { sha256: "f" } }, riderServices: { sha256: "r" } };
  assertUnchangedNeighbor(r, structuredClone(r));
  for (const key of ["graph","geometry","fuel"]) {
    const changed = structuredClone(r); changed.packManifest[key].sha256 = "changed";
    assert.throws(() => assertUnchangedNeighbor(r, changed), /different/);
  }
  assert.throws(() => assertUnchangedNeighbor(r, { ...r, riderServices: { sha256: "changed" } }), /unselected/);
});
test("existing candidate cannot be overwritten", () => {
  assert.throws(() => assemble({ root: __dirname }), /already exists/);
});
