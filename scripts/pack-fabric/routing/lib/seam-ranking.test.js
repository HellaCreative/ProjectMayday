"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { rankSeams } = require("./seam-ranking");
test("nearby disconnected seams cannot fill every retry slot", () => {
  const small = Array.from({length: 30}, (_, i) => ({componentPair:"small",networkSize:4,d:i}));
  const main = {componentPair:"main",networkSize:800000,d:100};
  const other = {componentPair:"other",networkSize:19,d:50};
  const ranked = rankSeams([...small, main, other], r => r.d);
  assert.deepEqual(ranked.slice(0,3),[main,other,small[0]]);
  assert.equal(ranked.length,32);
});
test("legacy seam records preserve distance ranking", () => {
  assert.deepEqual(rankSeams([{d:3},{d:1},{d:2}],r=>r.d),[{d:1},{d:2},{d:3}]);
});
