"use strict";

const assert = require("node:assert/strict");
const crypto = require("crypto");
const test = require("node:test");
const { loadRegionFuel, clearFuelCache } = require("./fuel-data");

test("packed fuel reports the exact candidate sidecar identity", async (t) => {
  clearFuelCache();
  const previousFetch = global.fetch;
  const previousOverrides = process.env.R2_REGION_BASE_OVERRIDES;
  const bytes = Buffer.from(JSON.stringify({ stations: [{ id: "pump-1" }] }));
  process.env.R2_REGION_BASE_OVERRIDES = JSON.stringify({
    ns: "https://packs.example/candidates/ns-osm-test-01"
  });
  global.fetch = async (url) => ({
    ok: true,
    status: 200,
    arrayBuffer: async () => bytes,
    url
  });
  t.after(() => {
    clearFuelCache();
    global.fetch = previousFetch;
    if (previousOverrides == null) delete process.env.R2_REGION_BASE_OVERRIDES;
    else process.env.R2_REGION_BASE_OVERRIDES = previousOverrides;
  });

  const result = await loadRegionFuel("ns");
  assert.equal(result.stations.length, 1);
  assert.deepEqual(result.packIdentity, {
    regionId: "ns",
    releaseId: "ns-osm-test-01",
    fuelSource: "https://packs.example/candidates/ns-osm-test-01/ns/fuel.v1.json",
    fuelBytes: bytes.length,
    fuelSha256: crypto.createHash("sha256").update(bytes).digest("hex")
  });
});

test("a warm planning operation reuses the packed fuel sidecar", async (t) => {
  clearFuelCache();
  const previousFetch = global.fetch;
  const previousOverrides = process.env.R2_REGION_BASE_OVERRIDES;
  const bytes = Buffer.from(JSON.stringify({ stations: [{ id: "pump-warm" }] }));
  process.env.R2_REGION_BASE_OVERRIDES = JSON.stringify({
    on: "https://packs.example/candidates/on-osm-test-01"
  });
  let fetches = 0;
  global.fetch = async () => {
    fetches += 1;
    return {
      ok: true,
      status: 200,
      arrayBuffer: async () => bytes
    };
  };
  t.after(() => {
    clearFuelCache();
    global.fetch = previousFetch;
    if (previousOverrides == null) delete process.env.R2_REGION_BASE_OVERRIDES;
    else process.env.R2_REGION_BASE_OVERRIDES = previousOverrides;
  });

  const [first, second] = await Promise.all([
    loadRegionFuel("on"),
    loadRegionFuel("on")
  ]);

  assert.equal(fetches, 1);
  assert.equal(first.stations[0].id, "pump-warm");
  assert.equal(second.stations[0].id, "pump-warm");
  assert.equal(second.loadDiagnostics.cacheHit, true);
});
