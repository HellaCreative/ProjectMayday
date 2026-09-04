"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  polygonOwner,
  seamCorridor
} = require("./region-polygons");

test("admin polygons own Atlantic and Ontario pins without stealing neighbours", () => {
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
  assert.equal(polygonOwner(-75.6972, 45.4215), "on");
  assert.equal(polygonOwner(-79.3832, 43.6532), "on");
  assert.equal(polygonOwner(-97.1385, 49.8954), "mb");
  assert.equal(polygonOwner(-99.95, 49.8483), "mb");
  assert.equal(polygonOwner(-94.4897, 49.767), "on");
  assert.equal(polygonOwner(-104.6189, 50.4452), "sk");
  assert.equal(polygonOwner(-106.67, 52.1332), "sk");
  assert.equal(polygonOwner(-114.0719, 51.0447), "ab");
  assert.equal(polygonOwner(-113.4938, 53.5461), "ab");
  assert.equal(polygonOwner(-123.1207, 49.2827), "bc");
  assert.equal(polygonOwner(-119.496, 49.888), "bc");
});

test("seam corridor is the padded admin-bbox overlap", () => {
  const peNb = seamCorridor("pe", "nb");
  assert.ok(peNb);
  assert.ok(peNb.minLon < peNb.maxLon);
  assert.ok(peNb.minLat < peNb.maxLat);
  assert.ok(seamCorridor("qc", "nb"));
  assert.ok(seamCorridor("qc", "nl"));
  assert.ok(seamCorridor("qc", "on"));
  assert.ok(seamCorridor("on", "mb"));
  assert.ok(seamCorridor("mb", "sk"));
  assert.ok(seamCorridor("ab", "sk"));
  assert.ok(seamCorridor("bc", "ab"));
  assert.equal(seamCorridor("pe", "wa"), null);
});
