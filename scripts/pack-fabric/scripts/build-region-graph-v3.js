#!/usr/bin/env node
"use strict";

/**
 * Stamp the Nova Scotia v3 pack recipe onto any region in geofabrik.js.
 *
 * Same rules as NS: OSM-only membership (track + path, no cycleway, ATV override,
 * ferries), leaves preserved, families at read time, fail-closed dictionaries.
 *
 *   node --max-old-space-size=8192 scripts/pack-fabric/scripts/build-region-graph-v3.js pe
 *
 * Clips the Geofabrik extract to the OSM admin polygon, then encodes.
 * Accepted reference packs ns/nb/pe/nl/qc/on cannot be rebuilt here.
 *
 *   --reuse-extract   skip osmium if roads.geojsonseq already exists
 *
 * Writes gitignored:
 *   routing/data/regions/<id>/graph.v3.bin
 *   routing/data/regions/<id>/geometry.v1.bin
 *   app/data/packs/v1/<id>/graph.v3.bin  (ship-routing source)
 *
 * Does not overwrite graph.v2.bin. After a successful stamp, upload an
 * immutable candidate, add the id to both V3 registries and commit, deploy the
 * recorded candidate override for acceptance, promote those exact bytes, then
 * deploy stable LIVE and run the region-scoped lockstep assertion. See
 * docs/PACK-FACTORY.md for the guarded release sequence.
 */
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const osmRoads = require("../routing/adapters/osm-roads");
const { buildRegionalGraph } = require("../routing/regional/package");
const { encodeFromV1 } = require("../routing/lib/pack-v2");
const { geofabrikSource, geofabrikPbfUrl } = require("../routing/registry/geofabrik");
const { isV3Region } = require("../routing/lib/v3-regions");

const FABRIC = path.join(__dirname, "..");
const DIRT = path.join(FABRIC, "../..");
const OSM_ROADS_ROOT = process.env.OSM_ROADS_ROOT || path.join(FABRIC, "data-raw", "osm-roads");
const PACKS = path.join(FABRIC, "app", "data", "packs", "v1");
const REGIONS = path.join(FABRIC, "routing", "data", "regions");
const SEED_FIXTURES = new Set(["ns"]);
const FROZEN_STAMPS = new Set(["ns", "nb", "pe", "nl", "qc", "on"]);
const MAX_LEAF_ENTRIES = 255;

function roadsSeqPath(regionId) {
  const source = geofabrikSource(regionId);
  return path.join(OSM_ROADS_ROOT, source.slug, "roads.geojsonseq");
}

function extractHint(regionId) {
  return `bash scripts/pack-fabric/scripts/clip-and-extract-osm-roads.sh ${String(regionId || "").toLowerCase()}`;
}

function prepareExtract(regionId, { reuseExtract = false } = {}) {
  const seq = roadsSeqPath(regionId);
  if (reuseExtract && fs.existsSync(seq)) {
    console.warn("reusing existing extract", seq);
    return seq;
  }
  const script = path.join(__dirname, "clip-and-extract-osm-roads.sh");
  const result = spawnSync("bash", [script, regionId], {
    stdio: "inherit",
    env: { ...process.env, OSM_ROADS_ROOT, FABRIC }
  });
  if (result.status !== 0) {
    throw new Error(`${extractHint(regionId)} failed (${result.status})`);
  }
  if (!fs.existsSync(seq)) {
    throw new Error(`clip extract did not write ${seq}`);
  }
  return seq;
}

function uniqueLeafCount(edges, field, sentinel) {
  const names = new Set();
  for (const edge of edges || []) {
    let key = edge[field];
    if (key == null) continue;
    key = String(key).trim().toLowerCase();
    if (!key || key === sentinel) continue;
    names.add(key);
  }
  return names.size + 1;
}

function leafCardinalityReport(edges) {
  return {
    surfaceLeafNames: uniqueLeafCount(edges, "surfaceLeaf", ""),
    roadClassLeafNames: uniqueLeafCount(edges, "roadClassLeaf", "unknown"),
    structureLeafNames: uniqueLeafCount(edges, "structureLeaf", ""),
    accessLeafNames: uniqueLeafCount(edges, "accessLeaf", "")
  };
}

function assertLeafDictionaries(report) {
  for (const [name, count] of Object.entries(report)) {
    if (count > MAX_LEAF_ENTRIES) {
      throw new Error(
        `graph.v3 ${name} has ${count} entries (fail-closed at ${MAX_LEAF_ENTRIES}); widen the index before shipping`
      );
    }
  }
}

function stagePackFiles(regionId, graphPath, geomPath) {
  const destDir = path.join(PACKS, regionId);
  fs.mkdirSync(destDir, { recursive: true });
  fs.copyFileSync(graphPath, path.join(destDir, "graph.v3.bin"));
  fs.copyFileSync(geomPath, path.join(destDir, "geometry.v1.bin"));
  return destDir;
}

function seedFixtures(regionId, graphPath, geomPath) {
  if (!SEED_FIXTURES.has(regionId)) return null;
  const seedDir = path.join(DIRT, "DirtTests", "Fixtures", "DirtLocalPacks", regionId);
  fs.mkdirSync(seedDir, { recursive: true });
  fs.copyFileSync(graphPath, path.join(seedDir, "graph.v3.bin"));
  fs.copyFileSync(geomPath, path.join(seedDir, "geometry.v1.bin"));
  return seedDir;
}

async function buildRegionGraphV3(regionId, { reuseExtract = false } = {}) {
  const source = geofabrikSource(regionId);
  const id = source.id;
  if (FROZEN_STAMPS.has(id)) {
    throw new Error(
      `refusing to stamp accepted reference pack '${id}'; open a deliberate new pack revision before replacing frozen bytes`
    );
  }
  if (!isV3Region(id)) {
    console.warn(
      `'${id}' is not in live v3-regions.json; stamping locally. LIVE still requests graph.v2.bin until both V3 registries are updated and the committed service is deployed.`
    );
  }

  const seq = prepareExtract(id, { reuseExtract });

  const outDir = path.join(REGIONS, id);
  fs.mkdirSync(outDir, { recursive: true });
  const outGraph = path.join(outDir, "graph.v3.bin");
  const outGeom = path.join(outDir, "geometry.v1.bin");
  const v2Graph = path.join(outDir, "graph.v2.bin");
  const v2GeomRollback = path.join(outDir, "geometry.v1.v2-rollback.bin");
  const existingGeom = path.join(outDir, "geometry.v1.bin");

  if (fs.existsSync(existingGeom) && fs.existsSync(v2Graph) && !fs.existsSync(v2GeomRollback)) {
    fs.copyFileSync(existingGeom, v2GeomRollback);
    console.log("preserved v2 geometry →", v2GeomRollback);
  }
  if (!fs.existsSync(v2Graph)) {
    console.warn("warning: graph.v2.bin missing — rollback pair incomplete");
  }

  const pbfUrl = geofabrikPbfUrl(id);
  console.log(`building ${id} intermediate (OSM-only + leaves + ferries from extract)…`);
  const { features, report } = await osmRoads.run({
    inputPath: seq,
    province: id.toUpperCase(),
    sourceUrl: pbfUrl,
    downloadUrl: pbfUrl,
    datasetVersion: `geofabrik:${source.slug}`
  });
  console.log("adapter features:", features.length, "scanned:", report.scannedCount);

  const graph = buildRegionalGraph({
    features,
    regionId: id,
    province: id.toUpperCase(),
    lineage: { phase: "graph-v3-stamp", source: source.slug }
  });

  const dictionaries = leafCardinalityReport(graph.edges);
  assertLeafDictionaries(dictionaries);
  console.log("leaf dictionaries", dictionaries);

  console.log("encoding graph.v3.bin… edges=", graph.edges.length);
  const { graphBuffer, geomBuffer } = encodeFromV1(graph);
  fs.writeFileSync(outGraph, graphBuffer);
  fs.writeFileSync(outGeom, geomBuffer);

  const packDir = stagePackFiles(id, outGraph, outGeom);
  const seedDir = seedFixtures(id, outGraph, outGeom);

  const summary = {
    regionId: id,
    slug: source.slug,
    outGraph,
    outGeom,
    packDir,
    seedDir,
    graphBytes: graphBuffer.length,
    geomBytes: geomBuffer.length,
    edges: graph.edges.length,
    nodes: graph.nodeCount,
    dictionaries,
    v2Kept: fs.existsSync(v2Graph),
    v2GeomRollback: fs.existsSync(v2GeomRollback)
  };
  console.log(JSON.stringify(summary, null, 2));
  return summary;
}

async function main(argv = process.argv.slice(2)) {
  const regionId = String(argv.find((value) => !value.startsWith("-")) || "").toLowerCase();
  if (!regionId) {
    throw new Error(
      "Usage: build-region-graph-v3.js <region-id> [--reuse-extract]\nExample: node --max-old-space-size=8192 scripts/pack-fabric/scripts/build-region-graph-v3.js pe"
    );
  }
  return buildRegionGraphV3(regionId, { reuseExtract: argv.includes("--reuse-extract") });
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err && err.stack ? err.stack : err);
    process.exit(1);
  });
}

module.exports = {
  FROZEN_STAMPS,
  MAX_LEAF_ENTRIES,
  assertLeafDictionaries,
  buildRegionGraphV3,
  extractHint,
  leafCardinalityReport,
  main,
  prepareExtract,
  roadsSeqPath
};
