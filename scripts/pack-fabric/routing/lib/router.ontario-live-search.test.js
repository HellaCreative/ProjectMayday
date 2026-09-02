"use strict";

const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const ON_GRAPH = path.join(
  __dirname,
  "..",
  "data",
  "regions",
  "on",
  "graph.v3.bin"
);

test(
  "long live Ontario Balanced route completes instead of exhausting an NS-scale deadline",
  { skip: !fs.existsSync(ON_GRAPH), timeout: 120_000 },
  async (t) => {
    const oldVercel = process.env.VERCEL;
    const oldChainCache = process.env.ROUTING_CHAIN_CACHE;
    t.after(() => {
      if (oldVercel == null) delete process.env.VERCEL;
      else process.env.VERCEL = oldVercel;
      if (oldChainCache == null) delete process.env.ROUTING_CHAIN_CACHE;
      else process.env.ROUTING_CHAIN_CACHE = oldChainCache;
    });
    process.env.VERCEL = "1";
    process.env.ROUTING_CHAIN_CACHE = "0";
    const { routeRequest } = require("./router");

    const result = await routeRequest({
      locations: [
        { lat: 45.16042827226568, lon: -76.07416570548115 },
        { lat: 49.267740201600496, lon: -88.12280920479155 }
      ],
      profile: "balanced",
      accessPolicy: {
        motorizedPermissive: true,
        motorizedUnknown: false
      },
      options: { sessionSeed: 0 }
    });

    assert.equal(result.status, "complete", result.message);
    assert.ok(result.distanceMeters > 1_200_000 && result.distanceMeters < 1_350_000);
    const meta = result.debug && result.debug.searchMeta;
    assert.equal(meta && meta.directReference && meta.directReference.algorithm, "astar-distance");
    assert.ok(meta && meta.searchBudgetMs >= 40_000);
    assert.equal(
      result.debug.diagnostics.searchAttempts[0].corridorMeters,
      80_000
    );
  }
);

test(
  "short live Ontario routes complete for every rider profile",
  { skip: !fs.existsSync(ON_GRAPH), timeout: 120_000 },
  async (t) => {
    const oldVercel = process.env.VERCEL;
    const oldChainCache = process.env.ROUTING_CHAIN_CACHE;
    t.after(() => {
      if (oldVercel == null) delete process.env.VERCEL;
      else process.env.VERCEL = oldVercel;
      if (oldChainCache == null) delete process.env.ROUTING_CHAIN_CACHE;
      else process.env.ROUTING_CHAIN_CACHE = oldChainCache;
    });
    process.env.VERCEL = "1";
    process.env.ROUTING_CHAIN_CACHE = "0";
    const { routeRequest } = require("./router");
    const locations = [
      { lat: 43.6532, lon: -79.3832 },
      { lat: 44.1, lon: -79.75 }
    ];

    for (const profile of ["dirt", "balanced", "cleanest"]) {
      const result = await routeRequest({
        locations,
        profile,
        accessPolicy: {
          motorizedPermissive: true,
          motorizedUnknown: false
        },
        options: { sessionSeed: 0 }
      });

      assert.equal(result.status, "complete", `${profile}: ${result.message}`);
      assert.ok(
        result.distanceMeters > 60_000 && result.distanceMeters < 90_000,
        `${profile}: unexpected ${result.distanceMeters} m route`
      );
    }
  }
);

test("search-limit copy identifies the requested profile", () => {
  const { routeSearchLimitMessage } = require("./router");
  assert.match(routeSearchLimitMessage("balanced"), /^Balanced search/);
  assert.match(routeSearchLimitMessage("dirt"), /^Dirt search/);
  assert.match(routeSearchLimitMessage("cleanest"), /^Clean search/);
});
