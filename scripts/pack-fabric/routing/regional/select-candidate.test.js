"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { graphPathForRegion, remoteGraphUrl, primaryRegionForPoint } = require("./select");

test("western Nova Scotia stays NS despite NB bbox overlap", () => {
  assert.equal(primaryRegionForPoint(-63.5752, 44.6488), "ns"); // Halifax
  assert.equal(primaryRegionForPoint(-65.7587, 44.6221), "ns"); // Digby
  assert.equal(primaryRegionForPoint(-64.4935, 45.0770), "ns"); // Kentville
  assert.equal(primaryRegionForPoint(-64.213, 45.833), "ns"); // Amherst — NS side of Tantramar
  assert.equal(primaryRegionForPoint(-64.7782, 46.0878), "nb"); // Moncton
  assert.equal(primaryRegionForPoint(-66.0633, 45.2733), "nb"); // Saint John
  assert.equal(primaryRegionForPoint(-64.368, 45.918), "nb"); // Sackville — not stolen by NS bbox
  assert.equal(primaryRegionForPoint(-63.1316, 46.2382), "pe"); // Charlottetown
  assert.equal(primaryRegionForPoint(-54.6103, 48.9544), "nl-island"); // Gander
  assert.equal(primaryRegionForPoint(-52.7126, 47.5615), "nl-island"); // St. John's
  assert.equal(primaryRegionForPoint(-71.2075, 46.8139), "qc-s"); // Québec City
  assert.equal(primaryRegionForPoint(-73.5673, 45.5017), "qc-s"); // Montréal
  assert.equal(primaryRegionForPoint(-60.3256, 53.3013), "nl-lab"); // Happy Valley-Goose Bay
  assert.equal(primaryRegionForPoint(-118.2437, 34.0522), "ca-s"); // Los Angeles
  assert.equal(primaryRegionForPoint(-122.4194, 37.7749), "ca-n"); // San Francisco
  assert.equal(primaryRegionForPoint(-74.365, 49.9167), "qc-n"); // Chibougamau
  assert.equal(primaryRegionForPoint(-75.6972, 45.4215), "on-s"); // Ottawa — not stolen by QC
  assert.equal(primaryRegionForPoint(-63.814, 46.162), "nb"); // Cape Jourimain — not PE
  assert.equal(primaryRegionForPoint(-81.25, 42.98), "on-s"); // London
  assert.equal(primaryRegionForPoint(-89.25, 48.38), "on-n"); // Thunder Bay
});

test("DIRT_V4_REGIONS serves graph.v4.bin only for named regions", () => {
  const previous = process.env.DIRT_V4_REGIONS;
  process.env.DIRT_V4_REGIONS = "ns";
  try {
    assert.match(remoteGraphUrl("ns"), /\/ns\/graph\.v4\.bin$/);
    assert.match(remoteGraphUrl("nb"), /\/nb\/graph\.v3\.bin$/);
  } finally {
    if (previous == null) delete process.env.DIRT_V4_REGIONS;
    else process.env.DIRT_V4_REGIONS = previous;
  }
});

test("a deployment-scoped live candidate overrides only its named region", () => {
  const previous = process.env.R2_REGION_BASE_OVERRIDES;
  process.env.R2_REGION_BASE_OVERRIDES = JSON.stringify({
    ns: "https://packs.example/candidates/ns-release"
  });
  try {
    assert.equal(
      remoteGraphUrl("ns"),
      "https://packs.example/candidates/ns-release/ns/graph.v3.bin"
    );
    assert.match(remoteGraphUrl("bc"), /\/bc\/graph\.v3\.bin$/);
    assert.match(remoteGraphUrl("nb"), /\/nb\/graph\.v3\.bin$/);
    assert.doesNotMatch(remoteGraphUrl("bc"), /ns-release/);
  } finally {
    if (previous == null) delete process.env.R2_REGION_BASE_OVERRIDES;
    else process.env.R2_REGION_BASE_OVERRIDES = previous;
  }
});

test("malformed candidate override fails closed", () => {
  const previous = process.env.R2_REGION_BASE_OVERRIDES;
  process.env.R2_REGION_BASE_OVERRIDES = "not-json";
  try {
    assert.throws(() => remoteGraphUrl("ns"), /Invalid R2_REGION_BASE_OVERRIDES/);
  } finally {
    if (previous == null) delete process.env.R2_REGION_BASE_OVERRIDES;
    else process.env.R2_REGION_BASE_OVERRIDES = previous;
  }
});

test("a verified graph path overrides a stale local regional graph", (t) => {
  const previous = process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES;
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-verified-graph-"));
  const verified = path.join(root, "verified-ns-graph.v2.bin");
  fs.writeFileSync(verified, "verified");
  t.after(() => {
    if (previous == null) delete process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES;
    else process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = previous;
    fs.rmSync(root, { recursive: true, force: true });
  });
  process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({ ns: verified });
  assert.equal(graphPathForRegion("ns"), verified);
});

test("a missing verified graph override fails closed", () => {
  const previous = process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES;
  process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = JSON.stringify({ ns: "/tmp/dirt-does-not-exist/graph.v2.bin" });
  try {
    assert.throws(() => graphPathForRegion("ns"), /Verified graph override is unavailable/);
  } finally {
    if (previous == null) delete process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES;
    else process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES = previous;
  }
});
