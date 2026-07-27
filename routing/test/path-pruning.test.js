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

test("removes a residential house-loop that rejoins the through road", () => {
  // Direct-style tendril: leave the main road, circle a block, rejoin, continue.
  const used = [
    edge("main-in", [[0, 0], [1, 0]], 100),
    edge("loop-n", [[1, 0], [1, 0.001]], 110),
    edge("loop-e", [[1, 0.001], [1.001, 0.001]], 110),
    edge("loop-s", [[1.001, 0.001], [1.001, 0]], 110),
    edge("loop-w", [[1.001, 0], [1, 0]], 110),
    edge("main-out", [[1, 0], [2, 0]], 100)
  ];

  const result = pruneGeographicLoops(used, (item) => item.coords);

  assert.deepEqual(result.edges.map((item) => item.edgeId), ["main-in", "main-out"]);
  assert.ok(result.prunedLoopCount >= 1);
  assert.ok(result.prunedMeters > 0);
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

test("removes a dual-fabric near-miss triangle that exact keys would miss", () => {
  // Same physical junction, two fabrics offset by ~8–12 m — the painted path
  // goes out on the road curve, then returns via a straight chord (or parallel
  // representation) before making the real turn. Exact precision-6 keys miss it.
  const before = [-63.122, 44.982];
  const junction = [-63.12, 44.985];
  const alongRoad = [-63.118, 44.988];
  const furtherUp = [-63.115, 44.991];
  const nearJunction = [-63.12005, 44.98508]; // ~10 m from junction (cell boundary)
  const used = [
    edge("pre", [before, junction], 350),
    edge("approach", [junction, alongRoad], 400),
    edge("overshoot", [alongRoad, furtherUp], 450),
    edge("chord-return", [furtherUp, nearJunction], 700),
    edge("real-turn", [nearJunction, [-63.125, 44.986]], 400)
  ];

  const exact = pruneGeographicLoops(used, (item) => item.coords, { exactOnly: true });
  assert.equal(exact.prunedLoopCount, 0, "exact keys must miss the near-miss");

  const result = pruneGeographicLoops(used, (item) => item.coords, {
    cellMeters: 20,
    matchMeters: 25
  });
  assert.ok(result.prunedLoopCount >= 1, "proximity cells must erase the triangle");
  assert.ok(result.prunedMeters > 0);
  const ids = result.edges.map((item) => item.edgeId);
  assert.ok(ids.includes("pre"), "through progress before the junction stays");
  assert.ok(ids.includes("real-turn"), "the real turn after rejoin stays");
  assert.ok(!ids.includes("chord-return"), "chord return must be removed");
  assert.ok(!ids.includes("overshoot"), "overshoot arm must be removed");
});
