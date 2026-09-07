"use strict";

/**
 * Cross-region seams from shared OSM node/way identity only.
 */

function seamCandidates(left, right) {
  const leftNodes = new Map((left.osmNodeIds || []).map((id, i) => [String(id), i]));
  const shared = [];
  for (let i = 0; i < (right.osmNodeIds || []).length; i += 1) {
    const id = String(right.osmNodeIds[i]);
    if (!leftNodes.has(id) || id === "0") continue;
    shared.push({
      osmNodeId: id,
      leftNode: leftNodes.get(id),
      rightNode: i
    });
  }
  return shared;
}

function assertSeamLegal(left, right, candidate) {
  if (!candidate || !candidate.osmNodeId) throw new Error("seam missing OSM identity");
  if (String(candidate.osmNodeId).startsWith("vertex:")) {
    throw new Error("coordinate alias is not a seam");
  }
  return true;
}

module.exports = { seamCandidates, assertSeamLegal };
