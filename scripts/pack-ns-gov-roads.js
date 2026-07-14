#!/usr/bin/env node
/**
 * Pack Nova Scotia government NSTDB road-line features into a DIRT overlay.
 *
 * NSTDB feature descriptions become first-class DIRT categories for the
 * Nova Scotia POC.
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const outDir = process.argv[2] || path.join(__dirname, "..", "app", "data");
const sourceUrl = process.argv[3] || "https://data.novascotia.ca/resource/a6gf-w68e.json";
const OUT_BASENAME = "ns-gov-roads";
const PAGE_SIZE = Number(process.env.NS_GOV_PAGE_SIZE || 50000);
const WHERE = [
  "feat_desc like '%Unpaved%'",
  "feat_desc='TRACK'",
  "feat_desc='TRACK - Indefinite/Approximate'",
  "feat_desc='BRIDGE - Track'",
  "feat_desc='TUNNEL - Track'",
  "feat_desc='ROAD - Abandoned - TRACK'",
  "feat_desc like 'TRAIL%'"
].join(" OR ");

function value(v) {
  return v == null ? "" : String(v).trim();
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

function roundGeom(g) {
  if (!g || !["LineString", "MultiLineString"].includes(g.type)) return null;
  if (g.type === "LineString") {
    return { type: "LineString", coordinates: g.coordinates.map(roundCoord) };
  }
  return {
    type: "MultiLineString",
    coordinates: g.coordinates.map((line) => line.map(roundCoord))
  };
}

function classify(props) {
  const desc = value(props.feat_desc);
  if (/Railroad|Ferry|Driveway|Median Crossover|Service Lane|Ramp|Dam/i.test(desc)) {
    return null;
  }
  if (/\bPaved\b/i.test(desc) && !/\bUnpaved\b/i.test(desc)) {
    return null;
  }
  if (/Trail/i.test(desc)) {
    return { trackClass: "single", confidence: "nstdb-trail" };
  }
  if (/Bridge/i.test(desc)) {
    return { trackClass: "bridge", confidence: "nstdb-structure" };
  }
  if (/Tunnel/i.test(desc)) {
    return { trackClass: "tunnel", confidence: "nstdb-structure" };
  }
  if (/Abandoned/i.test(desc)) {
    return { trackClass: "unserviced", confidence: "nstdb-abandoned" };
  }
  if (/Resource Access/i.test(desc)) {
    return { trackClass: "access", confidence: /Dry Weather/i.test(desc) ? "nstdb-dry-weather-resource-access" : "nstdb-resource-access" };
  }
  if (/Track/i.test(desc) || desc === "TRACK") {
    return { trackClass: "track", confidence: /Indefinite|Approximate/i.test(desc) ? "nstdb-approximate-track" : "nstdb-track" };
  }
  if (/Unpaved/i.test(desc)) {
    return { trackClass: "gravel", confidence: "nstdb-unpaved" };
  }
  return null;
}

function featureFromRow(row, index) {
  const classification = classify(row);
  if (!classification) return null;
  const geometry = roundGeom(row.the_geom);
  if (!geometry) return null;
  const name = value(row.name);
  const rteNo = value(row.rte_no);
  const shapeLen = Number(row.shape_len);
  const idParts = [row.feat_code, name, rteNo, index].map(value).filter(Boolean);

  const properties = {
    id: `ns-gov-${idParts.join("-") || index}`,
    source: "NS Government",
    dataSource: "ns-gov",
    trackClass: classification.trackClass,
    surfaceConfidence: classification.confidence,
    roadClass: value(row.feat_desc),
    featCode: value(row.feat_code),
    accessStatus: "unknown",
    accessDetail: "motorized access not explicit in NSTDB road-line layer"
  };
  if (name) properties.name = name;
  if (rteNo && rteNo !== "0") properties.routeNumber = rteNo;
  if (Number.isFinite(shapeLen)) properties.lengthMeters = Math.round(shapeLen);
  return { type: "Feature", properties, geometry };
}

async function fetchRows(offset) {
  const url = new URL(sourceUrl);
  url.searchParams.set("$limit", String(PAGE_SIZE));
  url.searchParams.set("$offset", String(offset));
  url.searchParams.set("$where", WHERE);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return res.json();
}

async function main() {
  const features = [];
  let skipped = 0;
  let fetched = 0;
  const sourceDescriptions = {};

  for (let offset = 0; ; offset += PAGE_SIZE) {
    const rows = await fetchRows(offset);
    if (!rows.length) break;
    fetched += rows.length;
    console.log(`Fetched ${fetched.toLocaleString()} NSTDB candidate rows`);

    for (const row of rows) {
      const desc = value(row.feat_desc) || "Unknown";
      sourceDescriptions[desc] = (sourceDescriptions[desc] || 0) + 1;
      const feature = featureFromRow(row, fetched + features.length);
      if (feature) features.push(feature);
      else skipped += 1;
    }

    if (rows.length < PAGE_SIZE) break;
  }

  const classes = features.reduce((acc, feature) => {
    const key = feature.properties.trackClass;
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});
  const confidence = features.reduce((acc, feature) => {
    const key = feature.properties.surfaceConfidence;
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
    sourceName: "Nova Scotia Topographic DataBase Roads, Trails and Rails - Road Line Layer",
    source: sourceUrl,
    catalogue: "https://data.novascotia.ca/Roads-Driving-and-Transport/Nova-Scotia-Topographic-DataBase-Roads-Trails-and-/a6gf-w68e",
    queryModel: "NSTDB Road Line Layer filtered to Unpaved, TRACK, and TRAIL feature descriptions; paved/driveway/ferry/rail excluded",
    license: "Open Government Licence - Nova Scotia",
    region: "Nova Scotia",
    featureCount: features.length,
    fetched,
    skipped,
    bytes: Buffer.byteLength(json),
    gzBytes: fs.statSync(gzPath).size,
    classes,
    surfaceConfidence: confidence,
    sourceDescriptions,
    limitations: [
      "NSTDB trail records do not explicitly validate motorized access; they are displayed as single track for visual comparison.",
      "TRACK records are normalized to Track, including indefinite/approximate track records."
    ]
  };
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  console.log(JSON.stringify(meta, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
