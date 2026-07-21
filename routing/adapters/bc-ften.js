"use strict";

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

const name = "bc-ften-roads";
const TYPE_NAME = "WHSE_FOREST_TENURE.FTEN_ROAD_SECTION_LINES_SVW";
// /geo/pub/wfs with typeNames returns HTTP 400; /geo/pub/ows + typeName works.
const WFS = "https://openmaps.gov.bc.ca/geo/pub/ows";

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
          reject(new Error("BC WFS HTTP " + res.statusCode + ": " + text.slice(0, 240)));
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
    req.setTimeout(120000, () => {
      req.destroy(new Error("BC WFS timeout"));
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
  u.searchParams.set("sortBy", "ROAD_SECTION_ID");
  if (startIndex > 0) u.searchParams.set("startIndex", String(startIndex));
  return fetchJson(u.toString());
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
    // BCGW may return BC Albers; skip absurd lon/lat.
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

async function run(options = {}) {
  const pageSize = options.pageSize || 100;
  const maxFeatures = options.maxFeatures || Infinity;
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
      const props = row.properties || {};
      const life = String(props.LIFE_CYCLE_STATUS_CODE || props.FILE_STATUS_CODE || "").toUpperCase();
      if (life === "RETIRED" || life === "DEACTIVATED" || life === "CANCELLED") {
        bump(excludedByReason, "deactivated_or_closed");
        continue;
      }
      if (props.RETIREMENT_DATE) {
        bump(excludedByReason, "deactivated_or_closed");
        continue;
      }
      const parts = geometryParts(row.geometry);
      if (!parts.length) {
        bump(excludedByReason, "no_usable_geometry");
        continue;
      }
      const featureId = props.ROAD_SECTION_ID || props.OBJECTID || row.id || scanned;
      for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
        const coords = parts[partIndex];
        const seed = ["bc-ften", featureId, partIndex, coords[0].join(","), coords[coords.length - 1].join(",")].join("|");
        const edgeId = "bc-ften-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
        bump(classification.surface, SURFACE_CLASS.resource);
        bump(classification.access, ACCESS_CLASS.motorized_unknown);
        bump(classification.structure, STRUCTURE_TYPE.none);
        bump(classification.roadTrack, ROAD_TRACK_CLASS.resource);
        features.push(
          createNormalizedEdge({
            edgeId,
            lineageId: `bc-ften:${featureId}:${partIndex}`,
            province: "BC",
            sourceName: "BC Forest Tenure Road Section Lines",
            sourceDatasetVersion: "FTEN_ROAD_SECTION_LINES_SVW",
            sourceFeatureId: String(featureId),
            sourceGeometryLineage: TYPE_NAME,
            geometry: { type: "LineString", coordinates: coords },
            surfaceClass: SURFACE_CLASS.resource,
            roadTrackClass: ROAD_TRACK_CLASS.resource,
            accessClass: ACCESS_CLASS.motorized_unknown,
            structureType: STRUCTURE_TYPE.none,
            sourceConfidence: SOURCE_CONFIDENCE.medium,
            roadName: props.ROAD_SECTION_NAME || props.ROAD_NAME || props.MAP_LABEL || null,
            direction: "both",
            seasonal: false,
            distanceMeters: lineMeters(coords),
            meta: { lifeCycleStatus: props.LIFE_CYCLE_STATUS_CODE || null }
          })
        );
      }
    }

    if (features.length >= maxFeatures) break;
    if (rows.length < pageSize) break;
    startIndex += rows.length;
    if (startIndex > 2000000) break;
  }

  const report = makeReport({
    adapter: name,
    province: "BC",
    sourceName: "BC Forest Tenure Road Section Lines",
    sourceUrl: "https://catalogue.data.gov.bc.ca/dataset/forest-tenure-road-section-lines",
    downloadUrl: WFS,
    license: "Open Government Licence - British Columbia",
    sourceDatasetVersion: "FTEN_ROAD_SECTION_LINES_SVW",
    status: "ok",
    featureCount: features.length,
    scannedCount: scanned,
    classification,
    excludedByReason,
    notes: [
      "Supplemental forestry/resource roads. Access is motorized_unknown — never invented as permissive."
    ],
    knownLimitations: [
      "Tenure roads are not a guarantee of public motorcycle access.",
      "DRA demographic roads not yet conflated in this adapter."
    ]
  });

  return { features, report };
}

module.exports = { name, run, WFS, TYPE_NAME };
