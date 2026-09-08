"use strict";

const assert = require("node:assert/strict");
const crypto = require("crypto");
const test = require("node:test");
const { loadRegionFuel, loadFuelForLocations, clearFuelCache } = require("./fuel-data");

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


test("single-point fuel uses admin ownership in overlapping state boxes and preserves NS02", async (t) => {
  clearFuelCache();
  const previousFetch = global.fetch;
  const previousOverrides = process.env.R2_REGION_BASE_OVERRIDES;
  process.env.R2_REGION_BASE_OVERRIDES = JSON.stringify({
    ma: "https://packs.example/candidates/fabric-v4-20260908-03",
    ns: "https://packs.example/candidates/fabric-v4-20260908-02"
  });
  const urls = [];
  global.fetch = async (url) => {
    urls.push(url);
    return { ok: true, arrayBuffer: async () => Buffer.from('{"stations":[{"id":"pump"}]}') };
  };
  t.after(() => {
    clearFuelCache();
    global.fetch = previousFetch;
    if (previousOverrides == null) delete process.env.R2_REGION_BASE_OVERRIDES;
    else process.env.R2_REGION_BASE_OVERRIDES = previousOverrides;
  });
  const cases = [
    [{ lon: -72.66903969731547, lat: 42.42887651518565 }, "ma"],
    [{ lng: -72.66903969731547, lat: 42.42887651518565 }, "ma"],
    [{ lon: -63.34025875229308, lat: 44.76483570134842 }, "ns"],
    [{ lon: -73.75, lat: 42.65 }, "ny"],
    [{ lon: -72.58, lat: 44.26 }, "vt"],
    [{ lon: -71.54, lat: 43.21 }, "nh"]
  ];
  for (const [location, expected] of cases) {
    const result = await loadFuelForLocations([location]);
    assert.equal(result.ok, true);
    assert.deepEqual(result.regionIds, [expected]);
    assert.equal(result.stations.length, 1);
    assert.equal(location.resolvedRegionId, undefined, "input is not mutated");
    if (expected === "ns") assert.equal(result.packIdentity[0].releaseId, "fabric-v4-20260908-02");
  }
  assert.ok(urls.some(url => url.endsWith("/ma/fuel.v1.json")));
  assert.ok(urls.every(url => url.endsWith("/fuel.v1.json")), "no road graph downloads");
});
