#!/usr/bin/env node
"use strict";

/**
 * Split Quebec into three Vercel longhaul packs (Hobby-safe).
 *
 * Quebec uses OSM-only fabric — NRN locals are too sparse/wrong for dirt bias
 * and basemap snaps. NB/NS keep NRN+OSM via build-longhaul-region-packs.js.
 *
 *   qc-sl   — St. Lawrence / river corridor (NB border → Québec → Saguenay)
 *   qc-west — Ontario border / Montréal / Laurentians / Outaouais
 *   qc-north — Far north / Côte-Nord (sparse)
 *
 * Overlapping bboxes so neighbouring packs share border nodes for merge.
 * Source: regions/qc/graph.v1.json.gz (OSM edges only kept at extract).
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const {
  clipGraphToBbox,
  extractRoadFabricLonghaulGraph,
  relabelComponents
} = require("../routing/regional/corridor");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");
const QC_FULL = path.join(REGIONS, "qc", "graph.v1.json.gz");

/** Overlapping W,S,E,N. Pad intentionally so west↔sl and north↔south merge. */
const QUADRANTS = {
  "qc-west": {
    bbox: [-79.8, 44.9, -72.2, 48.0],
    hubs: [
      { lon: -73.567, lat: 45.502 },
      { lon: -74.60, lat: 46.12 },
      { lon: -75.71, lat: 45.43 }
    ]
  },
  "qc-sl": {
    bbox: [-73.0, 44.9, -64.0, 49.2],
    hubs: [
      { lon: -68.65, lat: 47.55 },
      { lon: -71.208, lat: 46.813 },
      { lon: -71.15, lat: 48.42 }
    ]
  },
  "qc-north": {
    bbox: [-79.8, 48.7, -57.0, 62.7],
    hubs: [
      { lon: -68.15, lat: 49.22 },
      { lon: -66.38, lat: 50.22 }
    ]
  }
};

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

function loadQc() {
  const buf = fs.readFileSync(QC_FULL);
  const g = JSON.parse(zlib.gunzipSync(buf).toString("utf8"));
  g.regionId = "qc";
  return g;
}

function writePack(code, g, lineage) {
  const outDir = path.join(REGIONS, code);
  fs.mkdirSync(outDir, { recursive: true });
  for (const e of g.edges) e.g = thinGeometry(e.g, 6);
  g.edgeCount = g.edges.length;
  g.regionId = code;
  g.province = "QC";
  g.schemaVersion = "longhaul-region-1";
  g.lineage = lineage;
  const json = JSON.stringify(g);
  const gz = zlib.gzipSync(Buffer.from(json, "utf8"), { level: 9 });
  fs.writeFileSync(path.join(outDir, "longhaul.v1.json.gz"), gz);
  const meta = {
    regionId: code,
    schemaVersion: g.schemaVersion,
    edgeCount: g.edgeCount,
    nodeCount: g.nodeCount,
    gzBytes: gz.length,
    inflatedBytes: Buffer.byteLength(json),
    path: `routing/data/regions/${code}/longhaul.v1.json.gz`,
    lineage
  };
  fs.writeFileSync(path.join(outDir, "longhaul.v1.meta.json"), JSON.stringify(meta, null, 2));
  console.log(
    code,
    "edges",
    g.edgeCount,
    "gzMB",
    (gz.length / 1e6).toFixed(2),
    "inflMB",
    (meta.inflatedBytes / 1e6).toFixed(1),
    "mode",
    lineage.extractMode
  );
}

function main() {
  const only = process.argv.slice(2).filter((a) => !a.startsWith("--")).map((c) => c.toLowerCase());
  const codes = only.length ? only : Object.keys(QUADRANTS);
  console.log("loading qc/graph.v1.json.gz …");
  const full = loadQc();
  const inputEdges = (full.edges || []).length;
  console.log("qc full edges", inputEdges);

  for (const code of codes) {
    const spec = QUADRANTS[code];
    if (!spec) {
      console.error("unknown quadrant", code);
      process.exitCode = 1;
      continue;
    }
    let g = clipGraphToBbox(full, spec.bbox);
    const afterBbox = g.edgeCount || (g.edges || []).length;
    g = extractRoadFabricLonghaulGraph(g, {
      mode: "osm",
      hubLocations: spec.hubs || [],
      hubBufferMeters: 40000
    });
    g = relabelComponents(g);
    writePack(code, g, {
      purpose: "canada-chain QC quadrant pack (OSM-only; no NRN)",
      mentalModel: "osm-fabric-quadrant",
      source: "regions/qc/graph.v1.json.gz",
      extractMode: "fabric-osm-only",
      dropNrn: true,
      bbox: spec.bbox,
      hubCount: (spec.hubs || []).length,
      inputEdgeCount: inputEdges,
      bboxEdgeCount: afterBbox,
      outputEdgeCount: g.edgeCount || (g.edges || []).length,
      thinnedGeometry: true
    });
  }
}

main();
