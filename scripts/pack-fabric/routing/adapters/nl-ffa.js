"use strict";

/**
 * Newfoundland and Labrador FFA Resource Roads.
 * Source: GeoHub GNL ArcGIS FeatureServer (Open Government Licence - NL).
 * Resource roads stay motorized_unknown; Allow unknown is the legality gate.
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

const name = "nl-ffa-resource-roads";
const SERVICES = [
  {
    region: "NF",
    datasetVersion: "FFA_ResourceRoads_NF/2",
    service:
      "https://services8.arcgis.com/aCyQID5qQcyrJMm2/arcgis/rest/services/FFA_ResourceRoads_NF/FeatureServer/2"
  },
  {
    region: "LB",
    datasetVersion: "FFA_ResourceRoads_LB/0",
    service:
      "https://services8.arcgis.com/aCyQID5qQcyrJMm2/arcgis/rest/services/FFA_ResourceRoads_LB/FeatureServer/0"
  }
];

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
  if (/closed|private|decommission|abandon|no.?motor|non.?motor/i.test(text)) {
    return { ok: false, reason: "restricted_or_closed" };
  }
  if (/atv only|snowmobile only|pedestrian|foot trail|hiking/.test(text)) {
    return { ok: false, reason: "non_motorized_or_atv_only" };
  }

  let surfaceClass = SURFACE_CLASS.resource;
  if (/paved|asphalt|concrete/.test(text)) surfaceClass = SURFACE_CLASS.paved;
  else if (/gravel|unpaved|dirt|earth|loose/.test(text)) surfaceClass = SURFACE_CLASS.gravel;
  else if (/trail|track/.test(text)) surfaceClass = SURFACE_CLASS.track;

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

async function queryLayer(service, offset, pageSize) {
  const params = new URLSearchParams({
    where: "1=1",
    outFields: "*",
    returnGeometry: "true",
    outSR: "4326",
    f: "json",
    resultOffset: String(offset),
    resultRecordCount: String(pageSize)
  });
  return fetchJson(`${service}/query?${params.toString()}`);
}

async function run(options = {}) {
  const pageSize = options.pageSize || 1000;
  const maxFeatures = options.maxFeatures || Infinity;
  const classification = emptyCounts();
  const excludedByReason = {};
  const features = [];
  let scanned = 0;

  for (const source of SERVICES) {
    let offset = 0;
    for (;;) {
      const page = await queryLayer(source.service, offset, pageSize);
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
        const featureId = attrs.OBJECTID || attrs.GLOBALID || `${source.region}-${offset}-${features.length}`;
        for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
          if (features.length >= maxFeatures) break;
          const coords = parts[partIndex];
          const seed = [
            "nl-ffa",
            source.region,
            featureId,
            partIndex,
            coords[0].join(","),
            coords[coords.length - 1].join(",")
          ].join("|");
          const edgeId = "nl-ffa-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
          bump(classification.surface, classified.surfaceClass);
          bump(classification.access, classified.accessClass);
          bump(classification.structure, classified.structureType);
          bump(classification.roadTrack, classified.roadTrackClass);
          features.push(
            createNormalizedEdge({
              edgeId,
              lineageId: `nl-ffa:${source.region}:${featureId}:${partIndex}`,
              province: "NL",
              sourceName: "Newfoundland and Labrador FFA Resource Roads",
              sourceDatasetVersion: source.datasetVersion,
              sourceFeatureId: String(featureId),
              sourceGeometryLineage: source.service,
              geometry: { type: "LineString", coordinates: coords },
              surfaceClass: classified.surfaceClass,
              roadTrackClass: classified.roadTrackClass,
              accessClass: classified.accessClass,
              structureType: classified.structureType,
              sourceConfidence: classified.confidence,
              roadName: attrs.ROAD_NAME || null,
              direction: "both",
              seasonal: /winter|seasonal/i.test(JSON.stringify(attrs)),
              distanceMeters: lineMeters(coords),
              meta: {
                region: source.region,
                roadAccess: attrs.ROAD_ACCESS || null,
                roadClass: attrs.ROAD_CLASS || null,
                roadSurface: attrs.ROAD_SURFACE || null
              }
            })
          );
        }
      }
      if (features.length >= maxFeatures) break;
      offset += rows.length;
      if (page.exceededTransferLimit !== true) break;
      if (offset > 50000) break;
    }
    if (features.length >= maxFeatures) break;
  }

  const report = makeReport({
    adapter: name,
    province: "NL",
    sourceName: "Newfoundland and Labrador FFA Resource Roads",
    sourceUrl: "https://geohub-gnl.hub.arcgis.com",
    downloadUrl: SERVICES.map((s) => s.service).join(","),
    license: "Open Government Licence - Newfoundland and Labrador",
    sourceDatasetVersion: SERVICES.map((s) => s.datasetVersion).join("+"),
    status: "ok",
    featureCount: features.length,
    scannedCount: scanned,
    classification,
    excludedByReason,
    notes: [
      "Resource-road supplement for Newfoundland and Labrador.",
      "Access defaults to motorized_unknown — never invented as permissive."
    ],
    knownLimitations: [
      "ROAD_ACCESS coding is sparse / mixed; legality stays behind Allow unknown.",
      "Surface fields are often null and fall back to resource."
    ]
  });

  return { features, report };
}

module.exports = { name, run, SERVICES };
