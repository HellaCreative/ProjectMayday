"use strict";

/**
 * British Columbia Digital Road Atlas (DRA) — capillary supplement.
 *
 * Only ROAD_CLASS in (resource, recreation, trail). Highways / local / arterial
 * stay on OSM fabric. Access is motorized_unknown (Allow unknown gate).
 *
 * Prefers a local GeoJSONSeq extract under data-raw/bc-dra/; otherwise pages
 * openmaps.gov.bc.ca WFS. Build helper can materialize the seq from the public GDB.
 */
const fs = require("fs");
const path = require("path");
const https = require("https");
const http = require("http");
const crypto = require("crypto");
const readline = require("readline");
const { createNormalizedEdge } = require("../schema/edge");
const {
  SURFACE_CLASS,
  ACCESS_CLASS,
  STRUCTURE_TYPE,
  ROAD_TRACK_CLASS,
  SOURCE_CONFIDENCE
} = require("../schema/enums");
const { bump, makeReport, emptyCounts } = require("./contract");

const name = "bc-dra-roads";
const TYPE_NAME = "WHSE_BASEMAPPING.DRA_DGTL_ROAD_ATLAS_MPAR_SP";
const WFS = "https://openmaps.gov.bc.ca/geo/pub/ows";
const CATALOGUE =
  "https://catalogue.data.gov.bc.ca/dataset/digital-road-atlas-dra-master-partially-attributed-roads";
const CAPILLARY_CLASSES = new Set(["resource", "recreation", "trail"]);
const CQL = "ROAD_CLASS IN ('resource','recreation','trail')";

const ROOT = path.join(__dirname, "..", "..");
const DEFAULT_SEQ = path.join(ROOT, "data-raw", "bc-dra", "capillary.geojsonseq");

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
          reject(new Error("BC DRA WFS HTTP " + res.statusCode + ": " + text.slice(0, 240)));
          return;
        }
        try {
          resolve(JSON.parse(text));
        } catch (err) {
          reject(err);
        }
      });
      res.on("error", reject);
    });
    req.setTimeout(180000, () => {
      req.destroy(new Error("BC DRA WFS timeout"));
    });
    req.on("error", reject);
  });
}

async function fetchPage(pageSize, startIndex) {
  const u = new URL(WFS);
  u.searchParams.set("service", "WFS");
  u.searchParams.set("version", "2.0.0");
  u.searchParams.set("request", "GetFeature");
  u.searchParams.set("typeName", TYPE_NAME);
  u.searchParams.set("outputFormat", "json");
  u.searchParams.set("srsName", "EPSG:4326");
  u.searchParams.set("count", String(pageSize));
  u.searchParams.set("sortBy", "DIGITAL_ROAD_ATLAS_LINE_ID");
  u.searchParams.set("CQL_FILTER", CQL);
  if (startIndex > 0) u.searchParams.set("startIndex", String(startIndex));
  let lastErr = null;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      return await fetchJson(u.toString());
    } catch (err) {
      lastErr = err;
      const wait = 1500 * (attempt + 1);
      console.error(`[bc-dra] page start=${startIndex} attempt=${attempt + 1} failed: ${err.message}; retry in ${wait}ms`);
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw lastErr;
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

function normalizeLine(coords) {
  const out = [];
  for (const raw of coords) {
    if (!Array.isArray(raw) || raw.length < 2) continue;
    const c = roundCoord([Number(raw[0]), Number(raw[1])]);
    if (!Number.isFinite(c[0]) || !Number.isFinite(c[1])) continue;
    if (Math.abs(c[0]) > 180 || Math.abs(c[1]) > 90) continue;
    const last = out[out.length - 1];
    if (last && last[0] === c[0] && last[1] === c[1]) continue;
    out.push(c);
  }
  return out;
}

function haversineMeters(a, b) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const r = 6371000;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function lineMeters(coords) {
  let total = 0;
  for (let i = 1; i < coords.length; i += 1) total += haversineMeters(coords[i - 1], coords[i]);
  return total;
}

function geometryParts(geometry) {
  if (!geometry) return [];
  if (geometry.type === "LineString") return [normalizeLine(geometry.coordinates)].filter((c) => c.length >= 2);
  if (geometry.type === "MultiLineString") {
    return geometry.coordinates.map(normalizeLine).filter((c) => c.length >= 2);
  }
  return [];
}

function propsFromRow(row) {
  const p = row.properties || {};
  // WFS uses long names; public GDB uses abbreviated columns.
  return {
    ROAD_CLASS: p.ROAD_CLASS || p.RD_CLASS || null,
    ROAD_SURFACE: p.ROAD_SURFACE || p.RD_SURFACE || null,
    ROAD_NAME_FULL: p.ROAD_NAME_FULL || p.NAME_FULL || null,
    DIGITAL_ROAD_ATLAS_LINE_ID: p.DIGITAL_ROAD_ATLAS_LINE_ID || p.ID || p.OBJECTID || null,
    OBJECTID: p.OBJECTID || null
  };
}

function classify(rawProps) {
  const props = propsFromRow({ properties: rawProps });
  const roadClass = String(props.ROAD_CLASS || "").toLowerCase().trim();
  if (!CAPILLARY_CLASSES.has(roadClass)) {
    return { ok: false, reason: "non_capillary_class" };
  }
  const surfaceRaw = String(props.ROAD_SURFACE || "").toLowerCase().trim();
  const nameText = String(props.ROAD_NAME_FULL || "").toLowerCase();

  // Keep Restrictive / closed out of the pack.
  if (/decommission|abandoned|closed|private|restricted|no.?motor|no.?vehicle/i.test(nameText)) {
    return { ok: false, reason: "restricted_or_closed" };
  }

  let surfaceClass = SURFACE_CLASS.resource;
  let roadTrackClass = ROAD_TRACK_CLASS.resource;

  if (roadClass === "trail") {
    surfaceClass = SURFACE_CLASS.track;
    roadTrackClass = ROAD_TRACK_CLASS.track;
  } else if (roadClass === "recreation") {
    surfaceClass = SURFACE_CLASS.resource;
    roadTrackClass = ROAD_TRACK_CLASS.recreation;
  }

  if (/paved|asphalt|concrete|seal/.test(surfaceRaw)) {
    surfaceClass = SURFACE_CLASS.paved;
  } else if (/loose|gravel|crush|unpaved/.test(surfaceRaw)) {
    surfaceClass = SURFACE_CLASS.gravel;
  } else if (/rough|overgrown|dirt|earth|soil|natural|seasonal/.test(surfaceRaw)) {
    if (roadClass === "trail") {
      surfaceClass = SURFACE_CLASS.track;
      roadTrackClass = ROAD_TRACK_CLASS.track;
    } else {
      surfaceClass = SURFACE_CLASS.resource;
    }
  }

  return {
    ok: true,
    surfaceClass,
    roadTrackClass,
    accessClass: ACCESS_CLASS.motorized_unknown,
    roadClass,
    props
  };
}

function edgePriority(props) {
  const roadClass = String(props.ROAD_CLASS || "").toLowerCase();
  // Prefer trail + recreation when soft-capping large extracts.
  if (roadClass === "trail") return 0;
  if (roadClass === "recreation") return 1;
  return 2;
}

function featureFromRow(row, scanned) {
  const classified = classify(row.properties || {});
  if (!classified.ok) return { excluded: classified.reason };
  const props = classified.props;
  const parts = geometryParts(row.geometry);
  if (!parts.length) return { excluded: "no_usable_geometry" };

  const featureId =
    props.DIGITAL_ROAD_ATLAS_LINE_ID || props.OBJECTID || row.id || scanned;
  const out = [];
  for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
    const coords = parts[partIndex];
    const seed = ["bc-dra", featureId, partIndex, coords[0].join(","), coords[coords.length - 1].join(",")].join("|");
    const edgeId = "bc-dra-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
    out.push(
      createNormalizedEdge({
        edgeId,
        lineageId: `bc-dra:${featureId}:${partIndex}`,
        province: "BC",
        sourceName: "BC Digital Road Atlas",
        sourceDatasetVersion: "DRA_DGTL_ROAD_ATLAS_MPAR_SP",
        sourceFeatureId: String(featureId),
        sourceGeometryLineage: TYPE_NAME,
        geometry: { type: "LineString", coordinates: coords },
        surfaceClass: classified.surfaceClass,
        roadTrackClass: classified.roadTrackClass,
        accessClass: classified.accessClass,
        structureType: STRUCTURE_TYPE.none,
        sourceConfidence: SOURCE_CONFIDENCE.medium,
        roadName: props.ROAD_NAME_FULL || null,
        direction: "both",
        seasonal: false,
        distanceMeters: lineMeters(coords),
        meta: {
          conflationRole: "supplement",
          roadClass: classified.roadClass,
          roadSurface: props.ROAD_SURFACE || null,
          edgePriority: edgePriority(props)
        }
      })
    );
  }
  return { features: out };
}

async function loadFromGeoJSONSeq(seqPath, maxFeatures) {
  const classification = emptyCounts();
  const excludedByReason = {};
  const features = [];
  let scanned = 0;

  const rl = readline.createInterface({
    input: fs.createReadStream(seqPath, { encoding: "utf8" }),
    crlfDelay: Infinity
  });

  const buckets = [[], [], []]; // trail, recreation, resource
  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    scanned += 1;
    let row;
    try {
      row = JSON.parse(trimmed);
    } catch {
      bump(excludedByReason, "bad_json");
      continue;
    }
    const built = featureFromRow(row, scanned);
    if (built.excluded) {
      bump(excludedByReason, built.excluded);
      continue;
    }
    for (const edge of built.features) {
      bump(classification.surface, edge.surfaceClass);
      bump(classification.access, edge.accessClass);
      bump(classification.structure, edge.structureType);
      bump(classification.roadTrack, edge.roadTrackClass);
      const p = edge.meta && edge.meta.edgePriority != null ? edge.meta.edgePriority : 2;
      buckets[Math.min(2, Math.max(0, p))].push(edge);
    }
  }

  for (const bucket of buckets) {
    for (const edge of bucket) {
      if (features.length >= maxFeatures) break;
      features.push(edge);
    }
    if (features.length >= maxFeatures) break;
  }

  return { features, classification, excludedByReason, scanned };
}

async function loadFromWfs(pageSize, maxFeatures) {
  const classification = emptyCounts();
  const excludedByReason = {};
  const features = [];
  let startIndex = 0;
  let scanned = 0;

  for (;;) {
    const fc = await fetchPage(pageSize, startIndex);
    const rows = fc.features || [];
    if (!rows.length) break;

    for (const row of rows) {
      scanned += 1;
      if (features.length >= maxFeatures) break;
      const built = featureFromRow(row, scanned);
      if (built.excluded) {
        bump(excludedByReason, built.excluded);
        continue;
      }
      for (const edge of built.features) {
        if (features.length >= maxFeatures) break;
        bump(classification.surface, edge.surfaceClass);
        bump(classification.access, edge.accessClass);
        bump(classification.structure, edge.structureType);
        bump(classification.roadTrack, edge.roadTrackClass);
        features.push(edge);
      }
    }

    if (features.length >= maxFeatures) break;
    if (rows.length < pageSize) break;
    startIndex += rows.length;
    if (startIndex > 3000000) break;
  }

  return { features, classification, excludedByReason, scanned };
}

async function run(options = {}) {
  const pageSize = options.pageSize || 2000;
  const maxFeatures = options.maxFeatures != null ? options.maxFeatures : 350000;
  const seqPath = options.inputPath || DEFAULT_SEQ;

  let loaded;
  if (fs.existsSync(seqPath)) {
    console.log(`[bc-dra] Reading local extract ${seqPath}`);
    loaded = await loadFromGeoJSONSeq(seqPath, maxFeatures);
  } else {
    console.log(`[bc-dra] No local extract at ${seqPath}; paging WFS (slower)`);
    loaded = await loadFromWfs(pageSize, maxFeatures);
  }

  const report = makeReport({
    adapter: name,
    province: "BC",
    sourceName: "BC Digital Road Atlas",
    sourceUrl: CATALOGUE,
    downloadUrl: WFS,
    license: "Open Government Licence - British Columbia",
    sourceDatasetVersion: "DRA_DGTL_ROAD_ATLAS_MPAR_SP",
    status: "ok",
    featureCount: loaded.features.length,
    scannedCount: loaded.scanned,
    classification: loaded.classification,
    excludedByReason: loaded.excludedByReason,
    notes: [
      "Capillary only: ROAD_CLASS resource / recreation / trail.",
      "Access is motorized_unknown — gated by Allow unknown.",
      "Highways and urban local/arterial stay on OSM fabric."
    ],
    knownLimitations: [
      "Trail class may include non-motorized recreation — Allow unknown stays the legality gate.",
      "Soft-capped extracts prefer trail + recreation before resource when maxFeatures binds."
    ]
  });

  return { features: loaded.features, report };
}

module.exports = {
  name,
  run,
  WFS,
  TYPE_NAME,
  CQL,
  CAPILLARY_CLASSES,
  DEFAULT_SEQ
};
