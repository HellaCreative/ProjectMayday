"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("crypto");
const { handleRequest, normalizedBounds } = require("../api/poi.js");
const {
  clearCaches,
  loadRiderServices,
  validateManifest
} = require("./packed-rider-services");

function jsonResponse(value, status = 200) {
  const buffer = Buffer.from(JSON.stringify(value));
  return {
    ok: status >= 200 && status < 300,
    status,
    arrayBuffer: async () => buffer
  };
}

function responseRecorder() {
  return {
    headers: {},
    code: null,
    body: null,
    ended: false,
    setHeader(name, value) { this.headers[name] = value; },
    status(code) { this.code = code; return this; },
    json(body) { this.body = body; return this; },
    end() { this.ended = true; return this; }
  };
}

test("normalizes a valid viewport onto a stable cache grid", () => {
  assert.deepEqual(normalizedBounds({
    minLon: -63.641,
    minLat: 44.611,
    maxLon: -63.501,
    maxLat: 44.701
  }), {
    minLon: -63.650000000000006,
    minLat: 44.6,
    maxLon: -63.5,
    maxLat: 44.75
  });
  assert.equal(normalizedBounds({ minLon: -200, minLat: 0, maxLon: 1, maxLat: 1 }), null);
  assert.equal(normalizedBounds({ minLon: -10, minLat: 0, maxLon: 30, maxLat: 1 }), null);
});

test("loads only intersecting DIRT packs and verifies their identity", async () => {
  clearCaches();
  const pack = {
    schema: "rider-services.v1",
    regionId: "ns",
    elements: [
      { id: 1, type: "node", lat: 44.72, lon: -63.38, tags: { tourism: "camp_site" } },
      { id: 2, type: "node", lat: 46, lon: -64, tags: { shop: "alcohol" } }
    ]
  };
  const packBuffer = Buffer.from(JSON.stringify(pack));
  const manifest = {
    schema: "rider-services-manifest.v1",
    generatedAt: "2026-09-05T00:00:00Z",
    regions: [{
      id: "ns",
      bounds: [-66.5, 43.3, -59.5, 47.1],
      file: {
        name: "rider-services.v1.aaaaaaaaaaaa.json",
        bytes: packBuffer.length,
        sha256: crypto.createHash("sha256").update(packBuffer).digest("hex")
      }
    }]
  };
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    return url.endsWith("manifest.json") ? jsonResponse(manifest) : jsonResponse(pack);
  };
  const result = await loadRiderServices(
    { minLon: -63.5, minLat: 44.6, maxLon: -63.2, maxLat: 44.8 },
    { baseURL: "https://dirt.example/rider-services/v1", fetchImpl, now: 100 }
  );
  assert.deepEqual(result.regions, ["ns"]);
  assert.deepEqual(result.elements.map((element) => element.id), [1]);
  assert.equal(calls.length, 2);
});

test("fails closed when a regional object does not match the manifest", async () => {
  clearCaches();
  const manifest = {
    schema: "rider-services-manifest.v1",
    regions: [{
      id: "ns",
      bounds: [-66.5, 43.3, -59.5, 47.1],
      file: { name: "rider-services.v1.aaaaaaaaaaaa.json", bytes: 1, sha256: "a".repeat(64) }
    }]
  };
  const fetchImpl = async (url) => url.endsWith("manifest.json")
    ? jsonResponse(manifest)
    : jsonResponse({ schema: "rider-services.v1", regionId: "ns", elements: [] });
  await assert.rejects(
    loadRiderServices(
      { minLon: -64, minLat: 44, maxLon: -63, maxLat: 45 },
      { baseURL: "https://dirt.example/rider-services/v1", fetchImpl, now: 200 }
    ),
    /identity_mismatch_ns/
  );
});

test("API health identifies packed DIRT data and POST returns compatible elements", async () => {
  const health = responseRecorder();
  await handleRequest({ method: "GET", headers: {} }, health);
  assert.equal(health.code, 200);
  assert.equal(health.body.source, "packed-r2");

  const response = responseRecorder();
  await handleRequest({
    method: "POST",
    headers: { "x-dirt-request-id": "test-request" },
    body: { minLon: -64, minLat: 44, maxLon: -63, maxLat: 45 }
  }, response, {
    loadRiderServices: async () => ({
      schema: "rider-services-response.v1",
      regions: ["ns"],
      elements: [{ id: 7, type: "node", lat: 44.7, lon: -63.3, tags: { shop: "alcohol" } }]
    })
  });
  assert.equal(response.code, 200);
  assert.equal(response.headers["X-Dirt-POI-Source"], "packed-r2");
  assert.equal(response.body.elements[0].id, 7);
});

test("manifest validation rejects duplicate or unverifiable rows", () => {
  const row = {
    id: "ns",
    bounds: [-66.5, 43.3, -59.5, 47.1],
    file: { name: "rider-services.v1.aaaaaaaaaaaa.json", bytes: 10, sha256: "a".repeat(64) }
  };
  assert.throws(
    () => validateManifest({ schema: "rider-services-manifest.v1", regions: [row, row] }),
    /invalid_rider_services_region/
  );
  assert.throws(
    () => validateManifest({
      schema: "rider-services-manifest.v1",
      regions: [{ ...row, bounds: [-63, 45, -64, 44] }]
    }),
    /invalid_rider_services_bounds_ns/
  );
});
