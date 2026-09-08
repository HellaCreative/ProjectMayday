"use strict";
const LIMIT_METERS = 200;
function customerEndpointEdges(pack, edgeIndex, seeds, reverse = false) {
  const edges = new Set();
  if (!(pack.graphBinaryVersion >= 4) || edgeIndex < 0 ||
      ![pack.edgeAccess[edgeIndex * 2], pack.edgeAccess[edgeIndex * 2 + 1]].includes(4)) return edges;
  const adjacency = new Map();
  for (let node = 0; node < pack.nodeCount; node++) {
    for (let arc = pack.nodeOffsets[node]; arc < pack.nodeOffsets[node + 1]; arc++) {
      const ei = pack.edgeUndirectedIndex[arc], to = pack.edgeTargets[arc];
      const code = pack.edgeAccess[ei * 2 + (pack.edgeFrom[ei] === node ? 0 : 1)];
      if (code !== 4) continue;
      const source = reverse ? to : node, target = reverse ? node : to;
      if (!adjacency.has(source)) adjacency.set(source, []);
      adjacency.get(source).push({to:target, edge:ei, meters:Number(pack.edgeMeters[ei])});
    }
  }
  const distances = new Map(), queue = [];
  for (const {node, meters} of seeds) {
    if (node < 0 || node >= pack.nodeCount || meters < 0 || meters > LIMIT_METERS || !Number.isFinite(meters)) continue;
    if (meters < (distances.get(node) ?? Infinity)) {
      distances.set(node, meters); queue.push({node, meters});
    }
  }
  if (queue.length) edges.add(edgeIndex);
  while (queue.length) {
    queue.sort((a,b)=>b.meters-a.meters);
    const current = queue.pop();
    if (current.meters !== distances.get(current.node)) continue;
    for (const arc of adjacency.get(current.node) || []) {
      const meters = current.meters + arc.meters;
      if (meters > LIMIT_METERS) continue;
      edges.add(arc.edge);
      if (meters < (distances.get(arc.to) ?? Infinity)) {
        distances.set(arc.to, meters); queue.push({node:arc.to,meters});
      }
    }
  }
  return edges;
}
// A search mask is only an admissible candidate set. Check the actual path:
// customer roads form an endpoint prefix/suffix, never a through shortcut,
// and actual travelled customer metres (not radial distance) obey the limit.
function validCustomerRuns(rows, customerIds, startCustomer, endCustomer) {
  for (let i=0;i<rows.length;) {
    if (!customerIds.has(String(rows[i].edgeId))) { i++; continue; }
    const first=i; let meters=0;
    while (i<rows.length && customerIds.has(String(rows[i].edgeId))) meters+=Number(rows[i++].meters)||0;
    if (meters>LIMIT_METERS+0.01 || !((first===0 && startCustomer) || (i===rows.length && endCustomer))) return false;
  }
  return true;
}
module.exports={customerEndpointEdges,validCustomerRuns,LIMIT_METERS};
