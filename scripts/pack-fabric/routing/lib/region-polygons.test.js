"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  polygonOwner,
  seamCorridor,
  pointInGeometry
} = require("./region-polygons");

test("Maryland coverage includes D.C. without stealing Virginia", () => {
  const fs = require("node:fs");
  const { clipGeojsonPath, coverageRelationIds } = require("../../scripts/fetch-admin-polygon");
  assert.deepEqual(coverageRelationIds("md"), [162112, 162069]);
  const clip = JSON.parse(fs.readFileSync(clipGeojsonPath("md")));
  const geometry = clip.geometry || clip.features[0].geometry;
  for (const point of [[-77.0365,38.8977],[-76.986,38.880],[-77.0261,38.9897]]) {
    assert.equal(pointInGeometry(...point, geometry), true);
    assert.equal(polygonOwner(...point), "md");
  }
  assert.equal(polygonOwner(-77.0469,38.8048), "va");
  assert.equal(pointInGeometry(-77.0469,38.8048, geometry), false);
});

test("western Newfoundland stays on the island; Labrador follows its OSM boundary", () => {
  const { newfoundlandHalfForPoint } = require("../regional/select");
  for (const [lon,lat,expected] of [
    [-59.137,47.57,"nl-island"],[-57.95,48.95,"nl-island"],[-52.713,47.56,"nl-island"],
    [-55.59,51.37,"nl-island"],[-54.285,49.715,"nl-island"],[-56.43,51.73,"nl-lab"],[-60.33,53.30,"nl-lab"]
  ]) {
    assert.equal(polygonOwner(lon,lat),expected);
    assert.equal(newfoundlandHalfForPoint(lon,lat),expected);
  }
  assert.throws(() => require("../../scripts/split-subregion-polygons").parseArgs([
    "--parent","nl","--east","nl-island","--west","nl-lab","--cut-lon","-56.8"
  ]), /administrative boundary/);
});

test("admin polygons own Atlantic and Ontario pins without stealing neighbours", () => {
  assert.equal(polygonOwner(-63.5752, 44.6488), "ns");
  assert.equal(polygonOwner(-64.213, 45.833), "ns");
  assert.equal(polygonOwner(-64.368, 45.918), "nb");
  assert.equal(polygonOwner(-63.1316, 46.2382), "pe");
  assert.equal(polygonOwner(-63.696, 46.254), "pe");
  assert.equal(polygonOwner(-63.814, 46.162), "nb");
  assert.equal(polygonOwner(-54.6103, 48.9544), "nl-island");
  assert.equal(polygonOwner(-52.7126, 47.5615), "nl-island");
  assert.equal(polygonOwner(-66.9114, 52.9463), "nl-lab");
  assert.equal(polygonOwner(-71.2075, 46.8139), "qc-s");
  assert.equal(polygonOwner(-73.5673, 45.5017), "qc-s");
  assert.equal(polygonOwner(-57.132, 51.426), "qc-n");
  assert.equal(polygonOwner(-75.6972, 45.4215), "on-s");
  assert.equal(polygonOwner(-79.3832, 43.6532), "on-s");
  assert.equal(polygonOwner(-97.1385, 49.8954), "mb");
  assert.equal(polygonOwner(-99.95, 49.8483), "mb");
  assert.equal(polygonOwner(-94.4897, 49.767), "on-n");
  assert.equal(polygonOwner(-104.6189, 50.4452), "sk");
  assert.equal(polygonOwner(-106.67, 52.1332), "sk");
  assert.equal(polygonOwner(-114.0719, 51.0447), "ab");
  assert.equal(polygonOwner(-113.4938, 53.5461), "ab");
  assert.equal(polygonOwner(-123.1207, 49.2827), "bc");
  assert.equal(polygonOwner(-119.496, 49.888), "bc");
  assert.equal(polygonOwner(-135.0568, 60.7212), "yt");
  assert.equal(polygonOwner(-114.3718, 62.454), "nt");
  assert.equal(polygonOwner(-115.7999, 60.8156), "nt");
  assert.equal(polygonOwner(-68.517, 63.7467), "nu");
  assert.equal(polygonOwner(-92.0896, 62.8106), "nu");
  assert.equal(polygonOwner(-70.2558, 43.6591), "me");
  assert.equal(polygonOwner(-67.2786, 45.189), "me");
  assert.equal(polygonOwner(-67.2778, 45.1946), "nb");
  assert.equal(polygonOwner(-71.5376, 43.2081), "nh");
  assert.equal(polygonOwner(-71.4548, 42.9956), "nh");
  assert.equal(polygonOwner(-72.2786, 42.9337), "nh");
  assert.equal(polygonOwner(-72.5754, 44.2601), "vt");
  assert.equal(polygonOwner(-73.2121, 44.4759), "vt");
  assert.equal(polygonOwner(-73.7562, 42.6526), "ny");
  assert.equal(polygonOwner(-78.8784, 42.8864), "ny");
  assert.equal(polygonOwner(-73.4529, 44.6995), "ny");
  assert.equal(polygonOwner(-84.7147, 44.6611), "mi");
  assert.equal(polygonOwner(-88.569, 47.1211), "mi");
  assert.equal(polygonOwner(-84.5555, 42.7325), "mi");
  assert.equal(polygonOwner(-83.0364, 42.3143), "on-s");
  assert.equal(polygonOwner(-93.265, 44.9778), "mn");
  assert.equal(polygonOwner(-92.1005, 46.7867), "mn");
  assert.equal(polygonOwner(-100.7837, 46.8083), "nd");
  assert.equal(polygonOwner(-96.7898, 46.8772), "nd");
  assert.equal(polygonOwner(-122.3321, 47.6062), "wa");
  assert.equal(polygonOwner(-117.426, 47.6588), "wa");
  assert.equal(polygonOwner(-116.2023, 43.615), "id");
  assert.equal(polygonOwner(-116.7805, 47.6777), "id");
  assert.equal(polygonOwner(-113.994, 46.8721), "mt");
  assert.equal(polygonOwner(-114.3129, 48.1958), "mt");
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
  assert.ok(seamCorridor("yt", "bc"));
  assert.ok(seamCorridor("nt", "ab"));
  assert.ok(seamCorridor("nu", "nt"));
  assert.ok(seamCorridor("nu", "mb"));
  assert.ok(seamCorridor("me", "nb"));
  assert.ok(seamCorridor("nh", "me"));
  assert.ok(seamCorridor("nh", "qc"));
  assert.ok(seamCorridor("vt", "nh"));
  assert.ok(seamCorridor("vt", "qc"));
  assert.ok(seamCorridor("ny", "vt"));
  assert.ok(seamCorridor("ny", "qc"));
  assert.ok(seamCorridor("mi", "on"));
  assert.ok(seamCorridor("mn", "on"));
  assert.ok(seamCorridor("mn", "mb"));
  assert.ok(seamCorridor("nd", "mb"));
  assert.ok(seamCorridor("nd", "sk"));
  assert.ok(seamCorridor("wa", "bc"));
  assert.ok(seamCorridor("id", "bc"));
  assert.ok(seamCorridor("mt", "ab"));
  assert.ok(seamCorridor("mt", "sk"));
  assert.ok(seamCorridor("mt", "bc"));
  assert.equal(seamCorridor("pe", "wa"), null);
});
