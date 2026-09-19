#!/usr/bin/env node
"use strict";

/**
 * Stamp one V4 legal-topology pack from a locked continent source epoch.
 *
 *   node --max-old-space-size=16384 scripts/pack-fabric/scripts/build-region-graph-v4.js ns
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const { parseOplFile } = require("../routing/lib/legal-topology/opl");
const { buildGraphFromOsm, countsFromGraph } = require("../routing/lib/legal-topology/osm-graph");
const { encodeFromOsmGraph, sha256 } = require("../routing/lib/pack-v4");
const { buildPackManifestV2 } = require("../routing/lib/pack-manifest-v2");
const { geofabrikSource } = require("../routing/registry/geofabrik");
const { regionTimezone } = require("../routing/registry/timezones");
const { build: buildUrban } = require("./pack-region-urban");

const FABRIC = path.join(__dirname, "..");
const DIRT = path.join(FABRIC, "../..");

function shaFile(file) {
  return sha256(fs.readFileSync(file));
}

function loadSourceLock(regionId) {
  const lockPath = process.env.DIRT_V4_SOURCE_LOCK;
  if (!lockPath) {
    if (process.env.DIRT_V4_ALLOW_UNLOCKED === "1") return null;
    throw new Error("DIRT_V4_SOURCE_LOCK is required; V4 packs cannot use independent latest downloads");
  }
  const lock = JSON.parse(fs.readFileSync(path.resolve(lockPath), "utf8"));
  if (lock.schema !== "dirt-osm-source-lock.v1" || !lock.fabricEpoch) {
    throw new Error("invalid V4 source lock");
  }
  const region = lock.regions && lock.regions[regionId];
  if (!region) throw new Error(`source lock missing ${regionId}`);
  return { lock, region, path: path.resolve(lockPath) };
}

function provenanceMatches(provenance, expected) {
  return provenance && expected &&
    provenance.sourceSha256 === expected.sourceSha256 &&
    provenance.sourceBytes === expected.sourceBytes &&
    provenance.osmTimestamp === expected.osmTimestamp;
}

async function main() {
  const regionId = String(process.argv[2] || "").toLowerCase();
  const source = geofabrikSource(regionId);
  const timezone = regionTimezone(regionId);
  const sourceLock = loadSourceLock(regionId);
  const legalRoot = process.env.OSM_LEGAL_ROOT
    ? path.resolve(process.env.OSM_LEGAL_ROOT)
    : path.join(FABRIC, "data-raw", "osm-legal");
  const legalDir = path.join(legalRoot, source.slug);
  const provenancePath = path.join(legalDir, "provenance.v1.json");
  const existingProvenance = fs.existsSync(provenancePath)
    ? JSON.parse(fs.readFileSync(provenancePath, "utf8"))
    : null;
  const extractDone = fs.existsSync(path.join(legalDir, "legal-topology.opl")) &&
    (!sourceLock || provenanceMatches(existingProvenance, sourceLock.region));
  if (!extractDone) {
    const extract = spawnSync("bash", [path.join(__dirname, "extract-region-osm.sh"), regionId], {
      stdio: "inherit",
      env: { ...process.env, DIRT_V4_SOURCE_LOCK: sourceLock ? sourceLock.path : "" }
    });
    if (extract.status !== 0) throw new Error("extract-region-osm.sh failed");
  } else {
    console.warn("reusing source-locked lossless extract", legalDir);
  }

  const oplPath = path.join(legalDir, "legal-topology.opl");
  const provenance = JSON.parse(fs.readFileSync(path.join(legalDir, "provenance.v1.json"), "utf8"));
  if (sourceLock && !provenanceMatches(provenance, sourceLock.region)) {
    throw new Error(`legal extract for ${regionId} does not match the source lock`);
  }
  provenance.factoryCommit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: DIRT, encoding: "utf8" }).stdout.trim();
  provenance.sourceEpoch = sourceLock ? sourceLock.lock.fabricEpoch : `geofabrik:${provenance.osmTimestamp}`;
  provenance.sourceLock = sourceLock ? path.basename(sourceLock.path) : null;
  provenance.regionId = regionId;
  provenance.timezone = timezone;
  const urbanPath = path.join(legalDir, "urban-cores.v1.json");
  const urbanPbf = path.join(legalDir, "places.osm.pbf");
  const urbanSequence = path.join(legalDir, "places.geojsonseq");
  for (const args of [
    ["tags-filter", path.join(legalDir, "admin-halo.osm.pbf"), "nwr/place=city,town", "-o", urbanPbf, "--overwrite"],
    ["export", urbanPbf, "--add-unique-id=type_id", "-a", "type,id,timestamp", "-f", "geojsonseq", "-o", urbanSequence, "--overwrite"]
  ]) {
    if (spawnSync("osmium", args, { stdio: "inherit" }).status !== 0) throw new Error(`${regionId}: urban extraction failed`);
  }
  await buildUrban(regionId, source.slug, { input: urbanSequence, output: urbanPath,
    sourceIdentity: { sha256: provenance.sourceSha256, osmTimestamp: provenance.osmTimestamp } });
  const urban = JSON.parse(fs.readFileSync(urbanPath, "utf8"));
  provenance.urbanCores = urban.cores;
  provenance.settlements = urban.settlements;
  provenance.urbanSourceIdentity = urban.sourceIdentity;

  const osm = await parseOplFile(oplPath, { packedNodes: true });
  console.warn(
    "parsed OSM",
    osm.nodeStore ? osm.nodeStore.count : osm.nodes.length,
    "nodes",
    osm.ways.length,
    "ways",
    osm.relations.length,
    "relations"
  );
  const graph = buildGraphFromOsm(osm, { timezone });
  osm.nodes.length = 0;
  osm.ways.length = 0;
  osm.relations.length = 0;
  if (global.gc) global.gc();
  console.warn("graph", graph.nodes.length, "nodes", graph.edges.length, "edges", graph.restrictions.length, "restrictions");
  if (graph.unprovenStitches !== 0) throw new Error("unproven stitches are not zero");
  const encoded = encodeFromOsmGraph(graph, provenance);
  const packRoot = process.env.DIRT_V4_PACK_ROOT
    ? path.resolve(process.env.DIRT_V4_PACK_ROOT)
    : path.join(FABRIC, "app", "data", "packs", "v4");
  const outDir = path.join(packRoot, regionId);
  fs.mkdirSync(outDir, { recursive: true });
  const graphPath = path.join(outDir, "graph.v4.bin");
  const geomPath = path.join(outDir, "geometry.v1.bin");
  fs.writeFileSync(graphPath, encoded.graphBuffer);
  fs.writeFileSync(geomPath, encoded.geomBuffer);

  const fuelSrc = process.env.DIRT_V4_FUEL_PATH
    ? path.resolve(process.env.DIRT_V4_FUEL_PATH)
    : path.join(outDir, "fuel.v1.json");
  const fuelDest = path.join(outDir, "fuel.v1.json");
  if (!fs.existsSync(fuelSrc) || fs.statSync(fuelSrc).size <= 0) {
    throw new Error(`missing source-locked fuel sidecar for ${regionId}`);
  }
  if (fuelSrc !== fuelDest) fs.copyFileSync(fuelSrc, fuelDest);

  const counts = countsFromGraph(graph);
  const releaseId = process.env.DIRT_V4_RELEASE_ID;
  if (!releaseId || !/^fabric-v4-[0-9]{8}-[0-9]{2}$/.test(releaseId)) {
    throw new Error("DIRT_V4_RELEASE_ID must be fabric-v4-YYYYMMDD-NN");
  }
  const manifest = buildPackManifestV2({
    fabricReleaseId: releaseId,
    regionId,
    graph: { name: "graph.v4.bin", bytes: encoded.graphBuffer.length, sha256: sha256(encoded.graphBuffer) },
    geometry: { name: "geometry.v1.bin", bytes: encoded.geomBuffer.length, sha256: sha256(encoded.geomBuffer) },
    fuel: { name: "fuel.v1.json", bytes: fs.statSync(fuelDest).size, sha256: shaFile(fuelDest) },
    sourceEpoch: provenance.sourceEpoch,
    timezone
  });
  fs.writeFileSync(path.join(outDir, "pack-manifest.v2.json"), JSON.stringify(manifest, null, 2) + "\n");
  const report = {
    counts,
    rejected: graph.rejected,
    provenance,
    manifest,
    unprovenStitches: 0
  };
  fs.writeFileSync(path.join(outDir, "legal-topology-report.json"), JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify({ manifest, counts, rejected: counts.rejectedBy }, null, 2));
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  });
}

module.exports = { main };
