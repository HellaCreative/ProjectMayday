"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const base = require("../schema/cross-pack-topology.v2.json");
const overlay = require("../schema/connection-revision.v1.json");
const { connectionTopology } = require("./connection-revision");
test("connection overlay is opt-in and binds to the sealed fabric", () => {
  assert.equal(connectionTopology(base, ""), base);
  assert.throws(() => connectionTopology(base, "wrong"), /does not match/);
  assert.throws(() => connectionTopology({...base,sourceEpoch:"wrong"}, overlay.connectionRevision), /does not match/);
  const revised = connectionTopology(base, overlay.connectionRevision);
  assert.equal(revised.regions.ns, base.regions.ns);
  assert.equal(revised.regions.qc.neighbors.nb, base.regions.qc.neighbors.nb);
  assert.equal(base.regions.qc.neighbors.on.length,128);
  assert.equal(revised.regions.qc.neighbors.on.length,7099);
  assert.equal(revised.regions.on.neighbors.qc.length,7099);
  assert.equal(revised.fabricReleaseId, base.fabricReleaseId);
});
