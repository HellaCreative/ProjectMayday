#!/usr/bin/env node
/**
 * Phase 2A — Pack Nova Scotia NSTDB road lines into an eligible production
 * overlay with surface / structure / access separation and a topology report.
 *
 * Production pack rules (PHASE-2-BUILD-GUIDE.md):
 * - Exclude No Vehicular Traffic, trails, ramps, railways, ferries, driveways,
 *   service artifacts, and empty geometry.
 * - surfaceClass and structureType are separate fields.
 * - Every edge has accessClass, source provenance, and a stable edgeId.
 * - Split only at exact shared vertices (no proximity stitching).
 * - Raw archive written outside app/data for audit; not loaded by the client.
 *
 * Env:
 *   NS_GOV_BBOX="W,S,E,N"   optional clip
 *   NS_GOV_REGION="label"   region label
 *   NS_GOV_PAGE_SIZE        Socrata page size (default 50000)
 *   NS_GOV_CHUNK_DEG        display chunk size (default 0.4)
 *   NS_GOV_RAW_DIR          raw archive output (default ../data-raw/ns-gov)
 *   NS_GOV_SKIP_RAW=1       skip writing the raw archive
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const crypto = require("crypto");

const outDir = process.argv[2] || path.join(__dirname, "..", "app", "data");
const sourceUrl = process.argv[3] || "https://data.novascotia.ca/resource/a6gf-w68e.json";
const OUT_BASENAME = "ns-gov-roads";
const PAGE_SIZE = Number(process.env.NS_GOV_PAGE_SIZE || 50000);
const BBOX = (process.env.NS_GOV_BBOX || "").split(",").map(Number).filter((n) => Number.isFinite(n));
const REGION = process.env.NS_GOV_REGION || (BBOX.length === 4 ? "Custom bbox" : "Nova Scotia");
const RAW_DIR = process.env.NS_GOV_RAW_DIR || path.join(__dirname, "..", "data-raw", "ns-gov");
const SKIP_RAW = process.env.NS_GOV_SKIP_RAW === "1";

// Candidate rows: paved + unpaved + tracks. Trails are fetched only so they
// can be counted/excluded with an explicit reason (not put in the pack).
const DESC_FILTER = [
  "feat_desc like '%Unpaved%'",
  "feat_desc like '%Paved%'",
  "feat_desc='TRACK'",
  "feat_desc='TRACK - Indefinite/Approximate'",
  "feat_desc like 'BRIDGE%'",
  "feat_desc like 'TUNNEL%'",
  "feat_desc like 'ROAD - Abandoned%'",
  "feat_desc like 'TRAIL%'"
].join(" OR ");

const SURFACE_CLASSES = new Set(["paved", "gravel", "access", "track", "unknown"]);
const ACCESS_CLASSES = new Set([
  "motorized_verified",
  "motorized_permissive",
  "motorized_unknown",
  "motorized_restricted",
  "motorized_excluded"
]);

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

function bump(map, key, n = 1) {
  map[key] = (map[key] || 0) + n;
}

/**
 * Classify one NSTDB row into surface / structure / access, or exclude it.
 * Returns { ok:true, ...attrs } or { ok:false, reason }.
 */
function classifyRow(props) {
  const desc = value(props.feat_desc);
  if (!desc) return { ok: false, reason: "missing_feat_desc" };

  // ---- Hard exclusions ----------------------------------------------------
  if (/No Vehicular Traffic/i.test(desc)) {
    return { ok: false, reason: "no_vehicular_traffic" };
  }
  if (/\bTRAIL\b/i.test(desc)) {
    return { ok: false, reason: "non_motorized_trail" };
  }
  if (/Railroad|Railway/i.test(desc)) return { ok: false, reason: "railway" };
  if (/Ferry/i.test(desc)) return { ok: false, reason: "ferry" };
  if (/Driveway/i.test(desc)) return { ok: false, reason: "driveway" };
  if (/Median Crossover/i.test(desc)) return { ok: false, reason: "median_crossover" };
  if (/Service Lane/i.test(desc)) return { ok: false, reason: "service_lane" };
  if (/\bRAMP\b/i.test(desc)) return { ok: false, reason: "ramp" };
  if (/\bDam\b/i.test(desc)) return { ok: false, reason: "dam" };
  if (/Pedestrian|Footpath|Sidewalk/i.test(desc)) {
    return { ok: false, reason: "pedestrian_only" };
  }
  if (/Bicycle|Cycleway/i.test(desc)) return { ok: false, reason: "bicycle_only" };

  // ---- Structure (independent of surface) ---------------------------------
  let structureType = "none";
  if (/\bBRIDGE\b/i.test(desc)) structureType = "bridge";
  else if (/\bTUNNEL\b/i.test(desc)) structureType = "tunnel";
  else if (/\bFord\b/i.test(desc)) structureType = "ford";

  // ---- Surface ------------------------------------------------------------
  let surfaceClass = "unknown";
  if (/\bPaved\b/i.test(desc) && !/\bUnpaved\b/i.test(desc)) {
    surfaceClass = "paved";
  } else if (/Resource Access/i.test(desc)) {
    surfaceClass = "access";
  } else if (/\bTRACK\b/i.test(desc) || desc === "TRACK") {
    surfaceClass = "track";
  } else if (/Unpaved/i.test(desc)) {
    surfaceClass = "gravel";
  } else if (structureType !== "none") {
    // BRIDGE/TUNNEL without paved/unpaved/track cue — keep unknown surface.
    surfaceClass = "unknown";
  } else {
    return { ok: false, reason: "unclassified_description" };
  }

  // ---- Access -------------------------------------------------------------
  // NSTDB does not field-verify motorcycle legality. Government roadway /
  // resource inventory is treated as permissive; ambiguous tracks as unknown;
  // abandoned as restricted (packed for QA, not default-routed).
  let accessClass = "motorized_unknown";
  let confidence = "medium";
  if (/Abandoned/i.test(desc)) {
    accessClass = "motorized_restricted";
    confidence = "low";
  } else if (surfaceClass === "track") {
    accessClass = "motorized_unknown";
    confidence = /Indefinite|Approximate/i.test(desc) ? "low" : "medium";
  } else if (surfaceClass === "paved" || surfaceClass === "gravel" || surfaceClass === "access") {
    accessClass = "motorized_permissive";
    confidence = surfaceClass === "access" && /Dry Weather/i.test(desc) ? "medium" : "high";
  }

  if (!SURFACE_CLASSES.has(surfaceClass)) {
    return { ok: false, reason: "invalid_surface" };
  }
  if (!ACCESS_CLASSES.has(accessClass)) {
    return { ok: false, reason: "invalid_access" };
  }

  return {
    ok: true,
    surfaceClass,
    structureType,
    accessClass,
    confidence,
    sourceDescription: desc,
    seasonal: /Dry Weather|Seasonal|Winter/i.test(desc)
  };
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
    if (!Array.isArray(raw) || raw.length < 2) continue;
    const c = roundCoord(raw);
    if (!Number.isFinite(c[0]) || !Number.isFinite(c[1])) continue;
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

function sourceRecordId(row, fallback) {
  const id = value(row[":id"] || row.objectid || row.id || row.fid);
  return id || fallback;
}

function makeEdgeId(recordId, partIndex, segIndex, coords) {
  const seed = recordId + "|" + partIndex + "|" + segIndex + "|" +
    coords[0].join(",") + "|" + coords[coords.length - 1].join(",");
  const hash = crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
  return "ns-gov-" + hash;
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
  const lines = [];
  const rawFeatures = [];
  let fetched = 0;
  const excludedByReason = {};
  const sourceDescriptions = {};
  const accessCounts = {};
  const surfaceCounts = {};
  const structureCounts = {};

  for (let offset = 0; ; offset += PAGE_SIZE) {
    const rows = await fetchRows(offset);
    if (!rows.length) break;
    fetched += rows.length;
    console.log(`Fetched ${fetched.toLocaleString()} NSTDB candidate rows`);

    for (let rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
      const row = rows[rowIndex];
      const desc = value(row.feat_desc) || "Unknown";
      bump(sourceDescriptions, desc);

      const recordId = sourceRecordId(row, "off" + offset + "i" + rowIndex);
      const classification = classifyRow(row);
      const parts = rowToParts(row);

      if (!SKIP_RAW) {
        rawFeatures.push({
          type: "Feature",
          properties: {
            sourceRecordId: recordId,
            feat_desc: desc,
            name: value(row.name) || null,
            eligible: classification.ok,
            excludeReason: classification.ok ? null : classification.reason,
            surfaceClass: classification.ok ? classification.surfaceClass : null,
            structureType: classification.ok ? classification.structureType : null,
            accessClass: classification.ok ? classification.accessClass : null
          },
          geometry: row.the_geom && ["LineString", "MultiLineString"].includes(row.the_geom.type)
            ? row.the_geom
            : null
        });
      }

      if (!classification.ok) {
        bump(excludedByReason, classification.reason);
        continue;
      }
      if (!parts.length) {
        bump(excludedByReason, "no_usable_geometry");
        continue;
      }

      bump(accessCounts, classification.accessClass);
      bump(surfaceCounts, classification.surfaceClass);
      bump(structureCounts, classification.structureType);

      const name = value(row.name);
      for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
        lines.push({
          coords: parts[partIndex],
          recordId,
          partIndex,
          name,
          surfaceClass: classification.surfaceClass,
          structureType: classification.structureType,
          accessClass: classification.accessClass,
          confidence: classification.confidence,
          sourceDescription: classification.sourceDescription,
          seasonal: classification.seasonal
        });
      }
    }

    if (rows.length < PAGE_SIZE) break;
  }

  console.log(`Eligible line parts: ${lines.length.toLocaleString()}`);

  // ---- Vertex usage + exact shared-vertex splits --------------------------
  const vertexUse = new Map();
  for (const line of lines) {
    for (const c of line.coords) {
      const key = vertexKey(c);
      vertexUse.set(key, (vertexUse.get(key) || 0) + 1);
    }
  }

  const segments = [];
  let splitCount = 0;
  for (const line of lines) {
    const coords = line.coords;
    let start = 0;
    let segIndex = 0;
    for (let i = 1; i < coords.length; i += 1) {
      const isLast = i === coords.length - 1;
      const isJunction = !isLast && (vertexUse.get(vertexKey(coords[i])) || 0) >= 2;
      if (isJunction || isLast) {
        const piece = coords.slice(start, i + 1);
        if (piece.length >= 2) {
          segments.push({
            coords: piece,
            meters: lineMeters(piece),
            edgeId: makeEdgeId(line.recordId, line.partIndex, segIndex, piece),
            sourceRecordId: line.recordId,
            name: line.name,
            surfaceClass: line.surfaceClass,
            structureType: line.structureType,
            accessClass: line.accessClass,
            confidence: line.confidence,
            sourceDescription: line.sourceDescription,
            seasonal: line.seasonal
          });
          segIndex += 1;
        }
        if (isJunction) splitCount += 1;
        start = i;
      }
    }
  }

  console.log(`Split into ${segments.length.toLocaleString()} edges (${splitCount.toLocaleString()} junction splits)`);

  // ---- Connected components ----------------------------------------------
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

  const degree = new Map();
  for (const [a, b] of segmentNodes) {
    degree.set(a, (degree.get(a) || 0) + 1);
    degree.set(b, (degree.get(b) || 0) + 1);
  }
  let junctionNodes = 0;
  let deadEndNodes = 0;
  let degree2Nodes = 0;
  for (const d of degree.values()) {
    if (d >= 3) junctionNodes += 1;
    else if (d === 1) deadEndNodes += 1;
    else if (d === 2) degree2Nodes += 1;
  }

  // Geometry validation: every edge start/end is a declared node
  let invalidEndpointEdges = 0;
  for (const segment of segments) {
    if (!nodeIds.has(vertexKey(segment.coords[0])) ||
        !nodeIds.has(vertexKey(segment.coords[segment.coords.length - 1]))) {
      invalidEndpointEdges += 1;
    }
  }

  // ---- Feature emit ------------------------------------------------------
  const CHUNK_DEG = Number(process.env.NS_GOV_CHUNK_DEG || 0.4);
  const features = segments.map((segment, i) => {
    const props = {
      edgeId: segment.edgeId,
      surfaceClass: segment.surfaceClass,
      structureType: segment.structureType,
      accessClass: segment.accessClass,
      source: "ns-gov",
      sourceDescription: segment.sourceDescription,
      sourceRecordId: segment.sourceRecordId,
      confidence: segment.confidence,
      seasonal: !!segment.seasonal,
      lengthMeters: Math.round(segment.meters),
      distanceMeters: Math.round(segment.meters),
      componentId: componentRank.get(find(segmentNodes[i][0])),
      // Compat for current MapLibre layers / interim client A*
      trackClass: segment.surfaceClass
    };
    if (segment.name) props.name = segment.name;
    return {
      type: "Feature",
      properties: props,
      geometry: { type: "LineString", coordinates: segment.coords }
    };
  });

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
  chunkIndex.sort((a, b) => a.id.localeCompare(b.id));
  chunkIndex.sort((a, b) => b.count - a.count);

  const topology = {
    generatedAt: new Date().toISOString(),
    region: REGION,
    schemaVersion: "2a-1",
    totals: {
      fetchedRows: fetched,
      eligibleSourceLines: lines.length,
      edges: features.length,
      nodes: nodeIds.size,
      junctionNodes,
      deadEndNodes,
      degree2Nodes,
      sameLevelJunctionSplits: splitCount,
      connectedComponents: rankedRoots.length,
      invalidEndpointEdges,
      freeSpaceConnectors: 0
    },
    gradeSeparatedCrossings: {
      status: "not_evaluated",
      note: "Phase 2A preserves bridge/tunnel as structureType but does not yet planarize or grade-separate visual crossings without shared vertices."
    },
    intersectionsNotConnected: {
      status: "by_design",
      note: "Visual crossings without an exact shared vertex remain disconnected. No proximity stitching."
    },
    excludedByReason,
    accessCounts,
    surfaceCounts,
    structureCounts,
    topComponentsKm: rankedRoots.slice(0, 15).map((root) =>
      Math.round(componentMeters.get(root) / 100) / 10
    ),
    limitations: [
      "No free-space connectors are emitted.",
      "Junctions are exact shared-vertex matches only.",
      "Grade-separated crossings are tagged via structureType but not fully modeled in the graph.",
      "Access classes are inferred from NSTDB descriptions; motorized_verified requires future field/source confirmation.",
      "motorized_unknown tracks are packed but should not be silently treated as legal."
    ]
  };

  const manifest = {
    generatedAt: topology.generatedAt,
    schemaVersion: "2a-1",
    sourceName: "Nova Scotia Topographic DataBase Roads, Trails and Rails - Road Line Layer",
    source: sourceUrl,
    catalogue: "https://data.novascotia.ca/Roads-Driving-and-Transport/Nova-Scotia-Topographic-DataBase-Roads-Trails-and-/a6gf-w68e",
    queryModel: "Phase 2A: eligible motorized NSTDB roads/tracks only; trails and No Vehicular Traffic excluded; surface/structure/access separated; exact vertex splits; grid-chunked",
    license: "Open Government Licence - Nova Scotia",
    region: REGION,
    bbox: BBOX.length === 4 ? BBOX : null,
    chunkDeg: CHUNK_DEG,
    chunkDir: "ns-gov-chunks",
    featureCount: features.length,
    sourceLines: lines.length,
    junctionSplits: splitCount,
    fetched,
    skipped: Object.values(excludedByReason).reduce((a, b) => a + b, 0),
    bytes: totalBytes,
    gzBytes: totalGzBytes,
    classes: surfaceCounts,
    accessClasses: accessCounts,
    structureTypes: structureCounts,
    excludedByReason,
    topology: {
      nodes: nodeIds.size,
      junctionNodes,
      deadEndNodes,
      componentCount: rankedRoots.length,
      topComponentsKm: topology.topComponentsKm.slice(0, 10),
      freeSpaceConnectors: 0,
      gradeSeparatedCrossings: topology.gradeSeparatedCrossings.status
    },
    sourceDescriptions,
    limitations: topology.limitations,
    rawArchive: SKIP_RAW ? null : "data-raw/ns-gov/ (outside app bundle)",
    chunks: chunkIndex
  };

  fs.writeFileSync(path.join(outDir, `${OUT_BASENAME}.manifest.json`), JSON.stringify(manifest, null, 2));
  fs.writeFileSync(path.join(outDir, `${OUT_BASENAME}.topology.json`), JSON.stringify(topology, null, 2));

  if (!SKIP_RAW) {
    fs.mkdirSync(RAW_DIR, { recursive: true });
    const rawCollection = {
      type: "FeatureCollection",
      features: rawFeatures,
      properties: {
        generatedAt: topology.generatedAt,
        note: "Audit archive including excluded features. Not loaded by the production map client."
      }
    };
    const rawJson = JSON.stringify(rawCollection);
    const rawGz = zlib.gzipSync(Buffer.from(rawJson), { level: 9 });
    fs.writeFileSync(path.join(RAW_DIR, "raw-features.geojson.gz"), rawGz);
    fs.writeFileSync(
      path.join(RAW_DIR, "README.md"),
      [
        "# NSTDB raw archive",
        "",
        "This folder holds the audit export from `scripts/pack-ns-gov-roads.js`.",
        "It includes eligible and excluded source features with exclude reasons.",
        "",
        "**Do not ship this into `app/data` or load it from the browser client.**",
        "",
        `- Generated: ${topology.generatedAt}`,
        `- Features: ${rawFeatures.length.toLocaleString()}`,
        `- Gzip bytes: ${rawGz.length.toLocaleString()}`,
        ""
      ].join("\n")
    );
    console.log(`Raw archive → ${path.join(RAW_DIR, "raw-features.geojson.gz")} (${(rawGz.length / 1048576).toFixed(1)} MB)`);
  }

  console.log(JSON.stringify({
    schemaVersion: manifest.schemaVersion,
    featureCount: manifest.featureCount,
    skipped: manifest.skipped,
    excludedByReason,
    accessCounts,
    surfaceCounts,
    structureCounts,
    topology: manifest.topology,
    chunks: `${chunkIndex.length} chunks, largest ${chunkIndex[0] ? chunkIndex[0].count : 0} features`
  }, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
