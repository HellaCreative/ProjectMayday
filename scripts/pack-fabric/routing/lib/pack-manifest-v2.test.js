"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { validatePackManifestV2 } = require("./pack-manifest-v2");

test("pack-manifest.v2 rejects missing capability", () => {
  assert.throws(() =>
    validatePackManifestV2({
      schema: "pack-manifest.v2",
      capabilities: [],
      graph: { name: "graph.v4.bin", bytes: 1, sha256: "a" },
      geometry: { name: "geometry.v1.bin", bytes: 1, sha256: "b" },
      fuel: { name: "fuel.v1.json", bytes: 1, sha256: "c" },
      sourceEpoch: "e"
    })
  );
});
