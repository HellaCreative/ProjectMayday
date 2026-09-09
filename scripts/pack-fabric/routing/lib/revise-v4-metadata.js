"use strict";
const assert = require("node:assert/strict");
const { GRAPH_V4_MAGIC, GRAPH_V4_VERSION } = require("./pack-v4");

// Offset fields in the existing V4 header, not counts/flags/header size.
const POINTER_FIELDS = Array.from({ length: 29 }, (_, i) => 24 + i * 4);
function metadata(buffer) {
  if (buffer.readUInt32LE(0) !== GRAPH_V4_MAGIC || buffer.readUInt16LE(4) !== GRAPH_V4_VERSION) throw new Error("V4 required");
  const start = buffer.readUInt32LE(60), end = buffer.readUInt32LE(72);
  if (start < buffer.readUInt32LE(20) || end < start || end > buffer.length) throw new Error("Invalid metadata offsets");
  return JSON.parse(buffer.subarray(start, end).toString("utf8"));
}
function reviseMetadata(buffer, replacement) {
  const prior = metadata(buffer);
  if (replacement.regionId !== prior.regionId || replacement.province !== prior.province || replacement.graphBinaryVersion !== prior.graphBinaryVersion) throw new Error("Metadata cannot change graph identity");
  assert.deepEqual(replacement.capabilities, prior.capabilities);
  const start = buffer.readUInt32LE(60), end = buffer.readUInt32LE(72);
  const encoded = Buffer.from(JSON.stringify(replacement));
  // Preserve every later section's existing alignment, including 64-bit IDs.
  const delta = Math.ceil((encoded.length - (end - start)) / 8) * 8;
  const out = Buffer.alloc(buffer.length + delta);
  buffer.copy(out, 0, 0, start);
  out.fill(0x20, start, end + delta);
  encoded.copy(out, start);
  buffer.copy(out, end + delta, end);
  for (const field of POINTER_FIELDS) {
    const offset = buffer.readUInt32LE(field);
    out.writeUInt32LE(offset >= end ? offset + delta : offset, field);
  }
  assert.deepEqual(metadata(out), replacement);
  assert(buffer.subarray(buffer.readUInt32LE(20), start).equals(out.subarray(out.readUInt32LE(20), start)), "Road prefix changed");
  assert(buffer.subarray(end).equals(out.subarray(end + delta)), "Road/legal suffix changed");
  return { buffer: out, delta, prior };
}
module.exports = { metadata, reviseMetadata, POINTER_FIELDS };
