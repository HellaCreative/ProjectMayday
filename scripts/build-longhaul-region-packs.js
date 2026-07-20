#!/usr/bin/env node
"use strict";

/**
 * Build thinned per-province longhaul packs for Vercel canada-chain hops.
 * Full regional graphs inflate to 100–300MB and OOM Hobby isolates; these
 * corridor-clipped packs stay small enough to fetch + merge 1–2 at a time.
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { corridorLocationsForRoute } = require("../routing/regional/merge");
const {
  clipGraphToCorridor,
  extractHighwayGraph,
  extractLonghaulSpineGraph
} = require("../routing/regional/corridor");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");
const CODES = ["ns", "nb", "qc", "on", "mb", "sk", "ab", "bc"];
const BUFFER_M = 200000;

function thinGeometry(coords, maxPts = 6) {
  if (!coords || coords.length <= maxPts) return coords;
  const out = [coords[0]];
  const step = (coords.length - 1) / (maxPts - 1);
  for (let i = 1; i < maxPts - 1; i += 1) {
    out.push(coords[Math.round(i * step)]);
  }
  out.push(coords[coords.length - 1]);
  return out;
}

function load(code) {
  const buf = fs.readFileSync(path.join(REGIONS, code, "graph.v1.json.gz"));
  const g = JSON.parse(zlib.gunzipSync(buf).toString("utf8"));
  g.regionId = code;
  return g;
}

function main() {
  const corridor = corridorLocationsForRoute([
    { lat: 44.6488, lon: -63.575 },
    { lat: 49.2827, lon: -123.1207 }
  ]);
  console.log("corridor waypoints", corridor.length);

  for (const code of CODES) {
    let g = load(code);
    const before = g.edgeCount || (g.edges || []).length;
    const hasRoadClass = (g.edges || []).some((e) => e.rt);
    // Provinces without NRN road class (NS/NB) keep all non-track corridor
    // edges — length filters shatter connectivity. Classed provinces use a
    // freeway/arterial spine so ON/QC stay under Hobby memory.
    g = hasRoadClass ? extractLonghaulSpineGraph(g) : extractHighwayGraph(g);
    const afterSpine = g.edgeCount;
    g = clipGraphToCorridor(g, corridor, BUFFER_M);
    for (const e of g.edges) e.g = thinGeometry(e.g, 6);
    g.edgeCount = g.edges.length;
    g.regionId = code;
    g.province = String(code).toUpperCase();
    g.schemaVersion = "longhaul-region-1";
    g.lineage = {
      purpose: "canada-chain hop pack (NRN spine + southern corridor)",
      source: `regions/${code}/graph.v1.json.gz`,
      hasRoadClass,
      spine: hasRoadClass,
      highwayNoTrack: !hasRoadClass,
      corridorBufferMeters: BUFFER_M,
      thinnedGeometry: true,
      inputEdgeCount: before,
      spineEdgeCount: afterSpine,
      outputEdgeCount: g.edgeCount
    };

    const outDir = path.join(REGIONS, code);
    // writeRegionalGraph always writes graph.v1.json.gz — write custom name.
    const json = JSON.stringify(g);
    const gz = zlib.gzipSync(Buffer.from(json, "utf8"), { level: 9 });
    const graphPath = path.join(outDir, "longhaul.v1.json.gz");
    fs.writeFileSync(graphPath, gz);
    const meta = {
      regionId: code,
      schemaVersion: g.schemaVersion,
      edgeCount: g.edgeCount,
      nodeCount: g.nodeCount,
      gzBytes: gz.length,
      inflatedBytes: Buffer.byteLength(json),
      path: `routing/data/regions/${code}/longhaul.v1.json.gz`,
      lineage: g.lineage
    };
    fs.writeFileSync(path.join(outDir, "longhaul.v1.meta.json"), JSON.stringify(meta, null, 2));
    console.log(
      code,
      "edges",
      before,
      "→spine",
      afterSpine,
      "→pack",
      g.edgeCount,
      "gzMB",
      (gz.length / 1e6).toFixed(2),
      "inflMB",
      (meta.inflatedBytes / 1e6).toFixed(1)
    );
  }
}

main();
