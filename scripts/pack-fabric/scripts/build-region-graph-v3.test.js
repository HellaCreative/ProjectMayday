"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { OSM_REGION, geofabrikSource } = require("../routing/registry/geofabrik");
const { isV3Region, phoneGraphFileNameForRegion } = require("../routing/lib/v3-regions");
const {
  assertLeafDictionaries,
  applyRegionMetadata,
  extractHint,
  leafCardinalityReport,
  roadsSeqPath
} = require("./build-region-graph-v3");
const { remoteGraphUrl } = require("../routing/regional/select");

test("Geofabrik stamp covers every catalog province and state", () => {
  assert.equal(geofabrikSource("nb").slug, "new-brunswick");
  assert.equal(geofabrikSource("nb").country, "canada");
  assert.equal(geofabrikSource("NS").slug, "nova-scotia");
  assert.equal(geofabrikSource("yt").slug, "yukon");
  assert.equal(geofabrikSource("wa").country, "us");
  assert.equal(geofabrikSource("me").slug, "maine");
  assert.equal(geofabrikSource("ca").slug, "california");
  assert.equal(geofabrikSource("tx").country, "us");
  assert.equal(OSM_REGION.pe.slug, "prince-edward-island");
  const catalog = require("../routing/registry/geofabrik").catalogRegionIds();
  assert.deepEqual([...catalog].sort(), (
    "ab ak al ar az bc ca-n ca-s co ct de fl ga hi ia id il in ks ky la ma mb md me mi mn mo ms mt " +
    "nb nc nd ne nh nj nl-island nl-lab nm ns nt nu nv ny oh ok on-n on-s or pa pe qc-n qc-s ri sc sd sk " +
    "tn tx-ne tx-nw tx-se tx-sw ut va vt wa wi wv wy yt"
  ).split(" ").sort());
  for (const [parent, children] of Object.entries({
    on: ["on-n", "on-s"], qc: ["qc-n", "qc-s"],
    ca: ["ca-n", "ca-s"], nl: ["nl-island", "nl-lab"],
    tx: ["tx-ne", "tx-nw", "tx-se", "tx-sw"]
  })) {
    assert.equal(catalog.includes(parent), false);
    assert.equal(OSM_REGION[parent].legacy, true);
    for (const child of children) assert.equal(OSM_REGION[child].sourceSlug, OSM_REGION[parent].slug);
  }
  assert.equal(OSM_REGION.on.legacy, true);
  assert.equal(OSM_REGION["on-s"].sourceSlug, "ontario");
  assert.equal(OSM_REGION["on-n"].sourceSlug, "ontario");
  assert.throws(() => geofabrikSource("xx"), /no Geofabrik source/);
});

test("v3 region registry drives live graph filename", () => {
  assert.equal(isV3Region("ns"), true);
  assert.equal(isV3Region("nb"), true);
  assert.equal(isV3Region("__legacy_ns__"), true);
  assert.equal(isV3Region("pe"), true);
  assert.equal(isV3Region("nl"), true);
  assert.equal(isV3Region("qc"), true);
  assert.equal(isV3Region("on"), true);
  assert.equal(isV3Region("bc"), true);
  assert.equal(phoneGraphFileNameForRegion("nb"), "graph.v3.bin");
  assert.equal(phoneGraphFileNameForRegion("pe"), "graph.v3.bin");
  assert.equal(phoneGraphFileNameForRegion("on"), "graph.v3.bin");
  assert.equal(phoneGraphFileNameForRegion("bc"), "graph.v3.bin");
});

test("live remote URLs follow the v3 registry", () => {
  assert.match(remoteGraphUrl("nb"), /\/nb\/graph\.v3\.bin$/);
  assert.match(remoteGraphUrl("ns"), /\/ns\/graph\.v3\.bin$/);
  assert.match(remoteGraphUrl("pe"), /\/pe\/graph\.v3\.bin$/);
  assert.match(remoteGraphUrl("nl"), /\/nl\/graph\.v3\.bin$/);
  assert.match(remoteGraphUrl("qc"), /\/qc\/graph\.v3\.bin$/);
  assert.match(remoteGraphUrl("on"), /\/on\/graph\.v3\.bin$/);
  assert.match(remoteGraphUrl("bc"), /\/bc\/graph\.v3\.bin$/);
});

test("builder points at the Geofabrik extract, not an NS-only path", () => {
  assert.match(roadsSeqPath("nb"), /osm-roads\/new-brunswick\/roads\.geojsonseq$/);
  assert.match(extractHint("pe"), /clip-and-extract-osm-roads\.sh pe/);
  assert.match(extractHint("nl"), /clip-and-extract-osm-roads\.sh nl/);
  assert.match(extractHint("on"), /clip-and-extract-osm-roads\.sh on/);
});

test("v3 builder carries authored urban and settlement metadata into the graph", () => {
  const graph = {
    bbox: [-66.5, 43.0, -59.5, 47.5],
    crossPackSeams: null,
    urbanCores: [],
    settlements: []
  };
  applyRegionMetadata(graph, "ns");
  assert.ok(graph.urbanCores.length > 0);
  assert.ok(graph.settlements.some((box) => box.name === "Amherst"));
});

test("builder refuses to stamp accepted V3 reference packs", async () => {
  const { buildRegionGraphV3, FROZEN_STAMPS } = require("./build-region-graph-v3");
  assert.deepEqual([...FROZEN_STAMPS].sort(), ["nb", "nl", "ns", "on", "pe", "qc"]);
  const previous = process.env.DIRT_RESUME_PACK_FACTORY;
  process.env.DIRT_RESUME_PACK_FACTORY = "1";
  try {
    for (const id of FROZEN_STAMPS) {
      await assert.rejects(() => buildRegionGraphV3(id), new RegExp(`accepted reference pack '${id}'`));
    }
  } finally {
    if (previous == null) delete process.env.DIRT_RESUME_PACK_FACTORY;
    else process.env.DIRT_RESUME_PACK_FACTORY = previous;
  }
});

test("canary rebuild is only allowed for frozen ns", async () => {
  const { buildRegionGraphV3 } = require("./build-region-graph-v3");
  const previous = process.env.DIRT_RESUME_PACK_FACTORY;
  process.env.DIRT_RESUME_PACK_FACTORY = "1";
  try {
    await assert.rejects(
      () => buildRegionGraphV3("nb", { canary: true }),
      /canary rebuild is only allowed for ns/
    );
    await assert.rejects(
      () => buildRegionGraphV3("wa", { canary: true }),
      /canary rebuild is only allowed for ns/
    );
  } finally {
    if (previous == null) delete process.env.DIRT_RESUME_PACK_FACTORY;
    else process.env.DIRT_RESUME_PACK_FACTORY = previous;
  }
});

test("pack factory stamp is paused for every region", async () => {
  const { buildRegionGraphV3 } = require("./build-region-graph-v3");
  await assert.rejects(() => buildRegionGraphV3("mt"), /Pack factory is paused/);
  await assert.rejects(() => buildRegionGraphV3("ns", { canary: true }), /Pack factory is paused/);
  await assert.rejects(() => buildRegionGraphV3("nb"), /Pack factory is paused/);
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
