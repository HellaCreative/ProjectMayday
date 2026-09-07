"use strict";

const { packHasDirectedArc, legalDirectedArcs } = require("./travel-direction");

function assertEncodedDirection(pack, edges) {
  if (!pack || !Array.isArray(edges)) {
    throw new Error("assertEncodedDirection requires pack and edges");
  }
  for (let ei = 0; ei < edges.length; ei += 1) {
    const edge = edges[ei];
    const a = Number(edge.a);
    const b = Number(edge.b);
    const legal = legalDirectedArcs(edge.d || edge.direction);
    const hasForward = packHasDirectedArc(pack, a, b, ei);
    const hasReverse = packHasDirectedArc(pack, b, a, ei);
    if (hasForward !== legal.forward || hasReverse !== legal.reverse) {
      throw new Error(
        `one-way mismatch on ${edge.i || ei}: expected forward=${legal.forward} reverse=${legal.reverse} got forward=${hasForward} reverse=${hasReverse}`
      );
    }
  }
  return true;
}

module.exports = {
  assertEncodedDirection
};
