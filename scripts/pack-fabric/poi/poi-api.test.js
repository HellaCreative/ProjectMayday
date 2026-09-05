"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
  normalizedBounds,
  overpassQuery,
  fetchOverpass
} = require("../api/poi.js");

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

test("requests all three non-fuel rider-service categories", () => {
  const query = overpassQuery({ minLon: -64, minLat: 44, maxLon: -63, maxLat: 45 });
  assert.match(query, /hotel\|motel\|hostel\|guest_house\|chalet/);
  assert.match(query, /camp_site\|caravan_site/);
  assert.match(query, /\["shop"="alcohol"\]/);
  assert.doesNotMatch(query, /amenity"="fuel/);
});

test("falls through to the next upstream and validates the payload", async () => {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    if (calls.length === 1) return { ok: false, status: 429, text: async () => "busy" };
    return {
      ok: true,
      status: 200,
      text: async () => JSON.stringify({ elements: [{ id: 7, type: "node" }] })
    };
  };
  const result = await fetchOverpass("query", {
    fetchImpl,
    endpoints: ["https://one.example/api", "https://two.example/api"],
    timeoutMs: 50
  });
  assert.equal(calls.length, 2);
  assert.equal(result.endpoint, "https://two.example/api");
  assert.deepEqual(result.payload.elements, [{ id: 7, type: "node" }]);
});

