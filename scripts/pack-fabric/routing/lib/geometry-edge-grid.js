"use strict";

// Long ferry rectangles may span millions of cells. Keep those rectangles once
// and merge them into each queried bucket, retaining the original index order.
// This changes storage only: every cell returns the exact original candidates.
function buildEdgeGridFromGeom(geom, edgeCount) {
  const GRID = 0.01;
  const buckets = new Map();
  const broad = [];
  for (let index = 0; index < edgeCount; index++) {
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (let i = geom.offsets[index]; i < geom.offsets[index + 1]; i += 2) {
      minX = Math.min(minX, geom.coords[i]); maxX = Math.max(maxX, geom.coords[i]);
      minY = Math.min(minY, geom.coords[i + 1]); maxY = Math.max(maxY, geom.coords[i + 1]);
    }
    if (!Number.isFinite(minX)) continue;
    const x0 = Math.floor(minX / GRID), x1 = Math.floor(maxX / GRID);
    const y0 = Math.floor(minY / GRID), y1 = Math.floor(maxY / GRID);
    if ((x1 - x0 + 1) * (y1 - y0 + 1) > 256) {
      broad.push({index, x0, x1, y0, y1});
      continue;
    }
    for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) {
      const key = x + ":" + y;
      let bucket = buckets.get(key);
      if (!bucket) buckets.set(key, bucket = []);
      bucket.push(index);
    }
  }
  if (!broad.length) return {edgeGrid: buckets, GRID};
  return {GRID, edgeGrid: {
    get(key) {
      const split = key.indexOf(":");
      const x = Number(key.slice(0, split)), y = Number(key.slice(split + 1));
      const ordinary = buckets.get(key);
      let result = null;
      for (const r of broad) if (x >= r.x0 && x <= r.x1 && y >= r.y0 && y <= r.y1) {
        if (!result) result = ordinary ? ordinary.slice() : [];
        result.push(r.index);
      }
      return result ? result.sort((a,b) => a-b) : ordinary;
    }
  }};
}
module.exports = {buildEdgeGridFromGeom};
