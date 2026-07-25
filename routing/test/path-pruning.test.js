const test = require("node:test");
const assert = require("node:assert/strict");

const { pruneGeographicLoops } = require("../lib/path-pruning");

function edge(id, coords, meters = 100, extra = {}) {
  return { edgeId: id, coords, meters, ...extra };
}

test("removes a dead-end out-and-back while preserving the through journey", () => {
  const used = [
    edge("approach", [[0, 0], [1, 0]]),
    edge("spur-out", [[1, 0], [1, 1]]),
    edge("spur-tip", [[1, 1], [2, 1]]),
    edge("parallel-return", [[2, 1], [1, 0]]),
    edge("continue", [[1, 0], [2, 0]])
  ];

  const result = pruneGeographicLoops(used, (item) => item.coords);

  assert.deepEqual(result.edges.map((item) => item.edgeId), ["approach", "continue"]);
  assert.equal(result.prunedLoopCount, 1);
  assert.equal(result.prunedMeters, 300);
});

test("splits boundary edges when a retrace rejoins at interior coordinates", () => {
  const used = [
    edge("approach", [[0, 0], [1, 0], [2, 0]], 200),
    edge("spur", [[2, 0], [2, 1]], 100),
    edge("return-and-continue", [[2, 1], [1, 0], [1, -1]], 200),
    edge("finish", [[1, -1], [2, -1]], 100)
  ];

  const result = pruneGeographicLoops(used, (item) => item.coords);

  assert.deepEqual(result.edges.map((item) => item.edgeId), [
    "approach",
    "return-and-continue",
    "finish"
  ]);
  assert.deepEqual(result.edges[0].coords, [[0, 0], [1, 0]]);
  assert.deepEqual(result.edges[1].coords, [[1, 0], [1, -1]]);
  assert.equal(result.prunedLoopCount, 1);
  assert.ok(result.prunedMeters > 0);
});

test("leaves a simple forward-progress path unchanged", () => {
  const used = [
    edge("a", [[0, 0], [1, 0]]),
    edge("b", [[1, 0], [2, 0]]),
    edge("c", [[2, 0], [3, 0]])
  ];

  const result = pruneGeographicLoops(used, (item) => item.coords);

  assert.deepEqual(result.edges, used);
  assert.equal(result.prunedLoopCount, 0);
  assert.equal(result.prunedMeters, 0);
});

test("closes a rounded duplicate without creating a geometry gap", () => {
  const used = [
    edge("approach", [[0, 0], [1.0000001, 0]]),
    edge("spur", [[1.0000001, 0], [1, 1]]),
    edge("return", [[1, 1], [1.0000002, 0]]),
    edge("continue", [[1.0000002, 0], [2, 0]])
  ];

  const result = pruneGeographicLoops(used, (item) => item.coords);

  const approachEnd = result.edges[0].coords.at(-1);
  const continueStart = result.edges[1].coords[0];
  assert.deepEqual(continueStart, approachEnd);
});
