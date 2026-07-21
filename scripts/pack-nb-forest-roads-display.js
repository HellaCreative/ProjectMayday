#!/usr/bin/env node
"use strict";

/**
 * Pack New Brunswick Forest Roads into display chunks for the Layers panel
 * network overlay (same chunk scheme as ns-gov-roads).
 *
 * Uses the nb-forest-roads adapter. Display surfaceClass is "access"
 * (map paint vocabulary); routing uses resource via the regional graph build.
 *
 * Usage: node scripts/pack-nb-forest-roads-display.js
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const nb = require("../routing/adapters/nb-forest-roads");

const ROOT = path.join(__dirname, "..");
const OUT_DIR = path.join(ROOT, "app", "data");
const CHUNK_DEG = Number(process.env.NB_GOV_CHUNK_DEG || 0.4);
const OUT_BASENAME = "nb-gov-roads";

function bump(map, key, n = 1) {
  map[key] = (map[key] || 0) + n;
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

async function main() {
  console.log("Fetching NB Forest Roads for display pack…");
  const { features, report } = await nb.run({ pageSize: 2000 });
  console.log("Features:", features.length);

  const chunks = new Map();
  const counts = { access: 0, gravel: 0, paved: 0, track: 0, unknown: 0 };

  for (const edge of features) {
    const coords = (edge.geometry && edge.geometry.coordinates) || [];
    if (coords.length < 2) continue;
    const line = coords.map(roundCoord);
    const mid = line[Math.floor(line.length / 2)];
    const lon = mid[0];
    const lat = mid[1];
    const cx = Math.floor(lon / CHUNK_DEG);
    const cy = Math.floor(lat / CHUNK_DEG);
    const key = cx + "_" + cy;
    let chunk = chunks.get(key);
    if (!chunk) {
      chunk = {
        id: key,
        cx,
        cy,
        features: []
      };
      chunks.set(key, chunk);
    }
    // Display vocabulary: resource -> access (matches ns-gov-access layer filter).
    const surfaceClass = "access";
    bump(counts, surfaceClass);
    chunk.features.push({
      type: "Feature",
      properties: {
        edgeId: edge.edgeId,
        lineageId: edge.lineageId,
        surfaceClass,
        accessClass: edge.accessClass || "motorized_unknown",
        structureType: edge.structureType || "none",
        source: "nb-forest-roads",
        province: "NB"
      },
      geometry: { type: "LineString", coordinates: line }
    });
  }

  const chunkDir = path.join(OUT_DIR, "nb-gov-chunks");
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
    const bbox = [minX, minY, maxX, maxY];
    const file = chunk.id + ".geojson.gz";
    const payload = JSON.stringify({ type: "FeatureCollection", features: chunk.features });
    const gz = zlib.gzipSync(Buffer.from(payload), { level: 6 });
    fs.writeFileSync(path.join(chunkDir, file), gz);
    totalGz += gz.length;
    manifestChunks.push({ id: chunk.id, file, bbox, count: chunk.features.length });
  }

  const manifest = {
    generatedAt: new Date().toISOString(),
    schemaVersion: "network-display-1",
    dataset: OUT_BASENAME,
    province: "NB",
    source: report.downloadUrl,
    license: report.license,
    region: "New Brunswick",
    chunkDeg: CHUNK_DEG,
    chunkDir: "nb-gov-chunks",
    counts,
    featureCount: features.length,
    gzBytes: totalGz,
    chunks: manifestChunks,
    adapter: report.adapter
  };

  fs.writeFileSync(
    path.join(OUT_DIR, OUT_BASENAME + ".manifest.json"),
    JSON.stringify(manifest, null, 2) + "\n"
  );
  console.log("Wrote", path.join(OUT_DIR, OUT_BASENAME + ".manifest.json"));
  console.log("Chunks:", manifestChunks.length, "gzBytes:", totalGz);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
