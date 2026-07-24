"use strict";

/**
 * Ontario MNRF Road Segments — resource / recreation supplement.
 * Source: LIO Open Data MapServer (Open Government Licence - Ontario)
 */
const https = require("https");
const http = require("http");
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

const name = "on-mnrf-roads";
const SERVICE =
  "https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/LIO_OPEN_DATA/LIO_Open09/MapServer";
const LAYER_ID = 18; // MNRF Road Segment

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith("https") ? https : http;
    lib
      .get(url, (res) => {
        if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          fetchJson(res.headers.location).then(resolve, reject);
          return;
        }
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          try {
            resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
          } catch (err) {
            reject(err);
          }
        });
        res.on("error", reject);
      })
      .on("error", reject);
  });
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
  const x =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function lineMeters(coords) {
  let total = 0;
  for (let i = 1; i < coords.length; i += 1) total += haversineMeters(coords[i - 1], coords[i]);
  return total;
}

function pathsFromGeometry(geometry) {
  if (!geometry || !geometry.paths) return [];
  return geometry.paths.map(normalizeLine).filter((c) => c.length >= 2);
}

function classifyAttrs(attrs) {
  const closed = String(attrs.CLOSED_STATE || "").toLowerCase();
  const privateInd = String(attrs.PRIVATE_ROAD_IND || "").toLowerCase();
  const yearDecom = attrs.YEAR_DECOMMISSIONED;
  if (yearDecom != null && String(yearDecom).trim() !== "") {
    return { ok: false, reason: "restricted_or_closed" };
  }
  if (/closed|decommission|abandon/.test(closed)) {
    return { ok: false, reason: "restricted_or_closed" };
  }
  if (privateInd === "yes" || privateInd === "y" || privateInd === "true") {
    return { ok: false, reason: "restricted_or_closed" };
  }

  const nrc = String(attrs.NATIONAL_ROAD_CLASS || "").toLowerCase();
  // Phase 2 lock: MNR/resource capillary only. Skip ORN-derived conventional
  // classes — those duplicate OSM fabric and must never become the alternate graph.
  if (/freeway|expressway|arterial|collector/.test(nrc) && !/resource|recreation/.test(nrc)) {
    return { ok: false, reason: "orn_or_conventional_skip" };
  }
  if (/^local$|local.?road/.test(nrc) && !/resource|recreation/.test(nrc)) {
    return { ok: false, reason: "orn_or_conventional_skip" };
  }

  let surfaceClass = SURFACE_CLASS.resource;
  let roadTrackClass = ROAD_TRACK_CLASS.resource;
  if (/resource|recreation/.test(nrc)) {
    surfaceClass = SURFACE_CLASS.gravel;
    roadTrackClass = ROAD_TRACK_CLASS.resource;
  } else if (/gravel|unpaved/.test(nrc)) {
    surfaceClass = SURFACE_CLASS.gravel;
  } else if (!nrc || /unknown|other|access/.test(nrc)) {
    // Sparse MNR attrs — keep as unknown capillary, not paved local.
    surfaceClass = SURFACE_CLASS.gravel;
    roadTrackClass = ROAD_TRACK_CLASS.resource;
  } else {
    return { ok: false, reason: "orn_or_conventional_skip" };
  }
  return {
    ok: true,
    surfaceClass,
    accessClass: ACCESS_CLASS.motorized_unknown,
    structureType: STRUCTURE_TYPE.none,
    roadTrackClass,
    confidence: SOURCE_CONFIDENCE.medium
  };
}

async function query(offset, pageSize) {
  const params = new URLSearchParams({
    where: "1=1",
    outFields: "*",
    returnGeometry: "true",
    outSR: "4326",
    f: "json",
    resultOffset: String(offset),
    resultRecordCount: String(pageSize)
  });
  return fetchJson(`${SERVICE}/${LAYER_ID}/query?${params.toString()}`);
}

async function run(options = {}) {
  const pageSize = options.pageSize || 1000;
  const maxFeatures = options.maxFeatures || Infinity;
  const classification = emptyCounts();
  const excludedByReason = {};
  const features = [];
  let scanned = 0;
  let offset = 0;

  for (;;) {
    if (options.debug) console.error("[on-mnrf] query offset", offset, "features", features.length);
    const page = await query(offset, pageSize);
    if (options.debug) console.error("[on-mnrf] page", (page.features || []).length, page.error || "");
    const rows = page.features || [];
    if (!rows.length) break;
    for (const row of rows) {
      scanned += 1;
      if (features.length >= maxFeatures) break;
      const attrs = row.attributes || {};
      const classified = classifyAttrs(attrs);
      if (!classified.ok) {
        bump(excludedByReason, classified.reason);
        continue;
      }
      const parts = pathsFromGeometry(row.geometry);
      if (!parts.length) {
        bump(excludedByReason, "no_usable_geometry");
        continue;
      }
      const featureId = attrs.OGF_ID || attrs.OBJECTID || `${offset}-${features.length}`;
      for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
        if (features.length >= maxFeatures) break;
        const coords = parts[partIndex];
        const seed = ["on-mnrf", featureId, partIndex, coords[0].join(","), coords[coords.length - 1].join(",")].join("|");
        const edgeId = "on-mnrf-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
        bump(classification.surface, classified.surfaceClass);
        bump(classification.access, classified.accessClass);
        bump(classification.structure, classified.structureType);
        bump(classification.roadTrack, classified.roadTrackClass);
        features.push(
          createNormalizedEdge({
            edgeId,
            lineageId: `on-mnrf:${featureId}:${partIndex}`,
            province: "ON",
            sourceName: "Ontario MNRF Road Segments",
            sourceDatasetVersion: "LIO_Open09/18",
            sourceFeatureId: String(featureId),
            sourceGeometryLineage: `mapserver:${LAYER_ID}`,
            geometry: { type: "LineString", coordinates: coords },
            surfaceClass: classified.surfaceClass,
            roadTrackClass: classified.roadTrackClass,
            accessClass: classified.accessClass,
            structureType: classified.structureType,
            sourceConfidence: classified.confidence,
            roadName: attrs.ROAD_NAME || null,
            direction: "both",
            seasonal: false,
            distanceMeters: lineMeters(coords),
            meta: {
              nationalRoadClass: attrs.NATIONAL_ROAD_CLASS || null,
              roadUse: attrs.ROAD_USE || null
            }
          })
        );
      }
    }
    if (features.length >= maxFeatures) break;
    if (rows.length < pageSize) break;
    offset += rows.length;
    if (offset > 800000) break;
  }

  const report = makeReport({
    adapter: name,
    province: "ON",
    sourceName: "Ontario MNRF Road Segments",
    sourceUrl: "https://geohub.lio.gov.on.ca/datasets/lio::mnr-road-segments/explore",
    downloadUrl: `${SERVICE}/${LAYER_ID}`,
    license: "Open Government Licence - Ontario",
    sourceDatasetVersion: "LIO_Open09/18",
    status: "ok",
    featureCount: features.length,
    scannedCount: scanned,
    classification,
    excludedByReason,
    notes: [
      "Supplemental MNR resource/recreation roads. Access defaults to motorized_unknown."
    ],
    knownLimitations: [
      "Includes some ORN-sourced conventional roads; freeways are skipped.",
      "Does not assert motorcycle legality."
    ]
  });

  return { features, report };
}

module.exports = { name, run, SERVICE, LAYER_ID };
