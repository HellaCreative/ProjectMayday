"use strict";

/**
 * Alberta Access and Facility Roads — supplemental resource/access edges.
 * Source: geospatial.alberta.ca MapServer (Open Government Licence - Alberta)
 * Access is motorized_unknown unless attributes clearly indicate public highway.
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

const name = "ab-access-roads";
const SERVICE =
  "https://geospatial.alberta.ca/titan/rest/services/utility/access/MapServer";

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
  if (!geometry) return [];
  if (geometry.paths) return geometry.paths.map(normalizeLine).filter((c) => c.length >= 2);
  if (geometry.type === "LineString") return [normalizeLine(geometry.coordinates)].filter((c) => c.length >= 2);
  if (geometry.type === "MultiLineString") {
    return geometry.coordinates.map(normalizeLine).filter((c) => c.length >= 2);
  }
  return [];
}

function classifyAttrs(attrs) {
  const text = JSON.stringify(attrs || {}).toLowerCase();
  if (/closed|decommission|abandoned|private|restricted|no.?motor/i.test(text)) {
    return { ok: false, reason: "restricted_or_closed" };
  }
  // Cutlines are discovery/QA only — never auto-route without legal corroboration.
  if (/cutline|cut.?line|seismic/.test(text)) {
    return { ok: false, reason: "cutline_not_routable" };
  }
  let surfaceClass = SURFACE_CLASS.resource;
  if (/paved|asphalt|concrete/.test(text)) surfaceClass = SURFACE_CLASS.paved;
  else if (/gravel|unpaved|dirt|earth/.test(text)) surfaceClass = SURFACE_CLASS.gravel;
  else if (/track|trail/.test(text)) surfaceClass = SURFACE_CLASS.track;

  return {
    ok: true,
    surfaceClass,
    accessClass: ACCESS_CLASS.motorized_unknown,
    structureType: STRUCTURE_TYPE.none,
    roadTrackClass:
      surfaceClass === SURFACE_CLASS.track ? ROAD_TRACK_CLASS.track : ROAD_TRACK_CLASS.resource,
    confidence: SOURCE_CONFIDENCE.medium
  };
}

async function queryLayer(layerId, offset, pageSize) {
  const params = new URLSearchParams({
    where: "1=1",
    outFields: "*",
    returnGeometry: "true",
    outSR: "4326",
    f: "json",
    resultOffset: String(offset),
    resultRecordCount: String(pageSize)
  });
  return fetchJson(`${SERVICE}/${layerId}/query?${params.toString()}`);
}

async function run(options = {}) {
  const pageSize = options.pageSize || 1000;
  const maxFeatures = options.maxFeatures || Infinity;
  const meta = await fetchJson(`${SERVICE}?f=json`);
  // Feature layers only (group layers 0/24 return no geometries).
  // 23 = Gravel Road (20K), 26 = Other Road. Never 30 Cutline.
  const preferredLayerIds = options.layerIds || [23, 26];
  const layers = (meta.layers || []).filter(
    (l) => l && preferredLayerIds.includes(l.id)
  );
  if (!layers.length) {
    throw new Error("Alberta access MapServer returned no layers");
  }

  const classification = emptyCounts();
  const excludedByReason = {};
  const features = [];
  let scanned = 0;

  for (const layer of layers) {
    let offset = 0;
    for (;;) {
      const page = await queryLayer(layer.id, offset, pageSize);
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
        const featureId =
          attrs.OBJECTID || attrs.ObjectID || attrs.FID || `${layer.id}-${offset}-${features.length}`;
        for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
          const coords = parts[partIndex];
          const seed = ["ab", layer.id, featureId, partIndex, coords[0].join(","), coords[coords.length - 1].join(",")].join("|");
          const edgeId = "ab-afr-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
          bump(classification.surface, classified.surfaceClass);
          bump(classification.access, classified.accessClass);
          bump(classification.structure, classified.structureType);
          bump(classification.roadTrack, classified.roadTrackClass);
          features.push(
            createNormalizedEdge({
              edgeId,
              lineageId: `ab-afr:${layer.id}:${featureId}:${partIndex}`,
              province: "AB",
              sourceName: "Alberta Access and Facility Roads",
              sourceDatasetVersion: "alberta-titan-access",
              sourceFeatureId: String(featureId),
              sourceGeometryLineage: `mapserver:${layer.id}`,
              geometry: { type: "LineString", coordinates: coords },
              surfaceClass: classified.surfaceClass,
              roadTrackClass: classified.roadTrackClass,
              accessClass: classified.accessClass,
              structureType: classified.structureType,
              sourceConfidence: classified.confidence,
              roadName: attrs.ROAD_NAME || attrs.NAME || attrs.ROADNAME || null,
              direction: "both",
              seasonal: /winter|seasonal/i.test(JSON.stringify(attrs)),
              distanceMeters: lineMeters(coords),
              meta: { layerId: layer.id, layerName: layer.name }
            })
          );
        }
      }
      if (features.length >= maxFeatures) break;
      offset += rows.length;
      // Continue only while ArcGIS reports more pages remain.
      if (page.exceededTransferLimit !== true) break;
      if (offset > 500000) break;
    }
    if (features.length >= maxFeatures) break;
  }

  const report = makeReport({
    adapter: name,
    province: "AB",
    sourceName: "Alberta Access and Facility Roads",
    sourceUrl: "https://www.alberta.ca/provincial-geospatial-centre",
    downloadUrl: SERVICE,
    license: "Open Government Licence - Alberta",
    sourceDatasetVersion: "alberta-titan-access",
    status: "ok",
    featureCount: features.length,
    scannedCount: scanned,
    classification,
    excludedByReason,
    notes: [
      "Supplemental resource/access roads. Access defaults to motorized_unknown — never invented as permissive."
    ],
    knownLimitations: [
      "Attribute schemas vary by MapServer layer; closed/private cues are best-effort.",
      "Does not assert motorcycle legality."
    ]
  });

  return { features, report };
}

module.exports = { name, run, SERVICE };
