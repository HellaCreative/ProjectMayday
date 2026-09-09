"use strict";
const revisions = require("./verified-pack-revisions.json");
function qualifiedPack(identity) {
  if (!identity || typeof identity !== "object") return false;
  const expected = revisions[identity.releaseId]?.[identity.regionId];
  return !!expected && Object.entries(expected).every(([key,value])=>identity[key]===value);
}
function nbSupplement(identity, cores) {
  const nb = identity.find(p=>p.regionId==="nb");
  // The verified metadata correction embeds the same reviewed boxes once.
  return nb && nb.releaseId === "fabric-v4-20260908-02" ? cores : [];
}
module.exports = { qualifiedPack, nbSupplement };
