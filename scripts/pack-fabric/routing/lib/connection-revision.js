"use strict";
const overlay = require("../schema/connection-revision.v1.json");
function connectionTopology(base, revision = process.env.DIRT_V4_CONNECTION_REVISION) {
  if (!revision) return base;
  if (revision !== overlay.connectionRevision || base.fabricReleaseId !== overlay.fabricReleaseId || base.sourceEpoch !== overlay.sourceEpoch) {
    throw new Error("V4 connection revision does not match the selected fabric");
  }
  const regions = { ...base.regions };
  for (const [id, row] of Object.entries(overlay.regions)) {
    regions[id] = { ...regions[id], neighbors: { ...regions[id].neighbors, ...row.neighbors } };
  }
  return { ...base, connectionRevision: revision, regions,
    pairs: base.pairs.map(p => overlay.pairs.find(q => q.left === p.left && q.right === p.right) || p) };
}
module.exports = { connectionTopology };
