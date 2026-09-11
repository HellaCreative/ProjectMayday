"use strict";
const fs = require('node:fs');

// Read exact edge ranges instead of dragging 999 unrelated edges into each miss.
// The edge cap and byte cap are independent. An oversize edge is read completely,
// returned uncached, and included in transient peak accounting; never clipped.
function openGeometry(file, capacity, maxBytes = 8 * 1024 * 1024) {
  if (!Number.isSafeInteger(capacity) || capacity < 1 || !Number.isSafeInteger(maxBytes) || maxBytes < 1)
    throw new TypeError('Positive edge and byte capacities required');
  const fd = fs.openSync(file, 'r'), cache = new Map();
  const stats = {reads: 0, bytesRead: 0, hits: 0, misses: 0, residentBytes: 0,
    peakResidentBytes: 0, peakResidentEdges: 0, peakReadPlusResidentBytes: 0};
  function read(at, length) {
    const buffer = Buffer.allocUnsafeSlow(length);
    let done = 0;
    while (done < length) {
      const n = fs.readSync(fd, buffer, done, length - done, at + done);
      if (!n) throw new Error('Truncated geometry');
      done += n;
    }
    stats.reads++; stats.bytesRead += length;
    return buffer;
  }
  let offsets, count, dataAt;
  try {
    const h = read(0, 16);
    // The paired graph SHA is checked by the benchmark before opening this reader.
    if (h.readUInt32LE(0) !== 0x4d4f4547 || h.readUInt16LE(4) !== 1) throw new Error('Invalid geometry header');
    count = h.readUInt32LE(8);
    const b = read(16, (count + 1) * 4);
    offsets = new Uint32Array(b.buffer, b.byteOffset, count + 1);
    dataAt = 16 + b.length;
    if (offsets[0] !== 0 || offsets[count] !== h.readUInt32LE(12) ||
        dataAt + offsets[count] * 4 !== fs.fstatSync(fd).size) throw new Error('Invalid geometry length');
    for (let i = 0; i < count; i++)
      if (offsets[i] > offsets[i + 1] || offsets[i] % 2 || offsets[i + 1] % 2) throw new Error('Invalid geometry offsets');
  } catch (error) { fs.closeSync(fd); throw error; }
  stats.offsetBytes = offsets.byteLength;
  function coordinateRange(edge) {
    if (!Number.isSafeInteger(edge) || edge < 0 || edge >= count) throw new RangeError('Invalid geometry edge');
    let coords = cache.get(edge);
    if (coords) { cache.delete(edge); cache.set(edge, coords); stats.hits++; }
    else {
      stats.misses++;
      const length = (offsets[edge + 1] - offsets[edge]) * 4;
      while (cache.size && (cache.size >= capacity || stats.residentBytes + length > maxBytes)) {
        const first = cache.keys().next().value;
        stats.residentBytes -= cache.get(first).byteLength; cache.delete(first);
      }
      const b = read(dataAt + offsets[edge] * 4, length);
      coords = new Float32Array(b.buffer, b.byteOffset, length / 4);
      stats.peakReadPlusResidentBytes = Math.max(stats.peakReadPlusResidentBytes, stats.residentBytes + length);
      if (length <= maxBytes) { cache.set(edge, coords); stats.residentBytes += length; }
      stats.peakResidentBytes = Math.max(stats.peakResidentBytes, stats.residentBytes);
      stats.peakResidentEdges = Math.max(stats.peakResidentEdges, cache.size);
    }
    return {coords, start: 0, end: coords.length};
  }
  return {coordinateRange, polyline(edge) {
    const {coords} = coordinateRange(edge), result = [];
    for (let i = 0; i < coords.length; i += 2) result.push([coords[i], coords[i + 1]]);
    return result;
  }, stats, close() { fs.closeSync(fd); }};
}
module.exports = {openGeometry};
