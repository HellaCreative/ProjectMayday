#!/usr/bin/env node
"use strict";

/**
 * Build the tiny seam index bundled with the live routing functions.
 *
 * Full graph binaries remain on R2. Cross-region planning must not download
 * those binaries merely to rediscover a seam already proven at pack time, so
 * this copies only the authored seam anchors and urban exclusion boxes into
 * routing/schema/cross-pack-topology.v1.json.
 */
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");
const OUTPUT = path.join(ROOT, "routing", "schema", "cross-pack-topology.v1.json");

function readJSON(file, fallback) {
  if (!fs.existsSync(file)) return fallback;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function syncCrossPackTopology() {
  const regions = {};
  if (!fs.existsSync(REGIONS)) return null;
  for (const entry of fs.readdirSync(REGIONS, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const id = entry.name.toLowerCase();
    const dir = path.join(REGIONS, entry.name);
    const seams = readJSON(path.join(dir, "cross-pack-seams.v1.json"), null);
    if (!seams || !seams.neighbors || !Object.keys(seams.neighbors).length) continue;
    const urban = readJSON(path.join(dir, "urban-cores.v1.json"), { cores: [] });
    regions[id] = {
      neighbors: seams.neighbors,
      urbanCores: Array.isArray(urban.cores) ? urban.cores : []
    };
  }
  const output = {
    schemaVersion: "cross-pack-topology.v1",
    generatedAt: new Date().toISOString(),
    regions
  };
  fs.writeFileSync(OUTPUT, JSON.stringify(output, null, 2) + "\n");
  return { output: OUTPUT, regionCount: Object.keys(regions).length };
}

if (require.main === module) {
  const result = syncCrossPackTopology();
  if (!result) {
    console.error("No regional pack data found.");
    process.exit(1);
  }
  console.log(JSON.stringify(result, null, 2));
}

module.exports = { syncCrossPackTopology };
