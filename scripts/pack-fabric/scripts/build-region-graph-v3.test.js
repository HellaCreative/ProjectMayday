"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { OSM_REGION, geofabrikSource } = require("../routing/registry/geofabrik");
const { isV3Region, phoneGraphFileNameForRegion } = require("../routing/lib/v3-regions");
const {
  assertLeafDictionaries,
  extractHint,
  leafCardinalityReport,
  roadsSeqPath
} = require("./build-region-graph-v3");
const { remoteGraphUrl } = require("../routing/regional/select");

test("Geofabrik stamp covers Canada plus Washington", () => {
  assert.equal(geofabrikSource("nb").slug, "new-brunswick");
  assert.equal(geofabrikSource("nb").country, "canada");
  assert.equal(geofabrikSource("NS").slug, "nova-scotia");
  assert.equal(geofabrikSource("yt").slug, "yukon");
  assert.equal(geofabrikSource("wa").country, "us");
  assert.equal(OSM_REGION.pe.slug, "prince-edward-island");
  assert.throws(() => geofabrikSource("xx"), /no Geofabrik source/);
});

test("v3 region registry drives live graph filename", () => {
  assert.equal(isV3Region("ns"), true);
  assert.equal(isV3Region("nb"), true);
  assert.equal(isV3Region("__legacy_ns__"), true);
  assert.equal(isV3Region("pe"), false);
  assert.equal(isV3Region("bc"), false);
  assert.equal(phoneGraphFileNameForRegion("nb"), "graph.v3.bin");
  assert.equal(phoneGraphFileNameForRegion("bc"), "graph.v2.bin");
});

test("live remote URLs follow the v3 registry", () => {
  assert.match(remoteGraphUrl("nb"), /\/nb\/graph\.v3\.bin$/);
  assert.match(remoteGraphUrl("ns"), /\/ns\/graph\.v3\.bin$/);
  assert.match(remoteGraphUrl("pe"), /\/pe\/graph\.v2\.bin$/);
});

test("builder points at the Geofabrik extract, not an NS-only path", () => {
  assert.match(roadsSeqPath("nb"), /osm-roads\/new-brunswick\/roads\.geojsonseq$/);
  assert.match(extractHint("nb"), /extract-osm-roads\.sh new-brunswick canada/);
  assert.match(extractHint("wa"), /extract-osm-roads\.sh washington us/);
});

test("leaf dictionaries fail closed before encode", () => {
  const report = leafCardinalityReport([
    { surfaceLeaf: "asphalt", roadClassLeaf: "track", structureLeaf: "", accessLeaf: "yes" },
    { surfaceLeaf: "gravel", roadClassLeaf: "path", structureLeaf: "bridge", accessLeaf: "" }
  ]);
  assert.equal(report.surfaceLeafNames, 3);
  assert.equal(report.roadClassLeafNames, 3);
  assert.equal(report.structureLeafNames, 2);
  assert.doesNotThrow(() => assertLeafDictionaries(report));
  assert.throws(
    () => assertLeafDictionaries({ surfaceLeafNames: 256 }),
    /fail-closed/
  );
});
