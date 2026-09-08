"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { pruneGeographicLoops } = require("./path-pruning");

test("directed routes retain the legal connection between nearby separate roads", () => {
  const edges = [
    { edgeId: "east-carriageway", meters: 1000, coords: [[0, 45], [0.01, 45]] },
    { edgeId: "ramp", meters: 500, coords: [[0.01, 45], [0.01, 45.004]] },
    { edgeId: "return-road", meters: 1500, coords: [[0.01, 45.004], [0, 45.0001]] },
    { edgeId: "west-carriageway", meters: 1000, coords: [[0, 45.0001], [-0.01, 45.0001]] }
  ];
  const original = structuredClone(edges);
  assert.ok(pruneGeographicLoops(edges, e => e.coords).prunedLoopCount > 0,
    "the old proximity rule actually removes this required connection");
  const legal = pruneGeographicLoops(edges, e => e.coords, { preserveTopology: true });
  assert.deepEqual(legal.edges, original);
  assert.equal(legal.prunedLoopCount, 0);
  assert.equal(legal.prunedMeters, 0);
});
