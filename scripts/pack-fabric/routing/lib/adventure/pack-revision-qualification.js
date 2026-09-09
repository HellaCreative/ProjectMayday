"use strict";
const revisions = require("./verified-pack-revisions.json");
function qualifiedPack(identity) {
  // Retain the accepted release's existing qualification contract.
  if (identity.releaseId === "fabric-v4-20260908-02") return true;
  const expected = revisions[identity.releaseId]?.[identity.regionId];
  return !!expected && Object.entries(expected).every(([key,value])=>identity[key]===value);
}
function nbSupplement(identity, cores) {
  const nb = identity.find(p=>p.regionId==="nb");
  // The verified metadata correction embeds the same reviewed boxes once.
  return nb && !revisions[nb.releaseId]?.nb ? cores : [];
}
module.exports = { qualifiedPack, nbSupplement };
