"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const crypto = require("crypto");
const { createNormalizedEdge } = require("../schema/edge");
const {
  SURFACE_CLASS,
  ACCESS_CLASS,
  STRUCTURE_TYPE,
  ROAD_TRACK_CLASS,
  SOURCE_CONFIDENCE
} = require("../schema/enums");
const { bump, makeReport, emptyCounts } = require("./contract");

const name = "ns-nstdb";
const DEFAULT_SOURCE = "https://data.novascotia.ca/resource/a6gf-w68e.json";
const DEFAULT_LICENSE = "Open Government Licence - Nova Scotia";

function value(v) {
  return v == null ? "" : String(v).trim();
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

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

/**
 * Classify one NSTDB row / feature description.
 * Preserves Phase 2A rules; emits canonical enums (resource replaces legacy "access" surface).
 */
function classifyNstdbDescription(descRaw) {
  const desc = value(descRaw);
  if (!desc) return { ok: false, reason: "missing_feat_desc" };

  if (/No Vehicular Traffic/i.test(desc)) return { ok: false, reason: "no_vehicular_traffic" };
  if (/\bTRAIL\b/i.test(desc)) return { ok: false, reason: "non_motorized_trail" };
  if (/Railroad|Railway/i.test(desc)) return { ok: false, reason: "railway" };
  if (/Ferry/i.test(desc)) return { ok: false, reason: "ferry" };
  if (/Driveway/i.test(desc)) return { ok: false, reason: "driveway" };
  if (/Median Crossover/i.test(desc)) return { ok: false, reason: "median_crossover" };
  if (/Service Lane/i.test(desc)) return { ok: false, reason: "service_lane" };
  if (/\bDam\b/i.test(desc)) return { ok: false, reason: "dam" };
  if (/Pedestrian|Footpath|Sidewalk/i.test(desc)) return { ok: false, reason: "pedestrian_only" };
  if (/Bicycle|Cycleway/i.test(desc)) return { ok: false, reason: "bicycle_only" };

  let structureType = STRUCTURE_TYPE.none;
  if (/\bBRIDGE\b/i.test(desc)) structureType = STRUCTURE_TYPE.bridge;
  else if (/\bTUNNEL\b/i.test(desc)) structureType = STRUCTURE_TYPE.tunnel;
  else if (/\bFord\b/i.test(desc)) structureType = STRUCTURE_TYPE.ford;

  let surfaceClass = SURFACE_CLASS.unknown;
  let roadTrackClass = ROAD_TRACK_CLASS.unknown;
  if (/\bPaved\b/i.test(desc) && !/\bUnpaved\b/i.test(desc)) {
    surfaceClass = SURFACE_CLASS.paved;
    roadTrackClass = /\bRAMP\b/i.test(desc) ? ROAD_TRACK_CLASS.ramp : ROAD_TRACK_CLASS.local;
  } else if (/Resource Access/i.test(desc)) {
    surfaceClass = SURFACE_CLASS.resource;
    roadTrackClass = ROAD_TRACK_CLASS.resource;
  } else if (/\bTRACK\b/i.test(desc) || desc === "TRACK") {
    surfaceClass = SURFACE_CLASS.track;
    roadTrackClass = ROAD_TRACK_CLASS.track;
  } else if (/Unpaved/i.test(desc)) {
    surfaceClass = SURFACE_CLASS.gravel;
    roadTrackClass = ROAD_TRACK_CLASS.local;
  } else if (structureType !== STRUCTURE_TYPE.none) {
    surfaceClass = SURFACE_CLASS.unknown;
  } else {
    return { ok: false, reason: "unclassified_description" };
  }

  let accessClass = ACCESS_CLASS.motorized_unknown;
  let confidence = SOURCE_CONFIDENCE.medium;
  if (/Abandoned/i.test(desc)) {
    accessClass = ACCESS_CLASS.motorized_restricted;
    confidence = SOURCE_CONFIDENCE.low;
  } else if (surfaceClass === SURFACE_CLASS.track) {
    accessClass = ACCESS_CLASS.motorized_unknown;
    confidence = /Indefinite|Approximate/i.test(desc) ? SOURCE_CONFIDENCE.low : SOURCE_CONFIDENCE.medium;
  } else if (
    surfaceClass === SURFACE_CLASS.paved ||
    surfaceClass === SURFACE_CLASS.gravel ||
    surfaceClass === SURFACE_CLASS.resource
  ) {
    accessClass = ACCESS_CLASS.motorized_permissive;
    confidence =
      surfaceClass === SURFACE_CLASS.resource && /Dry Weather/i.test(desc)
        ? SOURCE_CONFIDENCE.medium
        : SOURCE_CONFIDENCE.high;
  }

  return {
    ok: true,
    surfaceClass,
    accessClass,
    structureType,
    roadTrackClass,
    confidence,
    sourceDescription: desc,
    seasonal: /Dry Weather|Seasonal|Winter/i.test(desc)
  };
}

function makeEdgeId(recordId, partIndex, coords) {
  const seed = recordId + "|" + partIndex + "|" + coords[0].join(",") + "|" + coords[coords.length - 1].join(",");
  return "ns-nstdb-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
}

function packedFeatureToEdge(feature) {
  const p = feature.properties || {};
  const coords = feature.geometry && feature.geometry.coordinates;
  if (!coords || coords.length < 2) return { edge: null, excludedReason: "no_usable_geometry" };

  // Prefer already-packed Phase 2A classes when present; map access→resource.
  let surfaceClass = p.surfaceClass || p.trackClass || null;
  if (surfaceClass === "access") surfaceClass = SURFACE_CLASS.resource;
  let accessClass = p.accessClass || null;
  let structureType = p.structureType || STRUCTURE_TYPE.none;
  let confidence = p.confidence || SOURCE_CONFIDENCE.medium;
  let sourceDescription = p.sourceDescription || p.feat_desc || "";
  let seasonal = !!p.seasonal;
  let roadTrackClass = ROAD_TRACK_CLASS.unknown;

  if (!surfaceClass || !accessClass) {
    const classified = classifyNstdbDescription(sourceDescription || p.feat_desc);
    if (!classified.ok) return { edge: null, excludedReason: classified.reason };
    surfaceClass = classified.surfaceClass;
    accessClass = classified.accessClass;
    structureType = classified.structureType;
    confidence = classified.confidence;
    sourceDescription = classified.sourceDescription;
    seasonal = classified.seasonal;
    roadTrackClass = classified.roadTrackClass;
  } else {
    if (surfaceClass === SURFACE_CLASS.resource) roadTrackClass = ROAD_TRACK_CLASS.resource;
    else if (surfaceClass === SURFACE_CLASS.track) roadTrackClass = ROAD_TRACK_CLASS.track;
    else if (surfaceClass === SURFACE_CLASS.paved) roadTrackClass = ROAD_TRACK_CLASS.local;
    else if (surfaceClass === SURFACE_CLASS.gravel) roadTrackClass = ROAD_TRACK_CLASS.local;
  }

  if (accessClass === "motorized_excluded") {
    return { edge: null, excludedReason: "motorized_excluded" };
  }

  const normalized = normalizeLine(coords);
  if (normalized.length < 2) return { edge: null, excludedReason: "no_usable_geometry" };

  const recordId = p.sourceRecordId || p.edgeId || "unknown";
  const edgeId = p.edgeId && String(p.edgeId).startsWith("ns-")
    ? String(p.edgeId).replace(/^ns-gov-/, "ns-nstdb-")
    : makeEdgeId(recordId, 0, normalized);

  const edge = createNormalizedEdge({
    edgeId,
    lineageId: "nstdb:NS:" + recordId,
    province: "NS",
    sourceName: "Nova Scotia Topographic DataBase Roads, Trails and Rails",
    sourceDatasetVersion: p.schemaVersion || "nstdb-a6gf-w68e",
    sourceFeatureId: recordId,
    sourceGeometryLineage: "nstdb-road-line",
    geometry: { type: "LineString", coordinates: normalized },
    componentId: p.componentId,
    surfaceClass,
    roadTrackClass,
    accessClass,
    structureType,
    roadName: p.name || null,
    direction: "both",
    seasonal,
    sourceConfidence: confidence,
    distanceMeters: Math.max(1, Math.round(Number(p.distanceMeters || p.lengthMeters) || lineMeters(normalized))),
    meta: {
      sourceDescription,
      legacySurfaceClass: p.surfaceClass || null
    }
  });
  return { edge, excludedReason: null };
}

function loadFeatureCollection(filePath) {
  const buf = fs.readFileSync(filePath);
  if (filePath.endsWith(".gz")) {
    return JSON.parse(zlib.gunzipSync(buf).toString("utf8"));
  }
  return JSON.parse(buf.toString("utf8"));
}

/**
 * Run NSTDB adapter from packed display chunks (preferred) or a FeatureCollection path.
 * @param {object} options
 * @param {string} [options.chunkDir]
 * @param {string} [options.featureCollectionPath]
 * @param {string} [options.sourceUrl]
 */
async function run(options = {}) {
  const classification = emptyCounts();
  const excludedByReason = {};
  const features = [];
  const files = [];

  if (options.featureCollectionPath) {
    files.push(options.featureCollectionPath);
  } else {
    const chunkDir = options.chunkDir || path.join(__dirname, "..", "..", "app", "data", "ns-gov-chunks");
    if (!fs.existsSync(chunkDir)) {
      throw new Error("NSTDB adapter missing chunkDir: " + chunkDir);
    }
    for (const file of fs.readdirSync(chunkDir).filter((f) => f.endsWith(".geojson.gz")).sort()) {
      files.push(path.join(chunkDir, file));
    }
  }

  for (const file of files) {
    const fc = loadFeatureCollection(file);
    for (const feature of fc.features || []) {
      const { edge, excludedReason } = packedFeatureToEdge(feature);
      if (excludedReason) {
        bump(excludedByReason, excludedReason);
        continue;
      }
      features.push(edge);
      bump(classification.surface, edge.surfaceClass);
      bump(classification.access, edge.accessClass);
      bump(classification.structure, edge.structureType);
      bump(classification.roadTrack, edge.roadTrackClass);
    }
  }

  const report = makeReport({
    adapter: name,
    province: "NS",
    sourceName: "Nova Scotia Topographic DataBase — Road Line Layer",
    sourceUrl: options.sourceUrl || DEFAULT_SOURCE,
    downloadUrl: options.sourceUrl || DEFAULT_SOURCE,
    license: DEFAULT_LICENSE,
    sourceDatasetVersion: "a6gf-w68e",
    features,
    excludedByReason,
    classification,
    notes: [
      "Provincial supplement for resource roads, tracks, and local detail NRN may omit.",
      "TRACK surfaces remain motorized_unknown — never invented as permissive."
    ],
    knownLimitations: [
      "feat_desc does not assert motorcycle legality.",
      "Indefinite/approximate TRACK geometry confidence is low."
    ]
  });

  return { features, report };
}

module.exports = {
  name,
  classifyNstdbDescription,
  packedFeatureToEdge,
  run
};
