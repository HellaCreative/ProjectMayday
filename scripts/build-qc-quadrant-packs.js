#!/usr/bin/env node
"use strict";

/**
 * Split Quebec into three Vercel longhaul packs so each fits Hobby 2048 MB
 * while keeping NB/NS-style dense fabric (all NRN non-track + OSM hub bulbs).
 *
 *   qc-sl   — St. Lawrence / river corridor (NB border → Québec → Trois-Rivières)
 *   qc-west — Ontario border / Montréal / Laurentians / Outaouais
 *   qc-north — Saguenay and north (sparse; few riders)
 *
 * Overlapping bboxes so neighbouring packs share border nodes for merge.
 * Source is always regions/qc/graph.v1.json.gz. Writes longhaul-only folders.
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const {
  clipGraphToBbox,
  extractRoadFabricLonghaulGraph,
  extractLonghaulSpineGraph,
  relabelComponents
} = require("../routing/regional/corridor");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");
const QC_FULL = path.join(REGIONS, "qc", "graph.v1.json.gz");

/** Overlapping W,S,E,N. Pad intentionally so west↔sl and north↔south merge. */
const QUADRANTS = {
  "qc-west": {
    // Tighter east edge; dense hubs instead of all-NRN (bbox alone is huge).
    bbox: [-79.8, 44.9, -72.2, 48.0],
    mode: "hub",
    hubBufferMeters: 42000,
    hubs: [
      { lon: -73.567, lat: 45.502 }, // Montréal
      { lon: -73.75, lat: 45.58 }, // Laval
      { lon: -74.28, lat: 46.05 }, // Sainte-Agathe
      { lon: -74.60, lat: 46.12 }, // Mont-Tremblant
      { lon: -73.98, lat: 46.12 }, // Entrelacs / Lac La Fontaine
      { lon: -74.05, lat: 46.0 }, // Rawdon / Notre-Dame-de-la-Merci
      { lon: -75.71, lat: 45.43 }, // Gatineau
      { lon: -74.75, lat: 45.65 }, // Lachute / Argenteuil
      { lon: -72.543, lat: 46.343 }, // Trois-Rivières stitch
      { lon: -73.2, lat: 45.65 }, // Contrecoeur / south shore stitch
      { lon: -72.8, lat: 46.05 } // Louiseville stitch toward river pack
    ]
  },
  "qc-sl": {
    // Includes Saguenay — real rider destination, not "far north".
    bbox: [-73.0, 44.9, -64.0, 49.2],
    mode: "maritime",
    hubBufferMeters: 40000,
    hubs: [
      { lon: -68.65, lat: 47.55 }, // Dégelis
      { lon: -69.542, lat: 47.837 }, // Rivière-du-Loup
      { lon: -70.33, lat: 47.38 },
      { lon: -71.208, lat: 46.813 }, // Québec
      { lon: -71.30, lat: 46.95 }, // Lac-Beauport
      { lon: -71.833, lat: 46.899 }, // Saint-Raymond
      { lon: -72.543, lat: 46.343 }, // Trois-Rivières
      { lon: -71.93, lat: 45.40 }, // Sherbrooke
      { lon: -72.15, lat: 45.65 }, // Drummondville
      { lon: -72.8, lat: 46.05 }, // Louiseville stitch toward west pack
      { lon: -71.15, lat: 48.42 } // Saguenay
    ]
  },
  "qc-north": {
    // Far north / Côte-Nord — sparse spine; few riders.
    bbox: [-79.8, 48.7, -57.0, 62.7],
    mode: "spine",
    hubBufferMeters: 35000,
    hubs: [
      { lon: -68.15, lat: 49.22 }, // Baie-Comeau
      { lon: -66.38, lat: 50.22 }, // Sept-Îles
      { lon: -74.0, lat: 53.0 } // northern spine sample
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
    let extractMode = "fabric-maritime";
    if (spec.mode === "spine") {
      extractMode = "longhaul-spine";
      g = extractLonghaulSpineGraph(g);
    } else if (spec.mode === "hub") {
      extractMode = "fabric-hub";
      g = extractRoadFabricLonghaulGraph(g, {
        mode: "hub",
        hubLocations: spec.hubs,
        hubBufferMeters: spec.hubBufferMeters
      });
    } else {
      g = extractRoadFabricLonghaulGraph(g, {
        mode: "maritime",
        hubLocations: spec.hubs,
        hubBufferMeters: spec.hubBufferMeters
      });
    }
    g = relabelComponents(g);
    writePack(code, g, {
      purpose: "canada-chain QC quadrant pack (Hobby-safe dense fabric)",
      mentalModel: "osm-nrn-fabric-quadrant",
      source: "regions/qc/graph.v1.json.gz",
      extractMode,
      bbox: spec.bbox,
      hubCount: (spec.hubs || []).length,
      hubBufferMeters: spec.hubBufferMeters,
      inputEdgeCount: inputEdges,
      bboxEdgeCount: afterBbox,
      outputEdgeCount: g.edgeCount || (g.edges || []).length,
      thinnedGeometry: true
    });
  }
}

main();
