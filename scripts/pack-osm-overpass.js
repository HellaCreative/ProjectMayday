#!/usr/bin/env node
/**
 * Pack OSM track/path candidates into the DIRT OSM Overpass-style overlay.
 *
 * This keeps every track/path/bridleway candidate and preserves access tags
 * as metadata, avoiding fragmented trails caused by incomplete OSM tagging.
 */
const fs = require("fs");
const path = require("path");
const readline = require("readline");
const zlib = require("zlib");

const inputPath = process.argv[2];
const outDir = process.argv[3] || path.join(__dirname, "..", "app", "data");
const sourceUrl = process.argv[4] || "https://download.geofabrik.de/north-america/canada/nova-scotia-latest.osm.pbf";
const OUT_BASENAME = "osm-overpass-trails";

if (!inputPath) {
  console.error("Usage: node scripts/pack-osm-overpass.js <input.geojsonseq> [outDir] [sourceUrl]");
  process.exit(1);
}

const ACCESS_YES = /^(yes|designated|permissive|destination)$/i;
const ACCESS_NO = /^(no|private)$/i;
const PAVED_SURFACE = /^(paved|asphalt|concrete|paving_stones|sett|cobblestone)$/i;

function shouldKeep(tags) {
  const highway = tags.highway || "";
  return /^(track|path|bridleway)$/.test(highway);
}

function classify(tags) {
  const highway = tags.highway || "";
  if (ACCESS_YES.test(tags.motorcycle || "") && highway === "path") return "single";
  if (ACCESS_YES.test(tags.atv || "") || /^(grade4|grade5)$/i.test(tags.tracktype || "")) return "atv";
  if (highway === "path" || highway === "bridleway") return "single";
  if (PAVED_SURFACE.test(tags.surface || "") || /^(grade1)$/i.test(tags.tracktype || "")) return "paved";
  return "gravel";
}

function accessStatus(tags) {
  const positive = ["motorcycle", "atv", "motor_vehicle", "vehicle"].find((key) => ACCESS_YES.test(tags[key] || ""));
  if (positive) return { status: "allowed", detail: `${positive}=${tags[positive]}` };
  const restricted = ["motorcycle", "atv", "motor_vehicle", "vehicle", "access"].find((key) => ACCESS_NO.test(tags[key] || ""));
  if (restricted) return { status: "restricted", detail: `${restricted}=${tags[restricted]}` };
  return { status: "unknown", detail: "no OSM motor access tag" };
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

function roundGeom(g) {
  if (g.type === "LineString") {
    return { type: "LineString", coordinates: g.coordinates.map(roundCoord) };
  }
  if (g.type === "MultiLineString") {
    return {
      type: "MultiLineString",
      coordinates: g.coordinates.map((line) => line.map(roundCoord))
    };
  }
  return null;
}

function featureFromOsmium(feature, kept) {
  if (!feature.geometry || !["LineString", "MultiLineString"].includes(feature.geometry.type)) return null;
  const tags = feature.properties || {};
  if (!shouldKeep(tags)) return null;
  const access = accessStatus(tags);
  const id = tags["@id"] || feature.id || `osm-${kept}`;
  const properties = {
    id,
    source: "OSM Overpass",
    trackClass: classify(tags),
    highway: tags.highway || "",
    accessStatus: access.status,
    accessDetail: access.detail
  };

  for (const key of ["name", "surface", "tracktype", "atv", "motorcycle", "motor_vehicle", "vehicle", "access"]) {
    if (tags[key]) properties[key] = tags[key];
  }

  return {
    type: "Feature",
    properties,
    geometry: roundGeom(feature.geometry)
  };
}

async function main() {
  const rl = readline.createInterface({
    input: fs.createReadStream(inputPath),
    crlfDelay: Infinity
  });

  const features = [];
  let skipped = 0;

  for await (const raw of rl) {
    const line = raw.replace(/^\x1e/, "").trim();
    if (!line) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      skipped += 1;
      continue;
    }
    const feature = featureFromOsmium(parsed, features.length);
    if (feature) {
      features.push(feature);
    } else {
      skipped += 1;
    }
  }

  const classes = features.reduce((acc, feature) => {
    const key = feature.properties.trackClass;
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});
  const access = features.reduce((acc, feature) => {
    const key = feature.properties.accessStatus;
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});

  fs.mkdirSync(outDir, { recursive: true });
  const fc = { type: "FeatureCollection", features };
  const json = JSON.stringify(fc);
  const gzPath = path.join(outDir, `${OUT_BASENAME}.geojson.gz`);
  const metaPath = path.join(outDir, `${OUT_BASENAME}.meta.json`);
  fs.writeFileSync(gzPath, zlib.gzipSync(Buffer.from(json), { level: 9 }));

  const meta = {
    generatedAt: new Date().toISOString(),
    sourceName: "OSM Overpass track/path overlay",
    source: sourceUrl,
    queryModel: "Overpass-equivalent OSM highway=track/path/bridleway filter",
    license: "ODbL - OpenStreetMap contributors",
    region: "Nova Scotia",
    featureCount: features.length,
    skipped,
    bytes: Buffer.byteLength(json),
    gzBytes: fs.statSync(gzPath).size,
    classes,
    access
  };
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  console.log(JSON.stringify(meta, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
