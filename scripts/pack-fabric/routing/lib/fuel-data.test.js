"use strict";

const assert = require("node:assert/strict");
const crypto = require("crypto");
const test = require("node:test");
const { loadRegionFuel } = require("./fuel-data");

test("packed fuel reports the exact candidate sidecar identity", async (t) => {
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
