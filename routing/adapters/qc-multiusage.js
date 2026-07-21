"use strict";

/**
 * Québec chemins multiusages (AQréseau+) — forest multi-use road supplement.
 * Source: MRNF ArcGIS MapServer (données ouvertes Québec)
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

const name = "qc-multiusage";
const SERVICE =
  "https://servicescarto.mrnf.gouv.qc.ca/pes/rest/services/Territoire/AQreseauPlus_WMS/MapServer";
const LAYER_ID = 37; // Chemin Multiusage — Oui

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
  const notes = String(attrs.Notes || attrs.Gestion || attrs.Stat_Pont || "").toLowerCase();
  if (/fermé|ferme|closed|abandon|priv[eé]|interdit/.test(notes)) {
    return { ok: false, reason: "restricted_or_closed" };
  }
  const caract = String(attrs.CaractRte || attrs.Cls_CheFor || attrs.Che_Multi || "").toLowerCase();
  let surfaceClass = SURFACE_CLASS.resource;
  let roadTrackClass = ROAD_TRACK_CLASS.resource;
  if (/pav[eé]|asphalte|b[eé]ton/.test(caract)) {
    surfaceClass = SURFACE_CLASS.paved;
    roadTrackClass = ROAD_TRACK_CLASS.local;
  } else if (/gravier|gravel|non.?pav/.test(caract)) {
    surfaceClass = SURFACE_CLASS.gravel;
  } else if (/sentier|piste|track/.test(caract)) {
    surfaceClass = SURFACE_CLASS.track;
    roadTrackClass = ROAD_TRACK_CLASS.track;
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
    const page = await query(offset, pageSize);
    if (page.error) {
      throw new Error("QC MapServer error: " + JSON.stringify(page.error));
    }
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
      const featureId = attrs.AQRP_UUID || attrs.OBJECTID || attrs.NoRte || `${offset}-${features.length}`;
      for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
        const coords = parts[partIndex];
        const seed = ["qc-mu", featureId, partIndex, coords[0].join(","), coords[coords.length - 1].join(",")].join("|");
        const edgeId = "qc-mu-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
        bump(classification.surface, classified.surfaceClass);
        bump(classification.access, classified.accessClass);
        bump(classification.structure, classified.structureType);
        bump(classification.roadTrack, classified.roadTrackClass);
        features.push(
          createNormalizedEdge({
            edgeId,
            lineageId: `qc-mu:${featureId}:${partIndex}`,
            province: "QC",
            sourceName: "Québec Chemins Multiusages (AQréseau+)",
            sourceDatasetVersion: "AQreseauPlus/37",
            sourceFeatureId: String(featureId),
            sourceGeometryLineage: `mapserver:${LAYER_ID}`,
            geometry: { type: "LineString", coordinates: coords },
            surfaceClass: classified.surfaceClass,
            roadTrackClass: classified.roadTrackClass,
            accessClass: classified.accessClass,
            structureType: classified.structureType,
            sourceConfidence: classified.confidence,
            roadName: attrs.NomRte || attrs.NoRte || null,
            direction: "both",
            seasonal: false,
            distanceMeters: lineMeters(coords),
            meta: {
              clsCheFor: attrs.Cls_CheFor || null,
              gestion: attrs.Gestion || null
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
    province: "QC",
    sourceName: "Québec Chemins Multiusages (AQréseau+)",
    sourceUrl: "https://mrnf.gouv.qc.ca/repertoire-geographique/adresses-quebec-reseaux-transport/",
    downloadUrl: `${SERVICE}/${LAYER_ID}`,
    license: "Licence Creative Commons CC-BY 4.0 / données ouvertes Québec",
    sourceDatasetVersion: "AQreseauPlus/37",
    status: "ok",
    featureCount: features.length,
    scannedCount: scanned,
    classification,
    excludedByReason,
    notes: [
      "Forest multi-use roads. Access defaults to motorized_unknown — never invented as permissive."
    ],
    knownLimitations: [
      "Condition of multiusage roads is not field-verified in source.",
      "Does not assert motorcycle legality."
    ]
  });

  return { features, report };
}

module.exports = { name, run, SERVICE, LAYER_ID };
