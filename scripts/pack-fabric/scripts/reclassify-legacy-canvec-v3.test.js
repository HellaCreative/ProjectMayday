"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { patchedAttribute, reclassifiedEdgeIds } = require("./reclassify-legacy-canvec-v3");
const { unpackAccess, unpackConfidence } = require("../routing/lib/pack-v2");

function attr(access, confidence) {
  return (access << 3) | (confidence << 9) | 5 | (6 << 12);
}

function pack(rows) {
  return {
    undirectedEdgeCount: rows.length,
    edgeAttrs: Uint16Array.from(rows.map((row) => row.attr)),
    edgeId: (index) => rows[index].id
  };
}

test("only common permissive-to-unknown low-confidence edges are selected", () => {
  const base = pack([
    { id: "canvec-track", attr: attr(1, 1) },
    { id: "ordinary-road", attr: attr(1, 1) },
    { id: "already-unknown", attr: attr(2, 2) }
  ]);
  const classified = pack([
    { id: "canvec-track", attr: attr(2, 2) },
    { id: "ordinary-road", attr: attr(1, 1) },
    { id: "already-unknown", attr: attr(2, 2) },
    { id: "new-topology", attr: attr(2, 2) }
  ]);
  assert.deepEqual(reclassifiedEdgeIds(base, classified), [
    { ei: 0, id: "canvec-track" }
  ]);
});

test("patch changes only access and confidence bit fields", () => {
  const before = attr(1, 1);
  const after = patchedAttribute(before);
  assert.equal(unpackAccess(after), 2);
  assert.equal(unpackConfidence(after), "low");
  const mutableMask = (7 << 3) | (3 << 9);
  assert.equal(after & ~mutableMask, before & ~mutableMask);
});
