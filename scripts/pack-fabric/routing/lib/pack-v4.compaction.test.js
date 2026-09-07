"use strict";

const fs = require("fs");
const path = require("path");
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  FLAG_V4_DERIVED_EDGE_IDS,
  compactGraphV4Buffer,
  decodeGraphV4,
  int64StringView
} = require("./pack-v4");

const FIXTURES = path.resolve(__dirname, "../fixtures/legal-topology");

test("packed OSM ids stay array-like without eager string copies", () => {
  const bytes = Buffer.alloc(24);
  bytes.writeBigInt64LE(11n, 0);
  bytes.writeBigInt64LE(22n, 8);
  bytes.writeBigInt64LE(33n, 16);
  const ids = int64StringView(bytes, 0, 3);
  assert.equal(ids.length, 3);
  assert.equal(ids[1], "22");
  assert.equal(ids.at(-1), "33");
  assert.equal(ids.includes("22"), true);
  assert.equal(ids.includes(22), false);
  assert.equal(ids.findIndex((id) => id === "33"), 2);
  assert.deepEqual(ids.map((id) => `w${id}`), ["w11", "w22", "w33"]);
  assert.deepEqual([...ids], ["11", "22", "33"]);
});

test("legacy V4 edge ids compact losslessly and remain stable", () => {
  const legacy = fs.readFileSync(path.join(FIXTURES, "legal-topology-canary-legacy.graph.v4.bin"));
  assert.equal(legacy.readUInt16LE(6) & FLAG_V4_DERIVED_EDGE_IDS, 0);
  const before = decodeGraphV4(legacy);
  const compacted = compactGraphV4Buffer(legacy);
  assert.ok(compacted.savedBytes > 0);
  assert.ok(compacted.graphBuffer.length < legacy.length);
  assert.notEqual(compacted.graphBuffer.readUInt16LE(6) & FLAG_V4_DERIVED_EDGE_IDS, 0);

  const after = decodeGraphV4(compacted.graphBuffer);
  assert.equal(after.nodeCount, before.nodeCount);
  assert.equal(after.edgeCount, before.edgeCount);
  assert.deepEqual([...after.edgeFrom], [...before.edgeFrom]);
  assert.deepEqual([...after.edgeTo], [...before.edgeTo]);
  assert.deepEqual([...after.osmWayIds], [...before.osmWayIds]);
  for (let edge = 0; edge < before.edgeCount; edge += 1) {
    assert.equal(after.edgeId(edge), before.edgeId(edge));
  }
  assert.equal(after.edgeId(-1), "");
  assert.equal(after.edgeId(after.edgeCount), "");

  const second = compactGraphV4Buffer(compacted.graphBuffer);
  assert.equal(second.alreadyCompact, true);
  assert.equal(second.savedBytes, 0);
  assert.equal(second.graphBuffer, compacted.graphBuffer);
});
