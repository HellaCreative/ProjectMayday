#!/usr/bin/env node
/**
 * Pack NRN resource/recreation road segments into a lightweight DIRT gravel overlay.
 */
const fs = require("fs");
const path = require("path");
const readline = require("readline");
const zlib = require("zlib");

const inputPath = process.argv[2];
const outDir = process.argv[3] || path.join(__dirname, "..", "app", "data");
const sourceUrl = process.argv[4] || "https://geo.statcan.gc.ca/nrn_rrn/ns/nrn_rrn_ns_GPKG.zip";
const OUT_BASENAME = "nrn-road-backbone";

if (!inputPath) {
  console.error("Usage: node scripts/pack-nrn-road-backbone.js <input.geojsonseq> [outDir] [sourceUrl]");
  process.exit(1);
}

function value(v) {
  return v == null ? "" : String(v).trim();
}

function known(v) {
  const s = value(v);
  return s && !/^unknown$/i.test(s) && !/^none$/i.test(s);
}

function firstKnown(...values) {
  return values.find(known) || "";
}

function classify(props) {
  const pavStatus = value(props.PAVSTATUS);
  const pavSurf = value(props.PAVSURF);
  const unpavSurf = value(props.UNPAVSURF);
  const roadClass = value(props.ROADCLASS);

  if (/unpaved|gravel|earth|dirt/i.test(`${pavStatus} ${unpavSurf}`)) {
    return { trackClass: "gravel", confidence: "pavement-field" };
  }
  if (/paved|asphalt|concrete/i.test(`${pavStatus} ${pavSurf}`)) {
    return { trackClass: "paved", confidence: "pavement-field" };
  }
  if (/resource|recreation/i.test(roadClass)) {
    return { trackClass: "gravel", confidence: "roadclass-inferred" };
  }
  return { trackClass: "paved", confidence: "roadclass-inferred" };
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

function roundGeom(g) {
  if (!g) return null;
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

function featureFromNrn(feature) {
  const geometry = roundGeom(feature.geometry);
  if (!geometry) return null;
  const props = feature.properties || {};
  const classification = classify(props);
  if (classification.trackClass === "paved") return null;
  const roadClass = value(props.ROADCLASS);
  const pavStatus = value(props.PAVSTATUS);
  const pavSurf = value(props.PAVSURF);
  const unpavSurf = value(props.UNPAVSURF);
  const name = firstKnown(props.STRUNAMEEN, props.R_STNAME_C, props.L_STNAME_C, props.RTENAME1EN);
  const routeNumber = firstKnown(props.RTNUMBER1);
  const id = firstKnown(props.NID, props.ROADSEGID, feature.id);

  const properties = {
    id,
    source: "NRN",
    dataSource: "nrn",
    trackClass: classification.trackClass,
    surfaceConfidence: classification.confidence,
    roadClass,
    pavementStatus: pavStatus,
    pavedSurface: pavSurf,
    unpavedSurface: unpavSurf
  };

  if (name) properties.name = name;
  if (routeNumber && routeNumber !== "0") properties.routeNumber = routeNumber;
  for (const [from, to] of [
    ["ROADSEGID", "roadSegmentId"],
    ["ROADJURIS", "jurisdiction"],
    ["PROVIDER", "provider"],
    ["NBRLANES", "lanes"],
    ["SPEED", "speed"],
    ["TRAFFICDIR", "trafficDirection"]
  ]) {
    if (known(props[from])) properties[to] = props[from];
  }

  return { type: "Feature", properties, geometry };
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
    try {
      const feature = featureFromNrn(JSON.parse(line));
      if (feature) features.push(feature);
      else skipped += 1;
    } catch {
      skipped += 1;
    }
  }

  const classes = features.reduce((acc, feature) => {
    acc[feature.properties.trackClass] = (acc[feature.properties.trackClass] || 0) + 1;
    return acc;
  }, {});
  const confidence = features.reduce((acc, feature) => {
    acc[feature.properties.surfaceConfidence] = (acc[feature.properties.surfaceConfidence] || 0) + 1;
    return acc;
  }, {});
  const roadClasses = features.reduce((acc, feature) => {
    const key = feature.properties.roadClass || "Unknown";
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
    sourceName: "National Road Network gravel/resource roads",
    source: sourceUrl,
    license: "Open Government Licence - Canada",
    region: "Nova Scotia",
    featureCount: features.length,
    skipped,
    bytes: Buffer.byteLength(json),
    gzBytes: fs.statSync(gzPath).size,
    classes,
    surfaceConfidence: confidence,
    roadClasses
  };
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  console.log(JSON.stringify(meta, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
