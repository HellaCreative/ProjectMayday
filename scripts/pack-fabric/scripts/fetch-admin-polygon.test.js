"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { unionCoverage, coverageRelationIds } = require("./fetch-admin-polygon");
const { pointInGeometry } = require("../routing/lib/region-polygons");

test("combined administrative coverage preserves holes and does not bridge gaps", () => {
  const polygon = { type: "Polygon", coordinates: [
    [[0,0],[3,0],[3,3],[0,3],[0,0]],
    [[1,1],[1,2],[2,2],[2,1],[1,1]]
  ] };
  assert.equal(unionCoverage([polygon]), polygon);
  const combined = unionCoverage([polygon, { type: "Polygon", coordinates: [
    [[5,0],[6,0],[6,3],[5,3],[5,0]]
  ] }]);
  assert.equal(pointInGeometry(0.5,0.5,combined), true);
  assert.equal(pointInGeometry(1.5,1.5,combined), false);
  assert.equal(pointInGeometry(4,1,combined), false);
  assert.equal(pointInGeometry(5.5,1,combined), true);
});

test("D.C. coverage belongs to Maryland and other region identities remain singular", () => {
  assert.deepEqual(coverageRelationIds("md"), [162112,162069]);
  assert.equal(coverageRelationIds("va").length, 1);
  assert.equal(coverageRelationIds("ns").length, 1);
});
