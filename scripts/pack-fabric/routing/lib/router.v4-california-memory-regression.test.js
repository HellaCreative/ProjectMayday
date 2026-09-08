"use strict";

const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "../../../..");
const packRoot = process.env.DIRT_V4_TEST_PACK_ROOT
  ? path.resolve(process.env.DIRT_V4_TEST_PACK_ROOT)
  : path.join(root, "scripts/pack-fabric/app/data/packs/v4/ca");

process.env.ROUTING_USE_REGIONAL = "1";
process.env.ROUTING_PACKS_V2 = "1";
process.env.VERCEL = "1";
process.env.VERCEL_ENV = "preview";
process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({
  ca: path.join(packRoot, "graph.v4.bin")
});

const { routeRequest } = require("./router");

test("California V4 Balanced route completes with sparse working memory", {
  timeout: 30_000
}, async () => {
  const result = await routeRequest({
    profile: "balanced",
    locations: [
      { lat: 38.5816, lon: -121.4944 },
      { lat: 38.6857, lon: -121.3722 }
    ],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: { sessionSeed: 0 }
  });

  assert.equal(result.status, "complete", result.message || result.error);
  assert.equal(result.debug?.packIdentity?.[0]?.releaseId, "fabric-v4-20260907-01");
  assert.equal(
    result.debug?.packIdentity?.[0]?.graphSha256,
    "2f7e1ef239a29905adafae71e0ac4fff19e7b01644a12006f9f5cb5d0b241a4a"
  );
  assert.equal(result.debug?.diagnostics?.allowUnknown, false);
  assert.equal(result.debug?.searchMeta?.sparseLabelState, true);
  assert.ok(Number(result.debug?.searchMeta?.labelPages) > 0);
  assert.ok(Number(result.distanceMeters) > 0);

  // Vercel's route function is a 2 GiB worker. Leave headroom for the handler
  // and response serialization instead of merely proving that a desktop can
  // finish with an effectively unbounded heap.
  const rssMiB = process.memoryUsage().rss / 1_048_576;
  assert.ok(rssMiB < 1_900, `California route RSS ${rssMiB.toFixed(0)} MiB`);
});
