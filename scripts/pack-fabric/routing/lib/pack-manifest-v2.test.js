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

function valid() {
  return {
    schema: "pack-manifest.v2",
    fabricReleaseId: "fabric-v4-20260907",
    regionId: "ns",
    capabilities: ["legal-topology.v1"],
    graph: { name: "graph.v4.bin", bytes: 10, sha256: "a".repeat(64) },
    geometry: { name: "geometry.v1.bin", bytes: 10, sha256: "b".repeat(64) },
    fuel: { name: "fuel.v1.json", bytes: 10, sha256: "c".repeat(64) },
    sourceEpoch: "geofabrik-lock:20260907",
    timezone: "America/Halifax"
  };
}

test("pack-manifest.v2 requires real positive identities for every artifact", () => {
  assert.equal(validatePackManifestV2(valid()), true);
  assert.throws(() => validatePackManifestV2({ ...valid(), fuel: { name: "fuel.v1.json", bytes: 0, sha256: "0".repeat(64) } }));
  assert.throws(() => validatePackManifestV2({ ...valid(), graph: { name: "graph.v3.bin", bytes: 10, sha256: "a".repeat(64) } }));
  assert.throws(() => validatePackManifestV2({ ...valid(), geometry: { name: "geometry.v1.bin", bytes: 10, sha256: "short" } }));
  assert.throws(() => validatePackManifestV2({ ...valid(), timezone: "" }));
});

test("pack-manifest.v2 requires an identified seam sidecar before a fabric is sealed", () => {
  assert.throws(() => validatePackManifestV2(valid(), { requireSeams: true }), /missing seams identity/);
  const withSeams = {
    ...valid(),
    capabilities: ["legal-topology.v1", "cross-pack-seams.v2"],
    seams: { name: "cross-pack-seams.v2.json", bytes: 10, sha256: "d".repeat(64) }
  };
  assert.equal(validatePackManifestV2(withSeams, { requireSeams: true }), true);
  assert.throws(() => validatePackManifestV2({
    ...withSeams,
    capabilities: ["legal-topology.v1"]
  }), /cross-pack-seams.v2 capability/);
});
