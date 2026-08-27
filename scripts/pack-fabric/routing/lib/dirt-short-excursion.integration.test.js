"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");

process.env.ROUTING_USE_REGIONAL = "1";
process.env.ROUTING_PACKS_V2 = "1";
process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({
  ns: path.resolve(__dirname, "../../app/data/packs/v1/ns/graph.v3.bin")
});

const { routeRequest } = require("./router");

const TESTER_FROM = { lat: 44.764835880538186, lon: -63.340266835559504 };
const TESTER_TO = { lat: 45.572716358030846, lon: -62.384631424460196 };
const HIGHWAY_7_MICRO_DIVERSION_EDGES = new Set([
  // Little River Drive, Cedar Drive, and Chestnut Drive on the audited pack.
  "osm-60a3b5e496c7",
  "osm-9ca22c5969ee",
  "osm-9f764cd64fb0-s0",
  "osm-9f764cd64fb0-s1",
  "osm-9f764cd64fb0-s2"
]);

test(
  "NS tester route does not collect sub-kilometre Highway 7 dirt teeth",
  { timeout: 30_000 },
  async () => {
    const route = await routeRequest({
      profile: "dirt",
      locations: [TESTER_FROM, TESTER_TO],
      vehicle: "dual-sport-motorcycle",
      accessPolicy: {
        motorizedPermissive: true,
        motorizedUnknown: false
      },
      options: { sessionSeed: 0, backtrackFactor: 4 }
    });

    assert.equal(route.status, "complete");
    const used = new Set((route.segments || []).map((segment) => String(segment.edgeId)));
    for (const edgeId of HIGHWAY_7_MICRO_DIVERSION_EDGES) {
      assert.equal(used.has(edgeId), false, `short diversion survived: ${edgeId}`);
    }
    assert.equal(route.debug.searchMeta.minimumEarnedDirtExcursionMeters, 1_000);
    assert.ok(route.debug.searchMeta.shortDirtPenaltyEdgeCount > 0);
    assert.ok(route.distanceMeters < 275_500, `tester route regressed to ${route.distanceMeters}m`);
  }
);
