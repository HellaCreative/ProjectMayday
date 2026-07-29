#!/usr/bin/env node
"use strict";

/**
 * Pack provincial capillary edges from a regional graph into Layers display
 * chunks (same scheme as ns/nb/qc-gov). Filters out OpenStreetMap backbone.
 *
 * Usage:
 *   node scripts/pack-provincial-display.js bc
 *   node scripts/pack-provincial-display.js ab
 *   node scripts/pack-provincial-display.js on
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const ROOT = path.join(__dirname, "..");
const OUT_DIR = path.join(ROOT, "app", "data");

const PROVINCES = {
  bc: {
    code: "BC",
    regionId: "bc",
    outBase: "bc-gov-roads",
    chunkDir: "bc-gov-chunks",
    sourceMatch: /Digital Road Atlas|BC Digital Road Atlas|\bDRA\b/i,
    sourceLabel: "BC Digital Road Atlas (resource / trail)",
    license: "Open Government Licence - British Columbia",
    regionName: "British Columbia",
    adapter: "bc-dra",
    chunkDeg: 0.5
  },
  ab: {
    code: "AB",
    regionId: "ab",
    outBase: "ab-gov-roads",
    chunkDir: "ab-gov-chunks",
    sourceMatch: /Alberta Access|Facility Roads/i,
    sourceLabel: "Alberta Access and Facility Roads",
    license: "Open Government Licence - Alberta",
    regionName: "Alberta",
    adapter: "ab-access",
    chunkDeg: 0.5
  },
  on: {
    code: "ON",
    regionId: "on",
    outBase: "on-gov-roads",
    chunkDir: "on-gov-chunks",
    sourceMatch: /Ontario MNRF|MNRF/i,
    sourceLabel: "Ontario MNRF Road Segments",
    license: "Open Government Licence - Ontario",
    regionName: "Ontario",
    adapter: "on-mnrf",
    chunkDeg: 0.5
  }
};

function bump(map, key, n = 1) {
  map[key] = (map[key] || 0) + n;
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

function displaySurface(rawSurface) {
  if (rawSurface === "resource" || rawSurface === "access") return "access";
  if (rawSurface === "track" || rawSurface === "double_track") return "track";
  if (rawSurface === "gravel") return "gravel";
  if (rawSurface === "paved") return "paved";
  return "access";
}

function main() {
  const key = String(process.argv[2] || "")
    .trim()
    .toLowerCase();
  const cfg = PROVINCES[key];
  if (!cfg) {
    console.error("Usage: node scripts/pack-provincial-display.js <bc|ab|on>");
    process.exit(1);
  }

  const graphPath = path.join(ROOT, "routing", "data", "regions", cfg.regionId, "graph.v1.json.gz");
  if (!fs.existsSync(graphPath)) {
    throw new Error("Missing graph: " + graphPath);
  }

  console.log("Reading", graphPath);
  const graph = JSON.parse(zlib.gunzipSync(fs.readFileSync(graphPath)).toString("utf8"));
  const surfaceName = (graph.enums && graph.enums.SURFACE_NAME) || {};
  const accessName = (graph.enums && graph.enums.ACCESS_NAME) || {};
  const chunks = new Map();
  const counts = { access: 0, gravel: 0, paved: 0, track: 0, unknown: 0 };
  let kept = 0;

  for (const e of graph.edges || []) {
    const src = e.src || "";
    if (!cfg.sourceMatch.test(src)) continue;
    const coords = e.g || [];
    if (coords.length < 2) continue;
    const line = coords.map(roundCoord);
    const mid = line[Math.floor(line.length / 2)];
    const cx = Math.floor(mid[0] / cfg.chunkDeg);
    const cy = Math.floor(mid[1] / cfg.chunkDeg);
    const chunkKey = cx + "_" + cy;
    let chunk = chunks.get(chunkKey);
    if (!chunk) {
      chunk = { id: chunkKey, cx, cy, features: [] };
      chunks.set(chunkKey, chunk);
    }
    const surfaceClass = displaySurface(surfaceName[e.s] || "access");
    bump(counts, surfaceClass in counts ? surfaceClass : "unknown");
    chunk.features.push({
      type: "Feature",
      properties: {
        edgeId: e.i,
        lineageId: e.lin || e.i,
        surfaceClass,
        accessClass: accessName[e.ac] || "motorized_unknown",
        structureType: "none",
        source: cfg.adapter,
        province: cfg.code
      },
      geometry: { type: "LineString", coordinates: line }
    });
    kept += 1;
  }

  const chunkDir = path.join(OUT_DIR, cfg.chunkDir);
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
    dataset: cfg.outBase,
    province: cfg.code,
    source: cfg.sourceLabel,
    license: cfg.license,
    region: cfg.regionName,
    chunkDeg: cfg.chunkDeg,
    chunkDir: cfg.chunkDir,
    counts,
    featureCount: kept,
    gzBytes: totalGz,
    chunks: manifestChunks,
    adapter: cfg.adapter,
    note: "Packed from regional graph provincial edges (not a live FeatureServer pull)."
  };

  fs.writeFileSync(
    path.join(OUT_DIR, cfg.outBase + ".manifest.json"),
    JSON.stringify(manifest, null, 2) + "\n"
  );
  console.log("Wrote", path.join(OUT_DIR, cfg.outBase + ".manifest.json"));
  console.log("Features:", kept, "chunks:", manifestChunks.length, "gzBytes:", totalGz);
}

main();
