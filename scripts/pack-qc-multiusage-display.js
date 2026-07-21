#!/usr/bin/env node
"use strict";

/**
 * Pack Quebec chemins multiusages edges from the regional graph into display
 * chunks for the Layers "Show QC route lines" toggle (same scheme as ns/nb-gov).
 *
 * Usage: node scripts/pack-qc-multiusage-display.js
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const ROOT = path.join(__dirname, "..");
const GRAPH_PATH = path.join(ROOT, "routing", "data", "regions", "qc", "graph.v1.json.gz");
const OUT_DIR = path.join(ROOT, "app", "data");
const CHUNK_DEG = Number(process.env.QC_GOV_CHUNK_DEG || 0.5);
const OUT_BASENAME = "qc-gov-roads";
const SOURCE_MATCH = /qu[eé]bec chemins multiusages|aqr[eé]seau/i;

function bump(map, key, n = 1) {
  map[key] = (map[key] || 0) + n;
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

function main() {
  if (!fs.existsSync(GRAPH_PATH)) {
    throw new Error("Missing QC graph: " + GRAPH_PATH);
  }
  console.log("Reading", GRAPH_PATH);
  const graph = JSON.parse(zlib.gunzipSync(fs.readFileSync(GRAPH_PATH)).toString("utf8"));
  const surfaceName = (graph.enums && graph.enums.SURFACE_NAME) || {};
  const accessName = (graph.enums && graph.enums.ACCESS_NAME) || {};
  const chunks = new Map();
  const counts = { access: 0, gravel: 0, paved: 0, track: 0, unknown: 0 };
  let kept = 0;

  for (const e of graph.edges || []) {
    const src = e.src || "";
    if (!SOURCE_MATCH.test(src)) continue;
    const coords = e.g || [];
    if (coords.length < 2) continue;
    const line = coords.map(roundCoord);
    const mid = line[Math.floor(line.length / 2)];
    const cx = Math.floor(mid[0] / CHUNK_DEG);
    const cy = Math.floor(mid[1] / CHUNK_DEG);
    const key = cx + "_" + cy;
    let chunk = chunks.get(key);
    if (!chunk) {
      chunk = { id: key, cx, cy, features: [] };
      chunks.set(key, chunk);
    }
    const rawSurface = surfaceName[e.s] || "access";
    const surfaceClass =
      rawSurface === "resource" || rawSurface === "access"
        ? "access"
        : rawSurface === "track" || rawSurface === "double_track"
          ? "track"
          : rawSurface === "gravel"
            ? "gravel"
            : rawSurface === "paved"
              ? "paved"
              : "access";
    bump(counts, surfaceClass in counts ? surfaceClass : "unknown");
    chunk.features.push({
      type: "Feature",
      properties: {
        edgeId: e.i,
        lineageId: e.lin || e.i,
        surfaceClass,
        accessClass: accessName[e.ac] || "motorized_unknown",
        structureType: "none",
        source: "qc-multiusage",
        province: "QC"
      },
      geometry: { type: "LineString", coordinates: line }
    });
    kept += 1;
  }

  const chunkDir = path.join(OUT_DIR, "qc-gov-chunks");
  fs.rmSync(chunkDir, { recursive: true, force: true });
  fs.mkdirSync(chunkDir, { recursive: true });

  const manifestChunks = [];
  let totalGz = 0;
  for (const chunk of [...chunks.values()].sort((a, b) => a.id.localeCompare(b.id))) {
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const f of chunk.features) {
      for (const c of f.geometry.coordinates) {
        if (c[0] < minX) minX = c[0];
        if (c[1] < minY) minY = c[1];
        if (c[0] > maxX) maxX = c[0];
        if (c[1] > maxY) maxY = c[1];
      }
    }
    const file = chunk.id + ".geojson.gz";
    const payload = JSON.stringify({ type: "FeatureCollection", features: chunk.features });
    const gz = zlib.gzipSync(Buffer.from(payload), { level: 6 });
    fs.writeFileSync(path.join(chunkDir, file), gz);
    totalGz += gz.length;
    manifestChunks.push({
      id: chunk.id,
      file,
      bbox: [minX, minY, maxX, maxY],
      count: chunk.features.length
    });
  }

  const manifest = {
    generatedAt: new Date().toISOString(),
    schemaVersion: "network-display-1",
    dataset: OUT_BASENAME,
    province: "QC",
    source: "Québec Chemins Multiusages (AQréseau+)",
    license: "Licence Creative Commons CC-BY 4.0 / données ouvertes Québec",
    region: "Quebec",
    chunkDeg: CHUNK_DEG,
    chunkDir: "qc-gov-chunks",
    counts,
    featureCount: kept,
    gzBytes: totalGz,
    chunks: manifestChunks,
    adapter: "qc-multiusage",
    note: "Packed from regional graph provincial edges (not a live FeatureServer pull)."
  };

  fs.writeFileSync(
    path.join(OUT_DIR, OUT_BASENAME + ".manifest.json"),
    JSON.stringify(manifest, null, 2) + "\n"
  );
  console.log("Wrote", path.join(OUT_DIR, OUT_BASENAME + ".manifest.json"));
  console.log("Features:", kept, "chunks:", manifestChunks.length, "gzBytes:", totalGz);
}

main();
