#!/usr/bin/env node
"use strict";

/**
 * Build a Canada-wide NRN spine graph (freeway/arterial/collector/ramp + long paved/gravel)
 * used for multi-province routing without loading every local street.
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { extractSpineGraph } = require("../routing/regional/corridor");
const { mergeRegionalGraphs } = require("../routing/regional/merge");
const { writeRegionalGraph } = require("../routing/regional/package");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");
const CODES = ["bc", "ab", "sk", "mb", "on", "qc", "nb", "ns", "pe", "nl", "yt", "nt", "nu"];

function loadGz(p) {
  return JSON.parse(zlib.gunzipSync(fs.readFileSync(p)).toString("utf8"));
}

function main() {
  const spines = [];
  for (const code of CODES) {
    const p = path.join(REGIONS, code, "graph.v1.json.gz");
    if (!fs.existsSync(p)) {
      console.warn("skip missing", code);
      continue;
    }
    console.log("spine extract", code);
    const g = loadGz(p);
    const spine = extractSpineGraph(g);
    spine.regionId = code;
    spine.province = code.toUpperCase();
    console.log(" ", g.edgeCount, "->", spine.edgeCount);
    spines.push(spine);
  }
  console.log("merging", spines.length, "spines…");
  const merged = mergeRegionalGraphs(spines);
  merged.graph.regionId = "canada-spine";
  merged.graph.province = "CA";
  merged.graph.schemaVersion = "canada-spine-1";
  const out = path.join(REGIONS, "canada-spine");
  const written = writeRegionalGraph(merged.graph, out);
  fs.writeFileSync(
    path.join(ROOT, "routing", "data", "reports", "canada-spine-build.json"),
    JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        merge: merged.report,
        meta: written.meta,
        freeSpaceConnectors: 0
      },
      null,
      2
    )
  );
  console.log("wrote", written.graphPath, written.meta);
}

main();
