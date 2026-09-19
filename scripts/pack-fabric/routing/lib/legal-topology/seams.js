"use strict";

/** Cross-region seams proved by shared OSM node, way and edge identity. */

// Decoded packs are immutable during a seam run. Reuse a pair's deterministic
// candidates while both pack objects are alive so selected proofs are checked
// without rescanning two full regional graphs for every proof. Weak references
// release the cached rows with the pair and keep continent builds memory-safe.
const seamCandidateCache = new WeakMap();
const seamProofIdentities = new WeakMap();

function haversineMeters(a, b) {
  const toRad = (value) => (value * Math.PI) / 180;
  const dLat = toRad(b[1] - a[1]);
  const dLon = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * 6_371_000 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function coordinate(pack, node) {
  return [Number(pack.nodeCoords[node * 2]), Number(pack.nodeCoords[node * 2 + 1])];
}

function incidentEdges(pack, node) {
  const result = [];
  for (let arc = pack.nodeOffsets[node]; arc < pack.nodeOffsets[node + 1]; arc += 1) {
    result.push(Number(pack.edgeUndirectedIndex[arc]));
  }
  return [...new Set(result)];
}

function edgeProof(pack, edge) {
  const from = Number(pack.edgeFrom[edge]);
  const to = Number(pack.edgeTo[edge]);
  const leaves = typeof pack.edgeLeaves === "function" ? pack.edgeLeaves(edge) : {};
  // Sidecar ranking needs the actual V4 ferry signal. Keep it out of
  // edgeProofKey: crossing time is quality metadata, not legal topology.
  const crossingSeconds = typeof pack.crossingSeconds === "function"
    ? Number(pack.crossingSeconds(edge)) || 0
    : 0;
  return {
    osmWayId: String(pack.osmWayIds[edge]),
    fromOsmNodeId: String(pack.osmNodeIds[from]),
    toOsmNodeId: String(pack.osmNodeIds[to]),
    accessForward: Number(pack.edgeAccess[edge * 2]),
    accessReverse: Number(pack.edgeAccess[edge * 2 + 1]),
    layer: Number(leaves.layer || 0),
    structureLeaf: leaves.structureLeaf || null,
    crossingSeconds
  };
}

function edgeProofKey(proof) {
  return [
    proof.osmWayId,
    proof.fromOsmNodeId,
    proof.toOsmNodeId,
    proof.accessForward,
    proof.accessReverse,
    proof.layer,
    proof.structureLeaf || ""
  ].join(":");
}

function barrierDecision(pack, osmNodeId) {
  const row = (pack.barriers || []).find((barrier) => String(barrier.osmNodeId) === String(osmNodeId));
  return row ? Number(row.decisionCode) : 0;
}

function restrictionProofs(pack, node, incident) {
  const relevant = new Set(incident);
  return (pack.restrictions || [])
    .filter((row) =>
      Number(row.viaNode) === Number(node) ||
      relevant.has(Number(row.fromEdge)) ||
      relevant.has(Number(row.toEdge)) ||
      (row.viaEdges || []).some((edge) => relevant.has(Number(edge)))
    )
    .map((row) => ({
      osmRelationId: String(row.osmRelationId),
      kind: Number(row.kind),
      only: row.only === true,
      vehicleMask: Number(row.vehicleMask),
      fromWayId: String(pack.osmWayIds[row.fromEdge]),
      viaWayIds: (row.viaWayIds || []).map(String),
      toWayId: String(pack.osmWayIds[row.toEdge])
    }))
    .sort((a, b) => a.osmRelationId.localeCompare(b.osmRelationId));
}

function seamCandidates(left, right) {
  let rightCache = seamCandidateCache.get(left);
  if (!rightCache) {
    rightCache = new WeakMap();
    seamCandidateCache.set(left, rightCache);
  }
  const cached = rightCache.get(right);
  if (cached) return cached;

  const leftNodes = new Map((left.osmNodeIds || []).map((id, i) => [String(id), i]));
  const shared = [];
  for (let rightNode = 0; rightNode < (right.osmNodeIds || []).length; rightNode += 1) {
    const osmNodeId = String(right.osmNodeIds[rightNode]);
    const leftNode = leftNodes.get(osmNodeId);
    if (leftNode == null || osmNodeId === "0") continue;
    const leftCoordinate = coordinate(left, leftNode);
    const rightCoordinate = coordinate(right, rightNode);
    const coordinateGapMeters = haversineMeters(leftCoordinate, rightCoordinate);
    if (coordinateGapMeters > 2) continue;
    if (barrierDecision(left, osmNodeId) !== barrierDecision(right, osmNodeId)) continue;

    const leftIncident = incidentEdges(left, leftNode);
    const rightIncident = incidentEdges(right, rightNode);
    const rightProofs = new Map(rightIncident.map((edge) => {
      const proof = edgeProof(right, edge);
      return [edgeProofKey(proof), proof];
    }));
    const matching = [];
    for (const edge of leftIncident) {
      const proof = edgeProof(left, edge);
      if (rightProofs.has(edgeProofKey(proof))) matching.push(proof);
    }
    if (!matching.length) continue;
    const leftRestrictions = restrictionProofs(left, leftNode, leftIncident);
    const rightRestrictions = restrictionProofs(right, rightNode, rightIncident);
    if (JSON.stringify(leftRestrictions) !== JSON.stringify(rightRestrictions)) continue;

    for (const proof of matching) {
      shared.push({
        osmNodeId,
        osmWayId: proof.osmWayId,
        leftNode,
        rightNode,
        coordinate: leftCoordinate,
        coordinateGapMeters,
        barrierDecision: barrierDecision(left, osmNodeId),
        restrictions: leftRestrictions,
        edge: proof,
        proof: "shared-osm-node-way-edge-legal-topology.v1"
      });
    }
  }
  rightCache.set(right, shared);
  return shared;
}

function assertSeamLegal(left, right, candidate) {
  if (!candidate || !candidate.osmNodeId || candidate.osmNodeId === "0") {
    throw new Error("seam missing OSM node identity");
  }
  if (!candidate.osmWayId || candidate.osmWayId === "0") {
    throw new Error("seam missing OSM way identity");
  }
  if (candidate.proof !== "shared-osm-node-way-edge-legal-topology.v1") {
    throw new Error("seam is not legal-topology proven");
  }
  if (Number(candidate.coordinateGapMeters) > 2) throw new Error("seam coordinate mismatch");
  const rows = seamCandidates(left, right);
  const identity = row => `${row.osmNodeId}|${row.osmWayId}|${edgeProofKey(row.edge)}`;
  let identities = seamProofIdentities.get(rows);
  if (!identities) {
    identities = new Set(rows.map(identity));
    seamProofIdentities.set(rows, identities);
  }
  const reproved = identities.has(identity(candidate));
  if (!reproved) throw new Error("seam proof does not match both packs");
  return true;
}

module.exports = {
  seamCandidates,
  assertSeamLegal,
  edgeProof,
  edgeProofKey,
  restrictionProofs,
  haversineMeters
};
