"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const os = require("node:os");
const { graphHeapMiB } = require("./build-v4-fabric");

test("V4 graph worker cannot claim the host's entire physical memory", () => {
  const physicalMiB = Math.floor(os.totalmem() / (1024 * 1024));
  assert.ok(graphHeapMiB() <= Math.floor(physicalMiB * 0.62));
  assert.ok(graphHeapMiB() >= 2048);
});
