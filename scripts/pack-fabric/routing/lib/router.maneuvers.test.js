"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { graphDecisionManeuvers } = require("./router");

function makeEdge(edgeId, a, b, coords, meters = 100) {
  return {
    edgeId,
    a,
    b,
    coords,
    meters,
    roadTrack: "secondary",
    virtual: false,
    accessLeg: false
  };
}

test("graph decisions include straight-through choices and stable identity", () => {
  const incoming = makeEdge("in", 0, 1, [[0, 0], [0, 1]]);
  const outgoing = makeEdge("out", 1, 2, [[0, 1], [0, 2]]);
  const branch = makeEdge("branch", 1, 3, [[0, 1], [1, 1]]);
  const byNode = new Map([[1, [
    { to: 0, edge: incoming },
    { to: 2, edge: outgoing },
    { to: 3, edge: branch }
  ]] ]);

  const result = graphDecisionManeuvers(
    [incoming, outgoing],
    (edge) => edge.coords,
    (node) => byNode.get(node) || []
  );

  assert.equal(result[0].type, "continueStraight");
  assert.equal(result[0].kind, "junction");
  assert.equal(result[0].instruction, "Continue straight");
  assert.equal(result[0].stableID, "jct:in>out");
  assert.equal(result[0].alongMeters, 100);
  assert.equal(result.at(-1).type, "arrive");
});

test("graph decisions announce chosen turn direction", () => {
  const incoming = makeEdge("in", 0, 1, [[0, 0], [0, 1]]);
  const outgoing = makeEdge("out", 1, 2, [[0, 1], [1, 1]]);
  const branch = makeEdge("branch", 1, 3, [[0, 1], [0, 2]]);

  const result = graphDecisionManeuvers(
    [incoming, outgoing],
    (edge) => edge.coords,
    () => [
      { to: 0, edge: incoming },
      { to: 2, edge: outgoing },
      { to: 3, edge: branch }
    ]
  );

  assert.equal(result[0].type, "turn");
  assert.equal(result[0].side, "right");
  assert.equal(result[0].instruction, "Turn right");
  assert.equal(result[0].degrees, 90);
});

test("geometry bends without a graph choice are not junctions", () => {
  const incoming = makeEdge("in", 0, 1, [[0, 0], [0, 1]]);
  const outgoing = makeEdge("out", 1, 2, [[0, 1], [1, 1]]);

  const result = graphDecisionManeuvers(
    [incoming, outgoing],
    (edge) => edge.coords,
    () => [
      { to: 0, edge: incoming },
      { to: 2, edge: outgoing }
    ]
  );

  assert.deepEqual(result.map((item) => item.type), ["arrive"]);
});
