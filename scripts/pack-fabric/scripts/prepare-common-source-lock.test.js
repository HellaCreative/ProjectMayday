"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { parseArgs } = require("./prepare-common-source-lock");
test("common source requires a publisher checksum and explicit supported region set", () => {
  const args = ["--source", "source.pbf", "--url", "https://example.invalid/dated.pbf", "--md5", "a".repeat(32), "--output", "lock.json"];
  assert.deepEqual(parseArgs([...args, "qc-n", "ns", "ns"]).regions, ["ns", "qc-n"]);
  assert.throws(() => parseArgs(args));
  assert.throws(() => parseArgs([...args, "made-up"]));
  assert.throws(() => parseArgs([...args, "ns", "--refresh"]));
  assert.throws(() => parseArgs(["--source"]));
});
