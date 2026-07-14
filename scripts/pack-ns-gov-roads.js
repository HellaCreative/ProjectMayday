#!/usr/bin/env node
/**
 * Pack Nova Scotia government NSTDB road-line features into a DIRT overlay
 * with routable topology.
 *
 * What this build does beyond the raw fetch:
 * 1. Includes PAVED roads as a first-class "paved" class so dirt segments can
 *    legally connect through the road network (same dataset, same vertices).
 * 2. Splits every line at vertices shared with any other line (exact 0 m
 *    coordinate match after 1e-5 rounding). No tolerance snapping, no gap
 *    bridging: junctions must already exist in the data.
 * 3. Tags every output segment with a connected-component id so the app can
 *    explain routing failures ("A and B are on different networks").
 *
 * Env:
 *   NS_GOV_BBOX="W,S,E,N"   optional clip (Socrata intersects filter)
 *   NS_GOV_REGION="label"   region label recorded in meta
 *   NS_GOV_PAGE_SIZE        Socrata page size (default 50000)
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const outDir = process.argv[2] || path.join(__dirname, "..", "app", "data");
const sourceUrl = process.argv[3] || "https://data.novascotia.ca/resource/a6gf-w68e.json";
const OUT_BASENAME = "ns-gov-roads";
const PAGE_SIZE = Number(process.env.NS_GOV_PAGE_SIZE || 50000);
const BBOX = (process.env.NS_GOV_BBOX || "").split(",").map(Number).filter((n) => Number.isFinite(n));
const REGION = process.env.NS_GOV_REGION || (BBOX.length === 4 ? "Custom bbox" : "Nova Scotia");

const DESC_FILTER = [
  "feat_desc like '%Unpaved%'",
  "feat_desc like '%Paved%'",
  "feat_desc='TRACK'",
  "feat_desc='TRACK - Indefinite/Approximate'",
  "feat_desc='BRIDGE - Track'",
  "feat_desc='TUNNEL - Track'",
  "feat_desc='ROAD - Abandoned - TRACK'",
  "feat_desc like 'TRAIL%'"
].join(" OR ");

function buildWhere() {
  if (BBOX.length !== 4) return `(${DESC_FILTER})`;
  const [w, s, e, n] = BBOX;
  const poly = `POLYGON((${w} ${s},${e} ${s},${e} ${n},${w} ${n},${w} ${s}))`;
  return `intersects(the_geom, '${poly}') AND (${DESC_FILTER})`;
}

function value(v) {
  return v == null ? "" : String(v).trim();
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

function classify(props) {
  const desc = value(props.feat_desc);
  if (/Railroad|Ferry|Driveway|Median Crossover|Service Lane|Ramp|Dam/i.test(desc)) {
    return null;
  }
  if (/\bPaved\b/i.test(desc) && !/\bUnpaved\b/i.test(desc)) {
    return { trackClass: "paved", confidence: "nstdb-paved" };
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

function vertexKey(c) {
  return c[0] + "," + c[1];
}

function haversineMeters(a, b) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const r = 6371000;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function lineMeters(coords) {
  let total = 0;
  for (let i = 1; i < coords.length; i += 1) total += haversineMeters(coords[i - 1], coords[i]);
  return total;
}

/** Round, and drop consecutive duplicate vertices introduced by rounding. */
function normalizeLine(coords) {
  const out = [];
  for (const raw of coords) {
    const c = roundCoord(raw);
    const last = out[out.length - 1];
    if (last && last[0] === c[0] && last[1] === c[1]) continue;
    out.push(c);
  }
  return out;
}

function rowToParts(row) {
  const g = row.the_geom;
  if (!g || !["LineString", "MultiLineString"].includes(g.type)) return [];
  const rawParts = g.type === "LineString" ? [g.coordinates] : g.coordinates;
  return rawParts.map(normalizeLine).filter((coords) => coords.length >= 2);
}

async function fetchRows(offset) {
  const url = new URL(sourceUrl);
  url.searchParams.set("$limit", String(PAGE_SIZE));
  url.searchParams.set("$offset", String(offset));
  url.searchParams.set("$where", buildWhere());
  url.searchParams.set("$order", ":id");
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return res.json();
}

async function main() {
  // ---- 1. Fetch + classify ------------------------------------------------
  const lines = []; // { coords, props }
  let fetched = 0;
  let skipped = 0;
  const sourceDescriptions = {};

  for (let offset = 0; ; offset += PAGE_SIZE) {
    const rows = await fetchRows(offset);
    if (!rows.length) break;
    fetched += rows.length;
    console.log(`Fetched ${fetched.toLocaleString()} NSTDB candidate rows`);

    for (const row of rows) {
      const desc = value(row.feat_desc) || "Unknown";
      sourceDescriptions[desc] = (sourceDescriptions[desc] || 0) + 1;
      const classification = classify(row);
      if (!classification) {
        skipped += 1;
        continue;
      }
      const parts = rowToParts(row);
      if (!parts.length) {
        skipped += 1;
        continue;
      }
      // Keep properties minimal: constant strings (source, access notes)
      // are synthesized in the app instead of repeated 300k times.
      const name = value(row.name);
      const props = {
        trackClass: classification.trackClass,
        surfaceConfidence: classification.confidence,
        roadClass: value(row.feat_desc)
      };
      if (name) props.name = name;
      for (const coords of parts) lines.push({ coords, props });
    }

    if (rows.length < PAGE_SIZE) break;
  }

  console.log(`Classified ${lines.length.toLocaleString()} line parts (${skipped.toLocaleString()} rows skipped)`);

  // ---- 2. Count vertex usage across all lines ------------------------------
  // A vertex used by 2+ lines (or twice by intersecting geometry) is a real,
  // in-data junction. Exact match only: the dataset is pre-rounded to 1e-5.
  const vertexUse = new Map();
  for (const line of lines) {
    for (const c of line.coords) {
      const key = vertexKey(c);
      vertexUse.set(key, (vertexUse.get(key) || 0) + 1);
    }
  }

  // ---- 3. Split every line at shared interior vertices ---------------------
  const segments = []; // { coords, props, meters }
  let splitCount = 0;
  for (const line of lines) {
    const coords = line.coords;
    let start = 0;
    for (let i = 1; i < coords.length; i += 1) {
      const isLast = i === coords.length - 1;
      const isJunction = !isLast && (vertexUse.get(vertexKey(coords[i])) || 0) >= 2;
      if (isJunction || isLast) {
        const piece = coords.slice(start, i + 1);
        if (piece.length >= 2) {
          segments.push({ coords: piece, props: line.props, meters: lineMeters(piece) });
        }
        if (isJunction) splitCount += 1;
        start = i;
      }
    }
  }

  console.log(`Split ${lines.length.toLocaleString()} lines into ${segments.length.toLocaleString()} segments (${splitCount.toLocaleString()} junction splits)`);

  // ---- 4. Connected components over segment endpoints ----------------------
  const nodeIds = new Map();
  function nodeId(c) {
    const key = vertexKey(c);
    let id = nodeIds.get(key);
    if (id == null) {
      id = nodeIds.size;
      nodeIds.set(key, id);
    }
    return id;
  }
  const parent = [];
  function find(x) {
    while (parent[x] !== x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }
  function union(a, b) {
    a = find(a);
    b = find(b);
    if (a !== b) parent[b] = a;
  }
  const segmentNodes = segments.map((segment) => {
    const a = nodeId(segment.coords[0]);
    const b = nodeId(segment.coords[segment.coords.length - 1]);
    while (parent.length < nodeIds.size) parent.push(parent.length);
    union(a, b);
    return [a, b];
  });

  const componentMeters = new Map();
  const componentCounts = new Map();
  segments.forEach((segment, i) => {
    const root = find(segmentNodes[i][0]);
    componentMeters.set(root, (componentMeters.get(root) || 0) + segment.meters);
    componentCounts.set(root, (componentCounts.get(root) || 0) + 1);
  });
  const rankedRoots = [...componentMeters.entries()].sort((a, b) => b[1] - a[1]).map(([root]) => root);
  const componentRank = new Map(rankedRoots.map((root, rank) => [root, rank]));

  // ---- 5. Junction stats ----------------------------------------------------
  const degree = new Map();
  for (const [a, b] of segmentNodes) {
    degree.set(a, (degree.get(a) || 0) + 1);
    degree.set(b, (degree.get(b) || 0) + 1);
  }
  let junctions = 0;
  let deadEnds = 0;
  for (const d of degree.values()) {
    if (d >= 3) junctions += 1;
    else if (d === 1) deadEnds += 1;
  }

  // ---- 6. Emit as grid chunks ----------------------------------------------
  // iOS Safari kills pages that parse the whole province at once, so the
  // output is a manifest plus ~0.4 degree grid chunks the app loads on demand.
  const CHUNK_DEG = Number(process.env.NS_GOV_CHUNK_DEG || 0.4);

  const features = segments.map((segment, i) => ({
    type: "Feature",
    properties: {
      ...segment.props,
      lengthMeters: Math.round(segment.meters),
      componentId: componentRank.get(find(segmentNodes[i][0]))
    },
    geometry: { type: "LineString", coordinates: segment.coords }
  }));

  const classes = features.reduce((acc, feature) => {
    const key = feature.properties.trackClass;
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});

  const chunkMap = new Map();
  for (const feature of features) {
    const first = feature.geometry.coordinates[0];
    const cx = Math.floor(first[0] / CHUNK_DEG);
    const cy = Math.floor(first[1] / CHUNK_DEG);
    const id = cx + "_" + cy;
    let chunk = chunkMap.get(id);
    if (!chunk) {
      chunk = { id, features: [], bbox: [Infinity, Infinity, -Infinity, -Infinity] };
      chunkMap.set(id, chunk);
    }
    chunk.features.push(feature);
    for (const c of feature.geometry.coordinates) {
      chunk.bbox[0] = Math.min(chunk.bbox[0], c[0]);
      chunk.bbox[1] = Math.min(chunk.bbox[1], c[1]);
      chunk.bbox[2] = Math.max(chunk.bbox[2], c[0]);
      chunk.bbox[3] = Math.max(chunk.bbox[3], c[1]);
    }
  }

  fs.mkdirSync(outDir, { recursive: true });
  const chunkDir = path.join(outDir, "ns-gov-chunks");
  fs.rmSync(chunkDir, { recursive: true, force: true });
  fs.mkdirSync(chunkDir, { recursive: true });

  const chunkIndex = [];
  let totalBytes = 0;
  let totalGzBytes = 0;
  for (const chunk of chunkMap.values()) {
    const json = JSON.stringify({ type: "FeatureCollection", features: chunk.features });
    const gz = zlib.gzipSync(Buffer.from(json), { level: 9 });
    const file = `${chunk.id}.geojson.gz`;
    fs.writeFileSync(path.join(chunkDir, file), gz);
    totalBytes += Buffer.byteLength(json);
    totalGzBytes += gz.length;
    chunkIndex.push({
      id: chunk.id,
      file,
      bbox: chunk.bbox.map((n) => Math.round(n * 1e5) / 1e5),
      count: chunk.features.length,
      gzBytes: gz.length
    });
  }
  chunkIndex.sort((a, b) => b.count - a.count);

  const manifest = {
    generatedAt: new Date().toISOString(),
    sourceName: "Nova Scotia Topographic DataBase Roads, Trails and Rails - Road Line Layer",
    source: sourceUrl,
    catalogue: "https://data.novascotia.ca/Roads-Driving-and-Transport/Nova-Scotia-Topographic-DataBase-Roads-Trails-and-/a6gf-w68e",
    queryModel: "NSTDB Road Line Layer: unpaved, track, trail, AND paved roads; split at exact shared vertices; component-tagged; grid-chunked",
    license: "Open Government Licence - Nova Scotia",
    region: REGION,
    bbox: BBOX.length === 4 ? BBOX : null,
    chunkDeg: CHUNK_DEG,
    chunkDir: "ns-gov-chunks",
    featureCount: features.length,
    sourceLines: lines.length,
    junctionSplits: splitCount,
    fetched,
    skipped,
    bytes: totalBytes,
    gzBytes: totalGzBytes,
    classes,
    topology: {
      nodes: nodeIds.size,
      junctionNodes: junctions,
      deadEndNodes: deadEnds,
      componentCount: rankedRoots.length,
      topComponentsKm: rankedRoots.slice(0, 10).map((root) => Math.round(componentMeters.get(root) / 100) / 10)
    },
    sourceDescriptions,
    limitations: [
      "NSTDB trail records do not explicitly validate motorized access; they are displayed as single track for visual comparison.",
      "TRACK records are normalized to Track, including indefinite/approximate track records.",
      "Junctions are exact shared-vertex matches only. Lines that visually touch without a shared vertex remain disconnected by design."
    ],
    chunks: chunkIndex
  };
  fs.writeFileSync(path.join(outDir, `${OUT_BASENAME}.manifest.json`), JSON.stringify(manifest, null, 2));
  console.log(JSON.stringify({ ...manifest, sourceDescriptions: "(omitted)", chunks: `${chunkIndex.length} chunks, largest ${chunkIndex[0].count} features / ${(chunkIndex[0].gzBytes / 1048576).toFixed(1)} MB gz` }, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
