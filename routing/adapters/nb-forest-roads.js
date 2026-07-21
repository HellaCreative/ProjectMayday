"use strict";

/**
 * New Brunswick Forest Roads (DNR-ED) — supplemental resource/access edges.
 * Source: gis-erd-der.gnb.ca OpenData/ForestRoads FeatureServer
 * Licence: Open Government Licence - New Brunswick (verify attribution).
 * Access defaults to motorized_unknown. Attributes on the live layer are sparse
 * (OBJECTID, GLOBALID, length only); all kept features map to resource/access.
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

const name = "nb-forest-roads";
const SERVICE =
  "https://gis-erd-der.gnb.ca/server/rest/services/OpenData/ForestRoads/FeatureServer";
const LAYER_ID = 0;

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith("https") ? https : http;
    lib
      .get(url, (res) => {
        if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          fetchJson(res.headers.location).then(resolve, reject);
          return;
        }
        if (res.statusCode !== 200) {
          reject(new Error("HTTP " + res.statusCode + " for " + url));
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
  if (!geometry) return [];
  if (geometry.paths) return geometry.paths.map(normalizeLine).filter((c) => c.length >= 2);
  if (geometry.type === "LineString") {
    return [normalizeLine(geometry.coordinates)].filter((c) => c.length >= 2);
  }
  if (geometry.type === "MultiLineString") {
    return geometry.coordinates.map(normalizeLine).filter((c) => c.length >= 2);
  }
  return [];
}

async function queryLayer(offset, pageSize) {
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
  const pageSize = options.pageSize || 2000;
  const maxFeatures = options.maxFeatures || Infinity;

  const serviceMeta = await fetchJson(`${SERVICE}?f=json`);
  const layerMeta = await fetchJson(`${SERVICE}/${LAYER_ID}?f=json`);
  if (!serviceMeta || !layerMeta || layerMeta.type !== "Feature Layer") {
    throw new Error("NB Forest Roads FeatureServer layer 0 is not live or not a Feature Layer");
  }

  const classification = emptyCounts();
  const excludedByReason = {};
  const features = [];
  let scanned = 0;
  let offset = 0;

  for (;;) {
    const page = await queryLayer(offset, pageSize);
    const rows = page.features || [];
    if (!rows.length) break;

    for (const row of rows) {
      scanned += 1;
      if (features.length >= maxFeatures) break;
      const attrs = row.attributes || {};
      const parts = pathsFromGeometry(row.geometry);
      if (!parts.length) {
        bump(excludedByReason, "no_usable_geometry");
        continue;
      }

      // Live schema has no surface/class fields. Forest Roads are resource access by definition.
      const surfaceClass = SURFACE_CLASS.resource;
      const accessClass = ACCESS_CLASS.motorized_unknown;
      const structureType = STRUCTURE_TYPE.none;
      const roadTrackClass = ROAD_TRACK_CLASS.resource;
      const confidence = SOURCE_CONFIDENCE.medium;

      const featureId =
        attrs.OBJECTID != null
          ? attrs.OBJECTID
          : attrs.GLOBALID || attrs.GlobalID || `${offset}-${features.length}`;

      for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
        const coords = parts[partIndex];
        const seed = ["nb", LAYER_ID, featureId, partIndex, coords[0].join(","), coords[coords.length - 1].join(",")].join(
          "|"
        );
        const edgeId = "nb-fr-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
        bump(classification.surface, surfaceClass);
        bump(classification.access, accessClass);
        bump(classification.structure, structureType);
        bump(classification.roadTrack, roadTrackClass);
        features.push(
          createNormalizedEdge({
            edgeId,
            lineageId: `nb-fr:${LAYER_ID}:${featureId}:${partIndex}`,
            province: "NB",
            sourceName: "New Brunswick Forest Roads (DNR-ED)",
            sourceDatasetVersion: "gnb-forest-roads-featureserver",
            sourceFeatureId: String(featureId),
            sourceGeometryLineage: "featureserver:0",
            geometry: { type: "LineString", coordinates: coords },
            surfaceClass,
            roadTrackClass,
            accessClass,
            structureType,
            sourceConfidence: confidence,
            roadName: null,
            direction: "both",
            seasonal: false,
            distanceMeters: lineMeters(coords),
            meta: {
              globalId: attrs.GLOBALID || attrs.GlobalID || null,
              shapeLength: attrs.Shape__Length != null ? Number(attrs.Shape__Length) : null
            }
          })
        );
      }
    }

    if (features.length >= maxFeatures) break;
    if (rows.length < pageSize) break;
    offset += rows.length;
    if (offset > 500000) break;
  }

  const report = makeReport({
    adapter: name,
    province: "NB",
    sourceName: "New Brunswick Forest Roads (DNR-ED)",
    sourceUrl: "https://hub.arcgis.com/datasets/NBDNR::forestry-roads-chemins-forestiers/about",
    downloadUrl: SERVICE,
    license: "Open Government Licence - New Brunswick",
    sourceDatasetVersion: "gnb-forest-roads-featureserver",
    status: "ok",
    featureCount: features.length,
    scannedCount: scanned,
    classification,
    excludedByReason,
    notes: [
      "Service describes roads not maintained by DTI whose primary purpose is forest-resource access.",
      "Live layer attributes are sparse (OBJECTID/GLOBALID/length). All kept edges map to surface=resource, access=motorized_unknown."
    ],
    knownLimitations: [
      "Does not assert motorcycle legality.",
      "No ATV/snowmobile singletrack (federation / permission-gated sources excluded)."
    ]
  });

  return { features, report };
}

module.exports = { name, run, SERVICE, LAYER_ID };
