"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { OSM_REGION } = require("../routing/registry/geofabrik");
const { buildManifest } = require("./publish-rider-services");
const { appendFuel } = require("./publish-missing-fuel");

test("Rider Services manifest requires every registered region", () => {
  const rows = Object.keys(OSM_REGION).map((id) => ({
    id,
    bounds: [-1, -1, 1, 1],
    counts: { campground: 1, lodging: 1, liquor: 1 },
    sourceUpdatedAt: "2026-09-05T00:00:00Z",
    file: { name: `rider-services.v1.${id.padEnd(12, "a")}.json`, bytes: 10, sha256: "a".repeat(64) },
    filePath: `/tmp/${id}`
  }));
  const manifest = buildManifest(rows, "2026-09-05T01:00:00Z");
  assert.equal(manifest.regions.length, 63);
  assert.equal(manifest.regions[0].filePath, undefined);
  assert.throws(() => buildManifest(rows.slice(1), "x"), /requires all 63/);
});

test("fuel merge appends only missing sidecars and preserves graph identity", () => {
  const catalog = {
    generatedAt: "old",
    marker: "preserve",
    regions: [
      { id: "ns", files: [{ name: "graph.v3.bin", bytes: 20, sha256: "g" }] },
      { id: "nb", files: [
        { name: "graph.v3.bin", bytes: 30, sha256: "h" },
        { name: "fuel.v1.json", bytes: 5, sha256: "i" }
      ] }
    ]
  };
  const next = appendFuel(catalog, [{
    id: "ns", file: { name: "fuel.v1.json", bytes: 9, sha256: "f" }
  }], "new");
  assert.equal(next.marker, "preserve");
  assert.deepEqual(next.regions[0].files[0], catalog.regions[0].files[0]);
  assert.equal(next.regions[0].files[1].name, "fuel.v1.json");
  assert.deepEqual(next.regions[1], catalog.regions[1]);
  assert.throws(
    () => appendFuel(catalog, [{ id: "nb", file: { name: "fuel.v1.json" } }], "new"),
    /already advertises fuel/
  );
});

test("DEV functions cannot bundle generated pack bytes or local upload state", () => {
  const root = path.resolve(__dirname, "..");
  const config = JSON.parse(fs.readFileSync(path.join(root, "vercel.json"), "utf8"));
  for (const name of ["api/route.js", "api/fuel.js", "api/fuel-chain.js"]) {
    const excluded = String(config.functions[name].excludeFiles || "");
    assert.match(excluded, /app\/data/);
    assert.match(excluded, /routing\/data/);
    assert.match(excluded, /routing\/candidates/);
  }

  const ignored = fs.readFileSync(path.join(root, ".vercelignore"), "utf8");
  assert.match(ignored, /^\.wrangler$/m);
  assert.match(ignored, /^app\/data\/rider-services\/\*\*$/m);
  assert.match(ignored, /^routing\/candidates\/\*\*$/m);
});
