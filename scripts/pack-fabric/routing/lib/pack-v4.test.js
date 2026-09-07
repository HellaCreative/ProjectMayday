"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { GRAPH_V4_MAGIC, GRAPH_V4_VERSION } = require("./pack-v4");

test("graph.v4 identity constants", () => {
  assert.equal(GRAPH_V4_VERSION, 4);
  assert.equal(GRAPH_V4_MAGIC, 0x34545244);
});
