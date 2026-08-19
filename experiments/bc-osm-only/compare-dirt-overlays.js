#!/usr/bin/env node
"use strict";

/**
 * OSM dirt vs one provincial overlay at a time (DRA, then FTEN).
 *
 * Overlay dirt only: forestry / resource / trail (ATV-ish). No highway→ancillary.
 * A vertex/sample is "already in OSM" if it sits within MATCH_M of OSM dirt.
 *
 * Usage:
 *   node experiments/bc-osm-only/compare-dirt-overlays.js
 */

const fs = require("fs");
const path = require("path");
const readline = require("readline");
const https = require("https");
const http = require("http");
const {
  decodeGraphV2,
  decodeGeometryV1,
  unpackSurface,
  unpackRoadClass,
  ROAD_CLASS_NAME
} = require("../../scripts/pack-fabric/routing/lib/pack-v2");

const OSM_GRAPH = path.resolve(
  __dirname,
  "../../scripts/pack-fabric/app/data/packs/v1/bc/graph.v2.bin"
);
const OSM_GEOM = path.resolve(
  __dirname,
  "../../scripts/pack-fabric/app/data/packs/v1/bc/geometry.v1.bin"
);
const DRA_SEQ =
  "/Users/richardsmith/Documents/Mayday/data-raw/bc-dra/capillary.geojsonseq";
const FTEN_PACK_GRAPH =
  "/Users/richardsmith/Documents/Mayday/routing/data/regions/bc.pre-osm-adventure/graph.v2.bin";
const FTEN_PACK_GEOM =
  "/Users/richardsmith/Documents/Mayday/routing/data/regions/bc.pre-osm-adventure/geometry.v1.bin";

const SURFACE_NAME = ["paved", "gravel", "access", "track", "unknown"];
const MATCH_M = 50;
const SAMPLE_M = 25;
const CELL = 40; // ~40 m at 1e5 lon/lat units
const THRESHOLD = 0.10;

const DRA_KEEP = new Set(["resource", "trail"]);
const DRA_SKIP_SURFACE = /paved|asphalt|concrete|seal/;
const HIGHWAY_ROADS = new Set([
  "freeway",
  "arterial",
  "ramp",
  "collector",
  "service"
]);

function haversine(aLat, aLon, bLat, bLon) {
  const R = 6371000;
  const dLat = ((bLat - aLat) * Math.PI) / 180;
  const dLon = ((bLon - aLon) * Math.PI) / 180;
  const s1 = Math.sin(dLat / 2);
  const s2 = Math.sin(dLon / 2);
  const h =
    s1 * s1 + Math.cos((aLat * Math.PI) / 180) * Math.cos((bLat * Math.PI) / 180) * s2 * s2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

function lineMeters(coords) {
  let total = 0;
  for (let i = 1; i < coords.length; i += 1) {
    total += haversine(coords[i - 1][1], coords[i - 1][0], coords[i][1], coords[i][0]);
  }
  return total;
}

function riderPaintSurface(surface, road) {
  if (surface === "paved") return "paved";
  if (surface === "unknown") {
    if (
      road === "freeway" ||
      road === "arterial" ||
      road === "ramp" ||
      road === "collector" ||
      road === "local" ||
      road === "service"
    ) {
      return "paved";
    }
  }
  return surface;
}

function isAdventurePaint(surface) {
  return (
    surface === "gravel" ||
    surface === "access" ||
    surface === "resource" ||
    surface === "track" ||
    surface === "double_track" ||
    surface === "unpaved" ||
    surface === "dirt"
  );
}

/** Dual-sport dirt OSM already owns — not city service / sealed highway. */
function isOsmDirt(surface, road) {
  const paint = riderPaintSurface(surface, road);
  if (paint === "paved") return false;
  if (road === "track" || road === "double_track" || road === "resource" || road === "recreation") {
    return true;
  }
  if (isAdventurePaint(paint) && !HIGHWAY_ROADS.has(road)) return true;
  return false;
}

function cellKey(lonE5, latE5) {
  const gx = Math.floor(lonE5 / CELL);
  const gy = Math.floor(latE5 / CELL);
  return gx * 1000000 + gy;
}

function buildIndex() {
  const cells = new Map();
  function add(lon, lat) {
    const lonE5 = Math.round(lon * 1e5);
    const latE5 = Math.round(lat * 1e5);
    const key = cellKey(lonE5, latE5);
    let arr = cells.get(key);
    if (!arr) {
      arr = [];
      cells.set(key, arr);
    }
    arr.push(lonE5, latE5);
  }
  function near(lon, lat) {
    const lonE5 = Math.round(lon * 1e5);
    const latE5 = Math.round(lat * 1e5);
    const gx = Math.floor(lonE5 / CELL);
    const gy = Math.floor(latE5 / CELL);
    for (let dx = -1; dx <= 1; dx += 1) {
      for (let dy = -1; dy <= 1; dy += 1) {
        const arr = cells.get((gx + dx) * 1000000 + (gy + dy));
        if (!arr) continue;
        for (let i = 0; i < arr.length; i += 2) {
          const dlon = (arr[i] - lonE5) / 1e5;
          const dlat = (arr[i + 1] - latE5) / 1e5;
          const m = Math.hypot(dlon * 78000, dlat * 111320);
          if (m <= MATCH_M) return true;
        }
      }
    }
    return false;
  }
  return { add, near, cells };
}

function sampleLine(coords, stepM) {
  const out = [];
  if (!coords || coords.length < 2) return out;
  out.push(coords[0]);
  let leftover = 0;
  for (let i = 1; i < coords.length; i += 1) {
    const a = coords[i - 1];
    const b = coords[i];
    const seg = haversine(a[1], a[0], b[1], b[0]);
    if (seg < 1e-6) continue;
    let dist = leftover;
    while (dist + stepM <= seg) {
      dist += stepM;
      const t = dist / seg;
      out.push([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]);
    }
    leftover = seg - dist;
  }
  out.push(coords[coords.length - 1]);
  return out;
}

function emptyStats() {
  return {
    features: 0,
    skipped: 0,
    skipReasons: {},
    km: 0,
    vertices: 0,
    uniqueKm: 0,
    overlapKm: 0,
    uniqueVertices: 0,
    overlapVertices: 0,
    byClass: {}
  };
}

function bump(map, key, n = 1) {
  map[key] = (map[key] || 0) + n;
}

function scoreLine(stats, index, coords, className) {
  const km = lineMeters(coords) / 1000;
  const samples = sampleLine(coords, SAMPLE_M);
  let uniqueM = 0;
  let overlapM = 0;
  let uniqueV = 0;
  let overlapV = 0;
  for (let i = 0; i < samples.length; i += 1) {
    const hit = index.near(samples[i][0], samples[i][1]);
    const m =
      i === 0
        ? 0
        : haversine(samples[i - 1][1], samples[i - 1][0], samples[i][1], samples[i][0]);
    if (hit) {
      overlapM += m;
      overlapV += 1;
    } else {
      uniqueM += m;
      uniqueV += 1;
    }
  }
  stats.features += 1;
  stats.km += km;
  stats.vertices += samples.length;
  stats.uniqueKm += uniqueM / 1000;
  stats.overlapKm += overlapM / 1000;
  stats.uniqueVertices += uniqueV;
  stats.overlapVertices += overlapV;
  if (!stats.byClass[className]) {
    stats.byClass[className] = { features: 0, km: 0, uniqueKm: 0 };
  }
  stats.byClass[className].features += 1;
  stats.byClass[className].km += km;
  stats.byClass[className].uniqueKm += uniqueM / 1000;
}

function normalizeLine(raw) {
  const out = [];
  for (const c of raw || []) {
    if (!Array.isArray(c) || c.length < 2) continue;
    const lon = Number(c[0]);
    const lat = Number(c[1]);
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) continue;
    if (Math.abs(lon) > 180 || Math.abs(lat) > 90) continue;
    const last = out[out.length - 1];
    if (last && last[0] === lon && last[1] === lat) continue;
    out.push([lon, lat]);
  }
  return out;
}

function geometryParts(geometry) {
  if (!geometry) return [];
  if (geometry.type === "LineString") {
    const line = normalizeLine(geometry.coordinates);
    return line.length >= 2 ? [line] : [];
  }
  if (geometry.type === "MultiLineString") {
    return geometry.coordinates.map(normalizeLine).filter((c) => c.length >= 2);
  }
  return [];
}

async function loadOsmDirt() {
  const graph = decodeGraphV2(fs.readFileSync(OSM_GRAPH));
  const geom = decodeGeometryV1(fs.readFileSync(OSM_GEOM));
  const index = buildIndex();
  const stats = {
    edges: graph.undirectedEdgeCount,
    dirtEdges: 0,
    dirtKm: 0,
    dirtVertices: 0,
    byRoad: {},
    bySurface: {}
  };
  for (let ei = 0; ei < graph.undirectedEdgeCount; ei += 1) {
    const surface = SURFACE_NAME[unpackSurface(graph.edgeAttrs[ei])] || "unknown";
    const road = ROAD_CLASS_NAME[unpackRoadClass(graph.edgeAttrs[ei])] || "unknown";
    if (!isOsmDirt(surface, road)) continue;
    const coords = geom.polyline(ei);
    if (coords.length < 2) continue;
    stats.dirtEdges += 1;
    stats.dirtKm += (graph.edgeMeters[ei] || lineMeters(coords)) / 1000;
    bump(stats.byRoad, road);
    bump(stats.bySurface, surface);
    for (const c of coords) {
      index.add(c[0], c[1]);
      stats.dirtVertices += 1;
    }
  }
  return { index, stats };
}

async function compareDra(index) {
  const stats = emptyStats();
  const rl = readline.createInterface({
    input: fs.createReadStream(DRA_SEQ, { encoding: "utf8" }),
    crlfDelay: Infinity
  });
  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let row;
    try {
      row = JSON.parse(trimmed);
    } catch {
      bump(stats.skipReasons, "bad_json");
      stats.skipped += 1;
      continue;
    }
    const p = row.properties || {};
    const roadClass = String(p.RD_CLASS || p.ROAD_CLASS || "").toLowerCase().trim();
    const surface = String(p.RD_SURFACE || p.ROAD_SURFACE || "").toLowerCase().trim();
    if (!DRA_KEEP.has(roadClass)) {
      bump(stats.skipReasons, "not_forestry_or_trail");
      stats.skipped += 1;
      continue;
    }
    if (DRA_SKIP_SURFACE.test(surface)) {
      bump(stats.skipReasons, "paved_surface");
      stats.skipped += 1;
      continue;
    }
    const parts = geometryParts(row.geometry);
    if (!parts.length) {
      bump(stats.skipReasons, "no_geometry");
      stats.skipped += 1;
      continue;
    }
    for (const coords of parts) scoreLine(stats, index, coords, roadClass);
  }
  return stats;
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith("https") ? https : http;
    const req = lib.get(url, (res) => {
      if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        fetchJson(res.headers.location).then(resolve, reject);
        return;
      }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        if (res.statusCode !== 200 || text.trimStart().startsWith("<")) {
          reject(new Error("WFS HTTP " + res.statusCode + ": " + text.slice(0, 200)));
          return;
        }
        try {
          resolve(JSON.parse(text));
        } catch (err) {
          reject(err);
        }
      });
    });
    req.setTimeout(180000, () => req.destroy(new Error("WFS timeout")));
    req.on("error", reject);
  });
}

async function compareFtenWfs(index) {
  const stats = emptyStats();
  const pageSize = 2000;
  let startIndex = 0;
  const TYPE_NAME = "WHSE_FOREST_TENURE.FTEN_ROAD_SECTION_LINES_SVW";
  for (;;) {
    const u = new URL("https://openmaps.gov.bc.ca/geo/pub/ows");
    u.searchParams.set("service", "WFS");
    u.searchParams.set("version", "2.0.0");
    u.searchParams.set("request", "GetFeature");
    u.searchParams.set("typeName", TYPE_NAME);
    u.searchParams.set("outputFormat", "json");
    u.searchParams.set("srsName", "EPSG:4326");
    u.searchParams.set("count", String(pageSize));
    u.searchParams.set("sortBy", "ROAD_SECTION_ID");
    if (startIndex > 0) u.searchParams.set("startIndex", String(startIndex));
    let fc = null;
    for (let attempt = 0; attempt < 4; attempt += 1) {
      try {
        fc = await fetchJson(u.toString());
        break;
      } catch (err) {
        if (attempt === 3) throw err;
        await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
      }
    }
    const rows = (fc && fc.features) || [];
    if (!rows.length) break;
    for (const row of rows) {
      const props = row.properties || {};
      const life = String(props.LIFE_CYCLE_STATUS_CODE || props.FILE_STATUS_CODE || "").toUpperCase();
      if (
        ["RETIRED", "DEACTIVATED", "CANCELLED", "PENDING", "PROPOSED", "APPLICATION"].includes(life) ||
        props.RETIREMENT_DATE
      ) {
        bump(stats.skipReasons, life || "retired");
        stats.skipped += 1;
        continue;
      }
      const parts = geometryParts(row.geometry);
      if (!parts.length) {
        bump(stats.skipReasons, "no_geometry");
        stats.skipped += 1;
        continue;
      }
      for (const coords of parts) scoreLine(stats, index, coords, "ften_resource");
    }
    process.stderr.write(`[ften] start=${startIndex} kept=${stats.features} skipped=${stats.skipped}\n`);
    if (rows.length < pageSize) break;
    startIndex += rows.length;
    if (startIndex > 400000) break;
  }
  return stats;
}

function compareFtenFromPack(index) {
  const stats = emptyStats();
  const graph = decodeGraphV2(fs.readFileSync(FTEN_PACK_GRAPH));
  const geom = decodeGeometryV1(fs.readFileSync(FTEN_PACK_GEOM));
  for (let ei = 0; ei < graph.undirectedEdgeCount; ei += 1) {
    const id = graph.edgeId(ei);
    if (!id.startsWith("bc-ften-")) continue;
    const coords = geom.polyline(ei);
    if (coords.length < 2) {
      bump(stats.skipReasons, "no_geometry");
      stats.skipped += 1;
      continue;
    }
    scoreLine(stats, index, coords, "ften_resource");
  }
  return stats;
}

function round(n, d = 1) {
  const p = 10 ** d;
  return Math.round(n * p) / p;
}

function verdict(osmDirtVertices, uniqueVertices, osmDirtKm, uniqueKm) {
  const vertexLift = osmDirtVertices > 0 ? uniqueVertices / osmDirtVertices : 0;
  const kmLift = osmDirtKm > 0 ? uniqueKm / osmDirtKm : 0;
  return {
    vertexLiftPct: round(vertexLift * 100, 1),
    kmLiftPct: round(kmLift * 100, 1),
    pass10: vertexLift >= THRESHOLD || kmLift >= THRESHOLD,
    recommend: vertexLift >= THRESHOLD || kmLift >= THRESHOLD ? "consider" : "skip"
  };
}

async function main() {
  console.error("[1/4] Indexing OSM dirt from current BC pack…");
  const osm = await loadOsmDirt();
  console.error(
    `[osm] edges=${osm.stats.edges} dirtEdges=${osm.stats.dirtEdges} dirtKm=${osm.stats.dirtKm.toFixed(0)} dirtVertices=${osm.stats.dirtVertices}`
  );

  console.error("[2/4] DRA resource+trail vs OSM dirt…");
  const dra = await compareDra(osm.index);
  console.error(
    `[dra] features=${dra.features} km=${dra.km.toFixed(0)} uniqueKm=${dra.uniqueKm.toFixed(0)} uniqueV=${dra.uniqueVertices}`
  );

  let ften = null;
  let ftenSource = "pack-pre-osm-adventure";
  if (process.argv.includes("--wfs")) {
    console.error("[3/4] FTEN active tenure vs OSM dirt (WFS)…");
    try {
      ften = await compareFtenWfs(osm.index);
      ftenSource = "wfs";
    } catch (err) {
      console.error("[ften] WFS failed:", err.message, "— falling back to packed FTEN edges");
      ften = compareFtenFromPack(osm.index);
    }
  } else {
    console.error("[3/4] FTEN vs OSM dirt from packed bc-ften-* edges (OSM+DRA-conflated keepers)…");
    ften = compareFtenFromPack(osm.index);
  }
  console.error(
    `[ften] source=${ftenSource} features=${ften.features} km=${ften.km.toFixed(0)} uniqueKm=${ften.uniqueKm.toFixed(0)} uniqueV=${ften.uniqueVertices}`
  );

  const out = {
    generatedAt: new Date().toISOString(),
    matchMeters: MATCH_M,
    sampleMeters: SAMPLE_M,
    thresholdPct: THRESHOLD * 100,
    osm: {
      pack: OSM_GRAPH,
      ...osm.stats,
      dirtKm: round(osm.stats.dirtKm, 1)
    },
    dra: {
      source: "BC Digital Road Atlas (RD_CLASS resource + trail, unpaved only)",
      file: DRA_SEQ,
      ...dra,
      km: round(dra.km, 1),
      uniqueKm: round(dra.uniqueKm, 1),
      overlapKm: round(dra.overlapKm, 1),
      verdict: verdict(osm.stats.dirtVertices, dra.uniqueVertices, osm.stats.dirtKm, dra.uniqueKm)
    },
    ften: {
      source: "BC Forest Tenure Road Section Lines (active only)",
      loadedFrom: ftenSource,
      ...ften,
      km: round(ften.km, 1),
      uniqueKm: round(ften.uniqueKm, 1),
      overlapKm: round(ften.overlapKm, 1),
      verdict: verdict(osm.stats.dirtVertices, ften.uniqueVertices, osm.stats.dirtKm, ften.uniqueKm)
    }
  };
  const outPath = path.join(__dirname, "dirt-overlay-compare.json");
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
  console.log(JSON.stringify(out, null, 2));
  console.error("Wrote", outPath);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
