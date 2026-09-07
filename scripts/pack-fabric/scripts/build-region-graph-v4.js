#!/usr/bin/env node
"use strict";

/**
 * Stamp one V4 legal-topology pack. NS only until the owner accepts.
 *
 *   node --max-old-space-size=16384 scripts/pack-fabric/scripts/build-region-graph-v4.js ns
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const { parseOpl } = require("../routing/lib/legal-topology/opl");
const { buildGraphFromOsm, countsFromGraph } = require("../routing/lib/legal-topology/osm-graph");
const { encodeFromOsmGraph, sha256 } = require("../routing/lib/pack-v4");
const { buildPackManifestV2 } = require("../routing/lib/pack-manifest-v2");

const FABRIC = path.join(__dirname, "..");
const DIRT = path.join(FABRIC, "../..");

function shaFile(file) {
  return sha256(fs.readFileSync(file));
}

function main() {
  const regionId = String(process.argv[2] || "").toLowerCase();
  if (regionId !== "ns") {
    throw new Error("V4 factory builds Nova Scotia only until owner acceptance");
  }
  const extractDone = fs.existsSync(path.join(FABRIC, "data-raw", "osm-legal", "nova-scotia", "legal-topology.opl"));
  if (!extractDone) {
    const extract = spawnSync("bash", [path.join(__dirname, "extract-region-osm.sh"), regionId], {
      stdio: "inherit",
      env: process.env
    });
    if (extract.status !== 0) throw new Error("extract-region-osm.sh failed");
  } else {
    console.warn("reusing lossless extract", path.join(FABRIC, "data-raw", "osm-legal", "nova-scotia"));
  }

  const legalDir = path.join(FABRIC, "data-raw", "osm-legal", "nova-scotia");
  const opl = fs.readFileSync(path.join(legalDir, "legal-topology.opl"), "utf8");
  const provenance = JSON.parse(fs.readFileSync(path.join(legalDir, "provenance.v1.json"), "utf8"));
  provenance.factoryCommit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: DIRT, encoding: "utf8" }).stdout.trim();
  provenance.sourceEpoch = `geofabrik:${provenance.osmTimestamp}`;
  provenance.regionId = regionId;
  provenance.timezone = "America/Halifax";
  const urbanPath = path.join(FABRIC, "routing", "data", "regions", regionId, "urban-cores.v1.json");
  if (fs.existsSync(urbanPath)) {
    const sidecar = JSON.parse(fs.readFileSync(urbanPath, "utf8"));
    provenance.urbanCores = sidecar.cores || sidecar.urbanCores || null;
    provenance.settlements = sidecar.settlements || null;
  }

  const osm = parseOpl(opl);
  console.warn("parsed OSM", osm.nodes.length, "nodes", osm.ways.length, "ways", osm.relations.length, "relations");
  const graph = buildGraphFromOsm(osm, { timezone: "America/Halifax" });
  console.warn("graph", graph.nodes.length, "nodes", graph.edges.length, "edges", graph.restrictions.length, "restrictions");
  if (graph.unprovenStitches !== 0) throw new Error("unproven stitches are not zero");
  const encoded = encodeFromOsmGraph(graph, provenance);
  const outDir = path.join(FABRIC, "app", "data", "packs", "v4", regionId);
  fs.mkdirSync(outDir, { recursive: true });
  const graphPath = path.join(outDir, "graph.v4.bin");
  const geomPath = path.join(outDir, "geometry.v1.bin");
  fs.writeFileSync(graphPath, encoded.graphBuffer);
  fs.writeFileSync(geomPath, encoded.geomBuffer);

  const fuelSrc = path.join(FABRIC, "app", "data", "packs", "v1", regionId, "fuel.v1.json");
  const fuelDest = path.join(outDir, "fuel.v1.json");
  if (fs.existsSync(fuelSrc)) fs.copyFileSync(fuelSrc, fuelDest);

  const counts = countsFromGraph(graph);
  const manifest = buildPackManifestV2({
    fabricReleaseId: process.env.DIRT_V4_RELEASE_ID || `ns-v4-legal-topology-${new Date().toISOString().slice(0, 10).replace(/-/g, "")}-01`,
    regionId,
    graph: { name: "graph.v4.bin", bytes: encoded.graphBuffer.length, sha256: sha256(encoded.graphBuffer) },
    geometry: { name: "geometry.v1.bin", bytes: encoded.geomBuffer.length, sha256: sha256(encoded.geomBuffer) },
    fuel: fs.existsSync(fuelDest)
      ? { name: "fuel.v1.json", bytes: fs.statSync(fuelDest).size, sha256: shaFile(fuelDest) }
      : { name: "fuel.v1.json", bytes: 0, sha256: "0".repeat(64) },
    sourceEpoch: provenance.sourceEpoch,
    timezone: "America/Halifax"
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
  try {
    main();
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = { main };
