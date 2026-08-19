"use strict";

const fs = require("fs");
const path = require("path");
const readline = require("readline");
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

const name = "nrn";
const DEFAULT_LICENSE = "Open Government Licence - Canada";
const DEFAULT_SOURCE =
  "https://open.canada.ca/data/en/dataset/3d282116-e556-400c-9306-ca1a3cada77f";

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

function classifyNrnProps(props) {
  const pavStatus = value(props.PAVSTATUS);
  const pavSurf = value(props.PAVSURF);
  const unpavSurf = value(props.UNPAVSURF);
  const roadClass = value(props.ROADCLASS);
  const structType = value(props.STRUCTTYPE);

  // Hard exclusions — never invent permission.
  if (/Abandoned/i.test(roadClass)) {
    return { ok: false, reason: "abandoned" };
  }
  if (/Ferry/i.test(roadClass)) {
    return { ok: false, reason: "ferry_as_roadseg" };
  }

  let structureType = STRUCTURE_TYPE.none;
  if (/Bridge/i.test(structType)) structureType = STRUCTURE_TYPE.bridge;
  else if (/Tunnel/i.test(structType)) structureType = STRUCTURE_TYPE.tunnel;
  else if (/Barrier|Blocked/i.test(structType)) structureType = STRUCTURE_TYPE.blocked_passage;

  let surfaceClass = SURFACE_CLASS.unknown;
  let confidence = SOURCE_CONFIDENCE.medium;
  if (/Unpaved/i.test(pavStatus) || /gravel|earth|dirt|unpaved/i.test(unpavSurf)) {
    surfaceClass = SURFACE_CLASS.gravel;
    confidence = SOURCE_CONFIDENCE.high;
  } else if (/\bPaved\b/i.test(pavStatus) || /asphalt|concrete|^paved$/i.test(pavSurf)) {
    surfaceClass = SURFACE_CLASS.paved;
    confidence = SOURCE_CONFIDENCE.high;
  } else if (/Resource|Recreation/i.test(roadClass)) {
    surfaceClass = SURFACE_CLASS.resource;
    confidence = SOURCE_CONFIDENCE.medium;
  } else if (/Local|Collector|Arterial|Expressway|Freeway|Alley|Ramp|Rapid|Service/i.test(roadClass)) {
    // Conventional class without pavement status — unknown surface, not invented paved.
    surfaceClass = SURFACE_CLASS.unknown;
    confidence = SOURCE_CONFIDENCE.low;
  } else {
    surfaceClass = SURFACE_CLASS.unknown;
    confidence = SOURCE_CONFIDENCE.low;
  }

  let roadTrackClass = ROAD_TRACK_CLASS.unknown;
  if (/Freeway|Expressway/i.test(roadClass)) roadTrackClass = ROAD_TRACK_CLASS.freeway;
  else if (/Arterial/i.test(roadClass)) roadTrackClass = ROAD_TRACK_CLASS.arterial;
  else if (/Collector/i.test(roadClass)) roadTrackClass = ROAD_TRACK_CLASS.collector;
  else if (/Local|Alley|Street/i.test(roadClass)) roadTrackClass = ROAD_TRACK_CLASS.local;
  else if (/Resource/i.test(roadClass)) roadTrackClass = ROAD_TRACK_CLASS.resource;
  else if (/Recreation/i.test(roadClass)) roadTrackClass = ROAD_TRACK_CLASS.recreation;
  else if (/Ramp/i.test(roadClass)) roadTrackClass = ROAD_TRACK_CLASS.ramp;
  else if (/Service/i.test(roadClass)) roadTrackClass = ROAD_TRACK_CLASS.service;

  // NRN is an authoritative road inventory — treat conventional classes as
  // permissive connectivity. Resource/recreation with unknown pavement stays
  // motorized_unknown (never invent motorcycle permission).
  let accessClass = ACCESS_CLASS.motorized_permissive;
  if (/Resource|Recreation/i.test(roadClass) && surfaceClass !== SURFACE_CLASS.paved && surfaceClass !== SURFACE_CLASS.gravel) {
    accessClass = ACCESS_CLASS.motorized_unknown;
  }

  let direction = "both";
  const traffic = value(props.TRAFFICDIR);
  if (/Same direction|One direction|Positive/i.test(traffic)) direction = "forward";
  else if (/Opposite|Negative/i.test(traffic)) direction = "reverse";

  return {
    ok: true,
    surfaceClass,
    accessClass,
    structureType,
    roadTrackClass,
    confidence,
    direction,
    roadClass,
    pavementStatus: pavStatus,
    seasonal: false
  };
}

function makeEdgeId(province, featureId, partIndex, coords) {
  const seed = ["nrn", province, featureId, partIndex, coords[0].join(","), coords[coords.length - 1].join(",")].join("|");
  return "nrn-" + province.toLowerCase() + "-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
}

function geometryParts(geometry) {
  if (!geometry) return [];
  if (geometry.type === "LineString") return [normalizeLine(geometry.coordinates)].filter((c) => c.length >= 2);
  if (geometry.type === "MultiLineString") {
    return geometry.coordinates.map(normalizeLine).filter((c) => c.length >= 2);
  }
  return [];
}

function featureToEdges(feature, province, datasetVersion) {
  const props = feature.properties || {};
  const classification = classifyNrnProps(props);
  const featureId = firstKnown(props.NID, props.ROADSEGID, feature.id);
  const parts = geometryParts(feature.geometry);
  if (!classification.ok) {
    return { edges: [], excludedReason: classification.reason };
  }
  if (!parts.length) {
    return { edges: [], excludedReason: "no_usable_geometry" };
  }

  const roadName = firstKnown(props.STRUNAMEEN, props.R_STNAME_C, props.L_STNAME_C, props.RTENAME1EN);
  const edges = [];
  for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
    const coords = parts[partIndex];
    const edgeId = makeEdgeId(province, featureId || "x", partIndex, coords);
    edges.push(
      createNormalizedEdge({
        edgeId,
        lineageId: "nrn:" + province + ":" + (featureId || edgeId),
        province,
        sourceName: "National Road Network",
        sourceDatasetVersion: datasetVersion,
        sourceFeatureId: featureId || null,
        sourceGeometryLineage: "nrn-roadseg",
        geometry: { type: "LineString", coordinates: coords },
        surfaceClass: classification.surfaceClass,
        roadTrackClass: classification.roadTrackClass,
        accessClass: classification.accessClass,
        structureType: classification.structureType,
        roadName: roadName || null,
        direction: classification.direction,
        seasonal: classification.seasonal,
        sourceConfidence: classification.confidence,
        distanceMeters: Math.max(1, Math.round(lineMeters(coords))),
        meta: {
          roadClass: classification.roadClass,
          pavementStatus: classification.pavementStatus,
          roadSegmentId: props.ROADSEGID || null
        }
      })
    );
  }
  return { edges, excludedReason: null };
}

/**
 * @param {object} options
 * @param {string} options.inputPath GeoJSONSeq path
 * @param {string} options.province Province code e.g. NS
 * @param {string} [options.sourceUrl]
 * @param {string} [options.downloadUrl]
 * @param {string} [options.datasetVersion]
 */
async function run(options = {}) {
  const inputPath = options.inputPath;
  if (!inputPath || !fs.existsSync(inputPath)) {
    throw new Error("NRN adapter requires options.inputPath to an existing GeoJSONSeq file");
  }
  const province = String(options.province || "NS").toUpperCase();
  const datasetVersion = options.datasetVersion || path.basename(inputPath);
  const classification = emptyCounts();
  const excludedByReason = {};
  const features = [];

  const rl = readline.createInterface({
    input: fs.createReadStream(inputPath),
    crlfDelay: Infinity
  });

  for await (const raw of rl) {
    const line = raw.replace(/^\x1e/, "").trim();
    if (!line) continue;
    let feature;
    try {
      feature = JSON.parse(line);
    } catch {
      bump(excludedByReason, "invalid_json");
      continue;
    }
    const { edges, excludedReason } = featureToEdges(feature, province, datasetVersion);
    if (excludedReason) {
      bump(excludedByReason, excludedReason);
      continue;
    }
    for (const edge of edges) {
      features.push(edge);
      bump(classification.surface, edge.surfaceClass);
      bump(classification.access, edge.accessClass);
      bump(classification.structure, edge.structureType);
      bump(classification.roadTrack, edge.roadTrackClass);
    }
  }

  const report = makeReport({
    adapter: name,
    province,
    sourceName: "National Road Network (NRCan)",
    sourceUrl: options.sourceUrl || DEFAULT_SOURCE,
    downloadUrl: options.downloadUrl || options.sourceUrl || DEFAULT_SOURCE,
    license: DEFAULT_LICENSE,
    sourceDatasetVersion: datasetVersion,
    features,
    excludedByReason,
    classification,
    notes: [
      "NRN is the national paved/gravel road backbone.",
      "Access is motorized_permissive for conventional inventory roads; resource/recreation with unknown pavement stay motorized_unknown.",
      "Missing pavement status is surface unknown — never invented as paved."
    ],
    knownLimitations: [
      "Does not encode motorcycle-specific legality.",
      "Resource/recreation coverage varies by province provider."
    ]
  });

  return { features, report };
}

module.exports = {
  name,
  classifyNrnProps,
  featureToEdges,
  run
};
