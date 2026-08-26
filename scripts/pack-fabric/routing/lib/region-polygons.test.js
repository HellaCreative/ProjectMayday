"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  polygonOwner,
  seamCorridor
} = require("./region-polygons");

test("admin polygons own Atlantic pins without stealing neighbours", () => {
  assert.equal(polygonOwner(-63.5752, 44.6488), "ns");
  assert.equal(polygonOwner(-64.213, 45.833), "ns");
  assert.equal(polygonOwner(-64.368, 45.918), "nb");
  assert.equal(polygonOwner(-63.1316, 46.2382), "pe");
  assert.equal(polygonOwner(-63.696, 46.254), "pe");
  assert.equal(polygonOwner(-63.814, 46.162), "nb");
  assert.equal(polygonOwner(-54.6103, 48.9544), "nl");
  assert.equal(polygonOwner(-52.7126, 47.5615), "nl");
  assert.equal(polygonOwner(-66.9114, 52.9463), "nl");
  assert.equal(polygonOwner(-71.2075, 46.8139), "qc");
  assert.equal(polygonOwner(-73.5673, 45.5017), "qc");
  assert.equal(polygonOwner(-57.132, 51.426), "qc");
  assert.equal(polygonOwner(-75.6972, 45.4215), null);
});

test("seam corridor is the padded admin-bbox overlap", () => {
  const peNb = seamCorridor("pe", "nb");
  assert.ok(peNb);
  assert.ok(peNb.minLon < peNb.maxLon);
  assert.ok(peNb.minLat < peNb.maxLat);
  assert.ok(seamCorridor("qc", "nb"));
  assert.ok(seamCorridor("qc", "nl"));
  assert.equal(seamCorridor("pe", "wa"), null);
});
