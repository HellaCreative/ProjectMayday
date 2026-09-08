"use strict";

const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "../../../..");
const packRoot = process.env.DIRT_V4_TEST_PACK_ROOT
  ? path.resolve(process.env.DIRT_V4_TEST_PACK_ROOT)
  : path.join(root, "scripts/pack-fabric/app/data/packs/v4/ns");

process.env.ROUTING_USE_REGIONAL = "1";
process.env.ROUTING_PACKS_V2 = "1";
process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({
  ns: path.join(packRoot, "graph.v4.bin")
});

const { routeRequest } = require("./router");

test("Nova Scotia V4 Dirt exhausts its coherent search and keeps the best completed mix", {
  timeout: 30_000
}, async () => {
  const result = await routeRequest({
    profile: "dirt",
    locations: [
      { lat: 44.764830, lon: -63.340265 },
      { lat: 43.622045, lon: -65.801340 }
    ],
    vehicle: "dual-sport-motorcycle",
    accessPolicy: { motorizedPermissive: true, motorizedUnknown: false },
    options: { routeSeed: 0, backtrackFactor: 4 }
  });

  assert.equal(result.status, "complete", result.message || result.error);
  assert.equal(result.debug?.packIdentity?.[0]?.releaseId, "fabric-v4-20260907-01");
  assert.equal(
    result.debug?.packIdentity?.[0]?.graphSha256,
    "2aa73fe085022d7e5e46794befd352b1933605c9a2d2070d23d361def2f3c338"
  );
  assert.equal(result.debug?.diagnostics?.allowUnknown, false);
  assert.equal(result.debug?.fallback, null);
  assert.equal(result.debug?.searchMeta?.timedOut, false);
  assert.equal(result.debug?.searchMeta?.pass2Outcome, "completed");
  assert.equal(result.debug?.searchMeta?.resourceSearchExhaustive, true);
  assert.equal(result.debug?.searchMeta?.resourceSearchEarlyQualityExit, false);
  assert.equal(result.debug?.searchMeta?.highestCompletedKnownDirtPercent, 67);
  assert.equal(result.stats?.dirtPercent, 67);
  assert.ok(result.quality?.knownDirtPercent >= 55,
    `known Dirt regressed to ${result.quality?.knownDirtPercent}%`);
  assert.ok(
    result.distanceMeters <= result.debug.searchMeta.coherentDistanceCapMeters + 1,
    `route ${result.distanceMeters}m exceeds coherent cap ` +
      `${result.debug.searchMeta.coherentDistanceCapMeters}m`
  );
  assert.ok(
    result.debug.searchMeta.coherentDistanceCapMeters <=
      result.debug.searchMeta.shortestLegalRoadMeters * 1.5 + 1,
    "the coherent-distance guard exceeded 1.5x the shortest legal road path"
  );
  const edgeIds = result.segments.map((segment) => String(segment.edgeId));
  assert.equal(new Set(edgeIds).size, edgeIds.length,
    "the rider-visible route repeats an edge");
  assert.ok(result.debug.searchMeta.prunedLoopMeters >= 0,
    "loop pruning diagnostics must be present");
  assert.equal(result.backtrackMeters, 0);
});
