"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { parseArgs } = require("./ship-v4-candidate");

test("V4 ship door accepts only a sealed-fabric candidate command", () => {
  const parsed = parseArgs(["--candidate", "fabric-v4-20260907-01", "--pack", "--verify"]);
  assert.equal(parsed.candidate, "fabric-v4-20260907-01");
  assert.equal(parsed.pack, true);
  assert.equal(parsed.verify, true);
  assert.throws(() => parseArgs(["--candidate", "fabric-v4-20260907-01", "--pack", "--live"]), /forbidden/);
  assert.throws(() => parseArgs(["--candidate", "fabric-v4-20260907-01", "--pack", "--promote"]), /forbidden/);
  assert.throws(() => parseArgs(["--candidate", "ns-v4-legal-topology-20260906-02", "--pack"]), /release id/);
});
