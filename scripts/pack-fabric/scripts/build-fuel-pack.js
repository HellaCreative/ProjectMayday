#!/usr/bin/env node
"use strict";

/**
 * Pack motorcycle-usable OSM fuel into viewport chunks.
 *
 * Usage (from MAYDAYiOS/Dirt):
 *   node scripts/pack-fabric/scripts/build-fuel-pack.js \
 *     data-raw/osm-fuel/british-columbia/fuel.geojsonseq \
 *     [outDir]
 *
 * Default out: data-raw/osm-fuel/pack
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { isMotorcycleUsable, rejection } = require("../poi/fuel-filter.js");

const inputPath = process.argv[2];
const outDir = process.argv[3] || path.join(__dirname, "../../../data-raw/osm-fuel/pack");
const CHUNK_DEG = Number(process.env.FUEL_CHUNK_DEG || 0.5);

if (!inputPath) {
  console.error("Usage: node scripts/pack-fabric/scripts/build-fuel-pack.js <fuel.geojsonseq> [outDir]");
  process.exit(1);
}

function representativePoint(geom) {
  if (!geom) return null;
  if (geom.type === "Point") return geom.coordinates;
  if (geom.type === "LineString") return averageCoords(geom.coordinates);
  if (geom.type === "Polygon") return averageCoords(geom.coordinates[0] || []);
  if (geom.type === "MultiPolygon") {
    let best = null;
    let bestLen = -1;
    for (const poly of geom.coordinates) {
      const ring = poly[0] || [];
      if (ring.length > bestLen) {
        bestLen = ring.length;
        best = ring;
      }
    }
    return averageCoords(best || []);
  }
  if (geom.type === "MultiLineString") return averageCoords(geom.coordinates.flat());
  return null;
}

function averageCoords(coords) {
  if (!coords || !coords.length) return null;
  let sx = 0;
  let sy = 0;
  let n = 0;
  for (const c of coords) {
    if (!Array.isArray(c) || !Number.isFinite(c[0]) || !Number.isFinite(c[1])) continue;
    sx += c[0];
    sy += c[1];
    n++;
  }
  if (!n) return null;
  return [sx / n, sy / n];
}

function round6(v) {
  return Math.round(v * 1e6) / 1e6;
}

function clean(v) {
  if (v == null) return null;
  const s = String(v).trim();
  return s ? s : null;
}

function composeAddress(p) {
  const line1 = [p["addr:housenumber"], p["addr:street"]].filter(Boolean).join(" ");
  const parts = [line1, p["addr:city"], p["addr:province"] || p["addr:state"], p["addr:postcode"]]
    .map((s) => (s || "").trim())
    .filter(Boolean);
  return parts.length ? parts.join(", ") : null;
}

function osmTagsFromProps(p) {
  const skip = new Set(["@id", "@type", "@timestamp", "@version"]);
  const out = {};
  for (const [k, v] of Object.entries(p || {})) {
    if (skip.has(k) || v == null) continue;
    const s = String(v).trim();
    if (s) out[k] = s;
  }
  return out;
}

function readSeq(text) {
  return text
    .split(/\x1e/)
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      try {
        return JSON.parse(s);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

const raw = fs.readFileSync(inputPath, "utf8");
const features = readSeq(raw);

const chunks = new Map();
const dropped = {
  closed: 0,
  truckOnly: 0,
  privateAccess: 0,
  dieselOnly: 0,
  bulkOrCardlock: 0,
  notFuel: 0,
  noGeom: 0
};
let kept = 0;
const allPois = [];

for (const f of features) {
  const p = f.properties || {};
  if (p.amenity !== "fuel") {
    dropped.notFuel++;
    continue;
  }
  const pt = representativePoint(f.geometry);
  if (!pt) {
    dropped.noGeom++;
    continue;
  }
  const lon = round6(pt[0]);
  const lat = round6(pt[1]);
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
    dropped.noGeom++;
    continue;
  }

  const osmTags = osmTagsFromProps(p);
  const name = clean(p.name) || clean(p.brand) || clean(p.operator);
  const brand = clean(p.brand) || clean(p.operator);
  const openingHours = clean(p.opening_hours);
  const reason = rejection({ name, brand, openingHours, tags: osmTags });
  if (reason) {
    dropped[reason] = (dropped[reason] || 0) + 1;
    continue;
  }
  if (!isMotorcycleUsable({ name, brand, openingHours, tags: osmTags })) {
    dropped.bulkOrCardlock++;
    continue;
  }

  const rawId = String(f.id || p["@id"] || "");
  const numericId = rawId.replace(/^[nwr]/, "");
  const ts = p["@timestamp"];
  const sourceUpdatedAt = Number.isFinite(ts)
    ? new Date(ts * 1000).toISOString()
    : clean(p["@timestamp"]);

  const poi = {
    id: "osm:" + (rawId || "fuel:" + numericId),
    category: "fuel",
    lat,
    lon,
    name,
    address: composeAddress(p),
    brand,
    openingHours,
    phone: clean(p.phone) || clean(p["contact:phone"]),
    website: clean(p.website) || clean(p["contact:website"]),
    osmTags,
    source: "openstreetmap",
    sourceId: numericId || rawId,
    sourceUpdatedAt: sourceUpdatedAt || null
  };

  const cx = Math.floor(lon / CHUNK_DEG);
  const cy = Math.floor(lat / CHUNK_DEG);
  const key = cx + "_" + cy;
  let chunk = chunks.get(key);
  if (!chunk) {
    chunk = { id: key, pois: [] };
    chunks.set(key, chunk);
  }
  chunk.pois.push(poi);
  allPois.push({
    id: poi.id,
    lat: poi.lat,
    lon: poi.lon,
    name: poi.name,
    brand: poi.brand,
    address: poi.address,
    openingHours: poi.openingHours,
    phone: poi.phone,
    website: poi.website
  });
  kept++;
}

const chunkDir = path.join(outDir, "chunks");
fs.rmSync(chunkDir, { recursive: true, force: true });
fs.mkdirSync(chunkDir, { recursive: true });

const manifestChunks = [];
let totalGz = 0;
for (const chunk of [...chunks.values()].sort((a, b) => a.id.localeCompare(b.id))) {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const poi of chunk.pois) {
    if (poi.lon < minX) minX = poi.lon;
    if (poi.lat < minY) minY = poi.lat;
    if (poi.lon > maxX) maxX = poi.lon;
    if (poi.lat > maxY) maxY = poi.lat;
  }
  const bbox = [round6(minX), round6(minY), round6(maxX), round6(maxY)];
  const file = chunk.id + ".json.gz";
  const payload = JSON.stringify({ id: chunk.id, bbox, pois: chunk.pois });
  const gz = zlib.gzipSync(Buffer.from(payload), { level: 9 });
  fs.writeFileSync(path.join(chunkDir, file), gz);
  totalGz += gz.length;
  manifestChunks.push({ id: chunk.id, file, bbox, count: chunk.pois.length });
}

const droppedTotal = Object.values(dropped).reduce((a, b) => a + b, 0);
const manifest = {
  generatedAt: new Date().toISOString(),
  schemaVersion: "fuel-poi-1",
  dataset: "DIRT motorcycle fuel",
  source: path.basename(inputPath),
  license: "OpenStreetMap contributors (ODbL)",
  attribution: "© OpenStreetMap contributors",
  chunkDeg: CHUNK_DEG,
  chunkDir: "chunks",
  filter: "FuelPOIFilter / pack-fabric/poi/fuel-filter.js",
  counts: { fuel: kept },
  dropped,
  featureCount: kept,
  skipped: droppedTotal,
  gzBytes: totalGz,
  chunks: manifestChunks
};

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, "fuel.manifest.json"), JSON.stringify(manifest, null, 2) + "\n");

const v1Out = process.env.FUEL_V1_OUT;
if (v1Out) {
  const regionId = process.env.FUEL_REGION_ID || "";
  const payload = {
    schema: "fuel.v1",
    regionId,
    generatedAt: manifest.generatedAt,
    source: "openstreetmap",
    sourceUpdatedAt: process.env.FUEL_SOURCE_UPDATED_AT || null,
    sourceSha256: process.env.FUEL_SOURCE_SHA256 || null,
    license: manifest.license,
    stations: allPois
  };
  fs.mkdirSync(path.dirname(v1Out), { recursive: true });
  fs.writeFileSync(v1Out, JSON.stringify(payload));
  console.log("  fuel.v1: " + v1Out + " (" + allPois.length + " stations, " + Math.round(fs.statSync(v1Out).size / 1024) + " KB)");
}

console.log("Fuel pack complete");
console.log("  kept:    " + kept);
console.log("  dropped:", dropped);
console.log("  chunks:  " + manifestChunks.length);
console.log("  gz:      " + (totalGz / 1024).toFixed(1) + " KB");
console.log("  out:     " + outDir);
