"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { metadata, reviseMetadata } = require("./revise-v4-metadata");

function fixture() {
  const b = Buffer.alloc(512, 0x20);
  b.writeUInt32LE(0x34545244, 0); b.writeUInt16LE(4, 4); b.writeUInt32LE(140, 20);
  for (let field = 24; field <= 136; field += 4) b.writeUInt32LE(field < 72 ? 140 : 400, field);
  b.writeUInt32LE(160, 60);
  Buffer.from(JSON.stringify({ regionId: "nb", province: "nb", graphBinaryVersion: 4, capabilities: ["legal-topology.v1"], urbanCores: null })).copy(b, 160);
  for (let i = 400; i < 512; i++) b[i] = i % 256;
  return b;
}
test("metadata revision preserves opaque legal bytes and all section alignment", () => {
  const b = fixture(), original = Buffer.from(b);
  for (const count of [0, 1, 20]) {
    const next = { ...metadata(b), urbanCores: Array.from({ length: count }, (_, i) => ({ name: `Town ${i}`, minLat: 45, maxLat: 46, minLon: -65, maxLon: -64 })) };
    const result = reviseMetadata(b, next);
    assert(result.delta % 8 === 0);
    assert.deepEqual(metadata(result.buffer), next);
    assert(b.subarray(400).equals(result.buffer.subarray(400 + result.delta)));
    assert(b.equals(original));
  }
});
test("metadata writer refuses identity changes and invalid offsets", () => {
  const b = fixture();
  assert.throws(() => reviseMetadata(b, { ...metadata(b), regionId: "ns" }));
  b.writeUInt32LE(9999, 72);
  assert.throws(() => metadata(b));
});
