#!/usr/bin/env node
"use strict";

/**
 * Prebuild a thinned Canada long-haul corridor graph for Halifax↔Vancouver-class routes.
 * Uses NRN regional packs, southern anchors, border stitching, thinned geometries.
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { mergeRegionalGraphs, corridorLocationsForRoute } = require("../routing/regional/merge");
const { clipGraphToCorridor } = require("../routing/regional/corridor");
const { writeRegionalGraph } = require("../routing/regional/package");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");
const CODES = ["ns", "nb", "qc", "on", "mb", "sk", "ab", "bc"];

function load(code) {
  const buf = fs.readFileSync(path.join(REGIONS, code, "graph.v1.json.gz"));
  const g = JSON.parse(zlib.gunzipSync(buf).toString("utf8"));
  g.regionId = code;
  return g;
}

function thinGeometry(coords, maxPts = 8) {
  if (!coords || coords.length <= maxPts) return coords;
  const out = [coords[0]];
  const step = (coords.length - 1) / (maxPts - 1);
  for (let i = 1; i < maxPts - 1; i += 1) {
    out.push(coords[Math.round(i * step)]);
  }
  out.push(coords[coords.length - 1]);
  return out;
}

function main() {
  const locs = [
    { lat: 44.6488, lon: -63.575 },
    { lat: 49.2827, lon: -123.1207 }
  ];
  const corridor = corridorLocationsForRoute(locs);
  console.log("loading + clipping…");
  const graphs = CODES.map((code) => {
    let g = load(code);
    // Drop tracks to shrink NS supplement noise on long haul.
    g.edges = g.edges.filter((e) => e.s !== 3);
    g = clipGraphToCorridor(g, corridor, 220000);
    g.regionId = code;
    console.log(code, g.edgeCount);
    return g;
  });
  console.log("merging…");
  const merged = mergeRegionalGraphs(graphs);
  console.log("matches", merged.report.boundaryMatches, "edges", merged.graph.edgeCount);
  for (const e of merged.graph.edges) {
    e.g = thinGeometry(e.g, 6);
  }
  merged.graph.regionId = "canada-longhaul";
  merged.graph.province = "CA";
  merged.graph.schemaVersion = "canada-longhaul-1";
  merged.graph.lineage = {
    purpose: "cross-canada cleanest/direct corridor",
    regions: CODES,
    merge: merged.report,
    thinnedGeometry: true
  };
  const out = path.join(REGIONS, "canada-longhaul");
  const written = writeRegionalGraph(merged.graph, out);
  console.log("wrote", written.graphPath, written.meta.gzBytes, "bytes", written.meta.edgeCount, "edges");
}

main();
