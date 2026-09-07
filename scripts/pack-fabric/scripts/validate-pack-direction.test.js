"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");
const { encodeFromV1 } = require("../routing/lib/pack-v2");
const { main } = require("./validate-pack-direction");

test("validate-pack-direction accepts a one-way CSR whose arc count matches", () => {
  const tmp = path.join(__dirname, "..", "app", "data", "packs", "v1", "fixture-oneway");
  const fs = require("fs");
  fs.mkdirSync(tmp, { recursive: true });
  const { graphBuffer } = encodeFromV1({
    nodeCount: 2,
    nodes: [[0, 0], [0.001, 0]],
    regionId: "fixture-oneway",
    edges: [{
      i: "ow", a: 0, b: 1, m: 10, s: 0, ac: 0, t: 0, rt: "freeway", conf: "high",
      d: "forward", g: [[0, 0], [0.001, 0]]
    }]
  });
  fs.writeFileSync(path.join(tmp, "graph.v3.bin"), graphBuffer);
  try {
    const report = main(["fixture-oneway"]);
    assert.equal(report.oneWayEdges, 1);
    assert.equal(report.twoWayEdges, 0);
    assert.equal(report.directedArcCount, 1);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
