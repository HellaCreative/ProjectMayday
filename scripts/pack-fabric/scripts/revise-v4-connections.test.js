"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { proveRecords } = require("./revise-v4-connections");
const edge = { osmWayId: "10", fromOsmNodeId: "1", toOsmNodeId: "2", accessForward: 0, accessReverse: 2, layer: 0, structureLeaf: null };
const row = { coordinate: [-74, 46], barrierDecision: 0, restrictions: [], edges: [edge] };
const records = value => new Map([["1", value]]);
test("connection revision requires matching coordinates, directional access, structure, barrier and turn proofs", () => {
  const left = records(row);
  assert.equal(proveRecords(left, records(row)).length, 1);
  for (const changed of [
    { ...row, coordinate: [-74, 46.001] },
    { ...row, barrierDecision: 2 },
    { ...row, restrictions: [{ osmRelationId: "100", kind: 1 }] },
    { ...row, edges: [{ ...edge, accessForward: 2 }] },
    { ...row, edges: [{ ...edge, layer: 1 }] },
    { ...row, edges: [{ ...edge, structureLeaf: "bridge" }] },
    { ...row, edges: [{ ...edge, fromOsmNodeId: "9" }] }
  ]) assert.deepEqual(proveRecords(left, records(changed)), []);
});
