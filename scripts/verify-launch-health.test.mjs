import assert from "node:assert/strict";
import test from "node:test";

import {
  parseArgs,
  validatePackManifest,
  validateRiderServicesManifest,
} from "./verify-launch-health.mjs";

function packRegion(id) {
  const hash = "a".repeat(64);
  return {
    id,
    files: [
      { name: "graph.v3.bin", bytes: 10, sha256: hash },
      { name: "geometry.v1.bin", bytes: 20, sha256: hash },
      { name: "fuel.v1.json", bytes: 30, sha256: hash },
    ],
  };
}

function riderRegion(id) {
  return {
    id,
    counts: { campground: 1, lodging: 2, liquor: 3 },
    file: { name: "rider-services.v1.test.json", bytes: 40, sha256: "b".repeat(64) },
  };
}

const ids = Array.from({ length: 63 }, (_, index) => `r${String(index).padStart(2, "0")}`);

test("parseArgs defaults to a fast production check", () => {
  assert.deepEqual(parseArgs([]), {
    environment: "production",
    deep: false,
    json: false,
    strict: false,
    timeoutMs: 15_000,
  });
});

test("parseArgs accepts explicit safe verification options", () => {
  assert.deepEqual(
    parseArgs(["--environment", "development", "--deep", "--strict", "--json", "--timeout-ms", "30000"]),
    {
      environment: "development",
      deep: true,
      json: true,
      strict: true,
      timeoutMs: 30_000,
    },
  );
  assert.throws(() => parseArgs(["--environment", "staging"]), /production or development/);
  assert.throws(() => parseArgs(["--post"]), /unknown argument/);
});

test("pack manifest requires graph, geometry, and fuel in all 63 regions", () => {
  const manifest = {
    schemaVersion: "pack-manifest.v1",
    version: "v1",
    regions: ids.map(packRegion),
  };
  assert.equal(validatePackManifest(manifest).length, 189);
  manifest.regions[4].files = manifest.regions[4].files.filter((file) => file.name !== "fuel.v1.json");
  assert.throws(() => validatePackManifest(manifest), /has no fuel\.v1\.json/);
});

test("Rider Services manifest requires positive counts for every category", () => {
  const manifest = {
    schema: "rider-services-manifest.v1",
    regions: ids.map(riderRegion),
  };
  assert.equal(validateRiderServicesManifest(manifest).length, 63);
  manifest.regions[9].counts.liquor = 0;
  assert.throws(() => validateRiderServicesManifest(manifest), /has no advertised liquor data/);
});
