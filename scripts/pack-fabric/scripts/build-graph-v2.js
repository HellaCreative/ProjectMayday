#!/usr/bin/env node
"use strict";

/**
 * Convert graph.v1.json.gz (or longhaul.v1.json.gz) to binary packs.
 * Phase C+: default output is LOCAL graph.v3.candidate.bin (does not overwrite shipped v2).
 *
 * Usage:
 *   node scripts/build-graph-v2.js [path-to-v1.json.gz ...]
 *   node scripts/build-graph-v2.js --ns
 *   node scripts/build-graph-v2.js --longhaul-corridor
 *   node scripts/build-graph-v2.js --ns --candidate-out /tmp/ns-v3
 */
const fs = require("fs");
const path = require("path");
const { convertV1FileToV2 } = require("../routing/lib/pack-v2");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");

function listLonghaulCorridor() {
  return ["ns", "nb", "qc", "on", "mb", "sk", "ab", "bc"]
    .map((id) => path.join(REGIONS, id, "longhaul.v1.json.gz"))
    .filter((p) => fs.existsSync(p));
}

function main() {
  const args = process.argv.slice(2);
  let files = [];
  const candidateOutAt = args.indexOf("--candidate-out");
  const candidateOutDir = candidateOutAt >= 0 ? args[candidateOutAt + 1] : null;
  if (args.includes("--ns")) {
    const regional = path.join(REGIONS, "ns", "graph.v1.json.gz");
    const legacy = path.join(ROOT, "routing", "data", "ns-graph.v1.json.gz");
    if (fs.existsSync(regional)) files.push(regional);
    if (fs.existsSync(legacy)) files.push(legacy);
  } else if (args.includes("--longhaul-corridor")) {
    files = listLonghaulCorridor();
  } else if (args.length) {
    files = args.filter((a) => !a.startsWith("--") && a !== candidateOutDir);
  } else {
    console.error(
      "Usage: build-graph-v2.js --ns | --longhaul-corridor | <v1.json.gz...> [--candidate-out dir]"
    );
    process.exit(1);
  }

  for (const file of files) {
    const started = Date.now();
    console.log("converting", file);
    const opts = {};
    if (candidateOutDir) {
      fs.mkdirSync(candidateOutDir, { recursive: true });
      const base = path.basename(file).replace(/\.json\.gz$/i, "");
      opts.graphPath = path.join(candidateOutDir, base + ".v3.candidate.bin");
      opts.geomPath = path.join(candidateOutDir, base + ".geometry.v3.candidate.bin");
    }
    const result = convertV1FileToV2(file, opts);
    console.log(
      JSON.stringify({
        ...result,
        ms: Date.now() - started,
        graphMB: +(result.graphBytes / 1e6).toFixed(2),
        geomMB: +(result.geomBytes / 1e6).toFixed(2)
      })
    );
  }
}

main();
