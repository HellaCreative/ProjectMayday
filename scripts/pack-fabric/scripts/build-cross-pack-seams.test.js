"use strict";

const assert = require("assert");
const { candidates, spread } = require("./build-cross-pack-seams");

function graph(region, edges) {
  return { regionId: region, nodeCount: 4, edges };
}

const left = graph("bc", [
  { i: "bc-1", a: 0, b: 1, rid: "w42", src: "OpenStreetMap", ac: 1, s: 0, rt: "local", g: [[-117, 49], [-116.9, 49]] },
  { i: "bc-2", a: 2, b: 3, rid: "w99", src: "OpenStreetMap", ac: 1, s: 1, rt: "track", g: [[-118, 49], [-117.9, 49]] }
]);
const right = graph("wa", [
  { i: "wa-1", a: 0, b: 1, rid: "w42", src: "OpenStreetMap", ac: 1, s: 0, rt: "local", g: [[-117.1, 49], [-117, 49]] },
  { i: "wa-2", a: 2, b: 3, rid: "w100", src: "OpenStreetMap", ac: 1, s: 1, rt: "track", g: [[-118, 49], [-117.9, 49]] }
]);

const found = candidates(left, right);
assert.strictEqual(found.length, 1);
assert.deepStrictEqual(found[0].coordinate, [-117, 49]);
assert.strictEqual(found[0].osmWayId, "w42");
assert.strictEqual(found[0].gapMeters, 0);
assert.strictEqual(spread(found, 1).length, 1);
console.log("build-cross-pack-seams tests passed");
