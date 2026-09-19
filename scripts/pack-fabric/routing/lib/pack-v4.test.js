"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { GRAPH_V4_MAGIC, GRAPH_V4_VERSION } = require("./pack-v4");
const { encodeGeometry, verifyGeometryGrid } = require("./pack-v4");
const { decodeGeometryV1 } = require("./pack-v2");

test("graph.v4 identity constants", () => {
  assert.equal(GRAPH_V4_VERSION, 4);
  assert.equal(GRAPH_V4_MAGIC, 0x34545244);
});

test("prepared matching bounds use stored coordinates without changing legacy geometry", () => {
  const edges = [
    { coords: [[-63.35, 44.70], [-63.3500001, 44.7000001], [-63.30, 44.75]] },
    { coords: [[-179.99, -89.99], [179.99, 89.99]] },
    { coords: [] },
    { coords: [[0.05, -0.05], [0.1, -0.1]] },
  ];
  const legacy = encodeGeometry(edges, { includeSpatialGrid: false });
  const prepared = encodeGeometry(edges);
  assert.equal(prepared.length - legacy.length, 8 * edges.length);
  assert.equal(prepared.readUInt16LE(6), 2);
  const decoded = decodeGeometryV1(prepared), original = decodeGeometryV1(legacy);
  assert.deepEqual(decoded.coords, original.coords);
  assert.deepEqual(decoded.offsets, original.offsets);
  edges.forEach((_, edge) => assert.deepEqual(decoded.polyline(edge), original.polyline(edge)));
  const base = Buffer.from(prepared.subarray(0, legacy.length));
  base.writeUInt16LE(0, 6);
  assert.deepEqual(base, legacy);
  edges.forEach(({ coords }, edge) => {
    const x = coords.map(p => Math.floor(Math.fround(p[0]) / 0.05));
    const y = coords.map(p => Math.floor(Math.fround(p[1]) / 0.05));
    const expected = coords.length ? [Math.min(...x), Math.max(...x), Math.min(...y), Math.max(...y)]
      : [32767, -32768, 32767, -32768];
    assert.deepEqual(Array.from({ length: 4 }, (_, i) => prepared.readInt16LE(legacy.length + edge * 8 + i * 2)), expected);
  });
  assert.equal(verifyGeometryGrid(prepared).edges, edges.length);
  assert.equal(verifyGeometryGrid(legacy).present, false);
  const altered = Buffer.from(prepared);
  altered.writeInt16LE(altered.readInt16LE(legacy.length) + 1, legacy.length);
  assert.throws(() => verifyGeometryGrid(altered), /differs from stored shape/);
  assert.throws(() => verifyGeometryGrid(prepared.subarray(0, prepared.length - 1)), /size mismatch/);
});

test("matching preparation rejects invalid geometry instead of hiding it", () => {
  for (const point of [[NaN, 40], [0, Infinity], [181, 0], [0, -91]]) {
    assert.throws(() => encodeGeometry([{ coords: [point] }]), /invalid geometry/);
  }
});
