#!/usr/bin/env node
/**
 * Pack Geofabrik's simplified OSM GeoPackage export as a comparison overlay.
 *
 * This source is additive. It is useful for visual coverage comparison but
 * lacks full OSM access/surface tags available in the PBF-derived overlay.
 */
const fs = require("fs");
const path = require("path");
const readline = require("readline");
const zlib = require("zlib");

const inputPath = process.argv[2];
const outDir = process.argv[3] || path.join(__dirname, "..", "app", "data");
const sourceUrl = process.argv[4] || "https://download.geofabrik.de/north-america/canada/nova-scotia-latest-free.gpkg.zip";
const OUT_BASENAME = "osm-geofabrik-gpkg";

if (!inputPath) {
  console.error("Usage: node scripts/pack-osm-geofabrik-gpkg.js <input.geojsonseq> [outDir] [sourceUrl]");
  process.exit(1);
}

function classify(props) {
  const fclass = String(props.fclass || "").toLowerCase();
  if (fclass === "track_grade1") return "paved";
  if (fclass === "track_grade4" || fclass === "track_grade5") return "atv";
  if (fclass === "path" || fclass === "bridleway") return "single";
  if (fclass === "track" || fclass === "track_grade2" || fclass === "track_grade3") return "gravel";
  return "";
}

function shouldKeep(props) {
  const trackClass = classify(props);
  return trackClass && trackClass !== "paved";
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

function featureFromGeofabrik(feature, kept) {
  if (!feature.geometry || !["LineString", "MultiLineString"].includes(feature.geometry.type)) return null;
  const props = feature.properties || {};
  if (!shouldKeep(props)) return null;
  const geom = roundGeom(feature.geometry);
  if (!geom) return null;

  const trackClass = classify(props);
  const id = props.osm_id ? `osm-gpkg-${props.osm_id}` : `osm-gpkg-${kept}`;
  const properties = {
    id,
    source: "OSM Geofabrik GPKG",
    trackClass,
    highway: String(props.fclass || ""),
    fclass: String(props.fclass || ""),
    accessStatus: "unknown",
    accessDetail: "not included in Geofabrik simplified GPKG export"
  };

  for (const key of ["name", "ref", "oneway", "maxspeed", "bridge", "tunnel"]) {
    if (props[key] !== undefined && props[key] !== null && props[key] !== "") {
      properties[key] = props[key];
    }
  }

  return {
    type: "Feature",
    properties,
    geometry: geom
  };
}

async function main() {
  const rl = readline.createInterface({
    input: fs.createReadStream(inputPath),
    crlfDelay: Infinity
  });

  const features = [];
  let skipped = 0;
  const fclasses = {};

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
    const fclass = parsed.properties?.fclass || "unknown";
    fclasses[fclass] = (fclasses[fclass] || 0) + 1;
    const feature = featureFromGeofabrik(parsed, features.length);
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

  fs.mkdirSync(outDir, { recursive: true });
  const fc = { type: "FeatureCollection", features };
  const json = JSON.stringify(fc);
  const gzPath = path.join(outDir, `${OUT_BASENAME}.geojson.gz`);
  const metaPath = path.join(outDir, `${OUT_BASENAME}.meta.json`);
  fs.writeFileSync(gzPath, zlib.gzipSync(Buffer.from(json), { level: 9 }));

  const meta = {
    generatedAt: new Date().toISOString(),
    sourceName: "OSM Geofabrik GPKG roads/path comparison overlay",
    source: sourceUrl,
    queryModel: "Geofabrik free GPKG gis_osm_roads_free fclass track/path filter",
    license: "ODbL - OpenStreetMap contributors",
    region: "Nova Scotia",
    featureCount: features.length,
    skipped,
    bytes: Buffer.byteLength(json),
    gzBytes: fs.statSync(gzPath).size,
    classes,
    fclasses,
    limitations: [
      "Simplified Geofabrik export omits full OSM surface, tracktype, motorcycle, atv, motor_vehicle, vehicle, and access tags."
    ]
  };
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  console.log(JSON.stringify(meta, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
