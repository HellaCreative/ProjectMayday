#!/usr/bin/env node
"use strict";

/**
 * OSM road fabric — motorized roads from Geofabrik extracts.
 *
 * Product role: the driveable basemap network (paved/gravel/dirt/service).
 * Always motorized_permissive when included. Surface/class = visuals + costing.
 * Conflation: after NRN (NRN keeps identity on overlaps), before provincial
 * capillary that fills *between* OSM roads. Not a wholesale NRN replace.
 *
 * Excluded: foot/bike-only, private/no, abandoned, pure path without motor tags.
 * Licence: OpenStreetMap contributors (ODbL).
 *
 * Usage (via build script):
 *   node -e "require('./routing/adapters/osm-roads').run({ inputPath, province })"
 */
const fs = require("fs");
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

const name = "osm-roads";

const INCLUDE_HIGHWAY = new Set([
  "motorway",
  "motorway_link",
  "trunk",
  "trunk_link",
  "primary",
  "primary_link",
  "secondary",
  "secondary_link",
  "tertiary",
  "tertiary_link",
  "unclassified",
  "residential",
  "living_street",
  "road",
  "service",
  "track"
]);

const PAVED_SURFACE = new Set([
  "paved",
  "asphalt",
  "concrete",
  "concrete:plates",
  "concrete:lanes",
  "paving_stones",
  "sett",
  "cobblestone",
  "metal",
  "wood"
]);

const GRAVEL_SURFACE = new Set([
  "gravel",
  "fine_gravel",
  "compacted",
  "pebblestone",
  "stone",
  "chipseal"
]);

const RESOURCE_SURFACE = new Set([
  "dirt",
  "ground",
  "earth",
  "mud",
  "sand",
  "grass",
  "unpaved",
  "woodchips"
]);

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

function tag(props, key) {
  const v = props[key];
  if (v == null || v === "") return "";
  return String(v).toLowerCase().trim();
}

function isDenied(props) {
  const access = tag(props, "access");
  const motor = tag(props, "motor_vehicle") || tag(props, "motorcar") || tag(props, "motorcycle");
  const vehicle = tag(props, "vehicle");
  for (const v of [access, motor, vehicle]) {
    if (v === "no" || v === "private" || v === "agricultural" || v === "forestry") {
      // forestry/agricultural alone on a track can still be dual-sport relevant —
      // only hard-deny explicit no/private here; forestry handled softer below.
      if (v === "no" || v === "private") return "access_denied";
    }
  }
  if (tag(props, "abandoned") === "yes" || tag(props, "disused") === "yes") return "abandoned";
  if (tag(props, "highway") === "abandoned") return "abandoned";
  // Foot/bike-only without motor permission.
  const hw = tag(props, "highway");
  if (hw === "footway" || hw === "cycleway" || hw === "path" || hw === "pedestrian" || hw === "steps") {
    if (!/yes|designated|permissive|destination/.test(motor) && !/yes|designated|permissive/.test(tag(props, "motorcycle"))) {
      return "foot_bike_only";
    }
  }
  return null;
}

function classify(props) {
  const denied = isDenied(props);
  if (denied) return { ok: false, reason: denied };

  const hw = tag(props, "highway");
  if (!INCLUDE_HIGHWAY.has(hw)) return { ok: false, reason: "highway_excluded" };

  // Pure path/track without any motor hint stays out when tagged as path already handled;
  // track with motor_vehicle=no already denied.
  if (hw === "path") return { ok: false, reason: "pure_path" };

  const surface = tag(props, "surface");
  let surfaceClass = SURFACE_CLASS.unknown;
  let roadTrackClass = ROAD_TRACK_CLASS.local;
  let accessClass = ACCESS_CLASS.motorized_permissive;
  let confidence = SOURCE_CONFIDENCE.medium;

  // Locked Carto categories for DIRT fabric preference
  // (https://wiki.openstreetmap.org/wiki/OpenStreetMap_Carto/Lines):
  //   1. Major roads — motorway…unclassified
  //   2. City roads — residential / living_street / service
  //   3. Agricultural/forestry — highway=track (tracktype grade1–5 / unknown)
  // Packed class:
  //   freeway/ramp ≈ motorway(+link)
  //   arterial     ≈ trunk / primary (upper major — Clean OK, adventure avoid)
  //   collector    ≈ secondary (mid major)
  //   local        ≈ tertiary / unclassified (lower major — adventure preferred)
  //   service      ≈ residential / living_street / service (city — connector only)
  //   track        ≈ agricultural/forestry tracks
  if (/motorway/.test(hw)) roadTrackClass = /_link$/.test(hw) ? ROAD_TRACK_CLASS.ramp : ROAD_TRACK_CLASS.freeway;
  else if (/trunk|primary/.test(hw))
    roadTrackClass = /_link$/.test(hw) ? ROAD_TRACK_CLASS.ramp : ROAD_TRACK_CLASS.arterial;
  else if (/secondary/.test(hw))
    roadTrackClass = /_link$/.test(hw) ? ROAD_TRACK_CLASS.ramp : ROAD_TRACK_CLASS.collector;
  else if (/tertiary/.test(hw))
    roadTrackClass = /_link$/.test(hw) ? ROAD_TRACK_CLASS.ramp : ROAD_TRACK_CLASS.local;
  else if (hw === "unclassified" || hw === "road") roadTrackClass = ROAD_TRACK_CLASS.local;
  else if (hw === "track") roadTrackClass = ROAD_TRACK_CLASS.track;
  else if (hw === "service" || hw === "residential" || hw === "living_street")
    roadTrackClass = ROAD_TRACK_CLASS.service;

  if (PAVED_SURFACE.has(surface)) {
    surfaceClass = SURFACE_CLASS.paved;
  } else if (GRAVEL_SURFACE.has(surface)) {
    surfaceClass = SURFACE_CLASS.gravel;
  } else if (RESOURCE_SURFACE.has(surface)) {
    surfaceClass = SURFACE_CLASS.resource;
    if (roadTrackClass === ROAD_TRACK_CLASS.local) roadTrackClass = ROAD_TRACK_CLASS.resource;
  } else if (hw === "track" || hw === "service") {
    // No surface tag: treat as undeveloped for dirt costing.
    surfaceClass = SURFACE_CLASS.resource;
    confidence = SOURCE_CONFIDENCE.medium;
  } else if (/motorway|trunk|primary/.test(hw)) {
    // Only invent paved for true highway hierarchy.
    surfaceClass = SURFACE_CLASS.paved;
  } else {
    // secondary/tertiary/unclassified/residential/road with no surface tag:
    // unknown — do not invent asphalt (QC rural often untagged).
    surfaceClass = SURFACE_CLASS.unknown;
  }

  if (tag(props, "bridge") === "yes") {
    return {
      ok: true,
      surfaceClass,
      accessClass,
      structureType: STRUCTURE_TYPE.bridge,
      roadTrackClass,
      confidence
    };
  }
  if (tag(props, "tunnel") === "yes") {
    return {
      ok: true,
      surfaceClass,
      accessClass,
      structureType: STRUCTURE_TYPE.tunnel,
      roadTrackClass,
      confidence
    };
  }

  return {
    ok: true,
    surfaceClass,
    accessClass,
    structureType: STRUCTURE_TYPE.none,
    roadTrackClass,
    confidence
  };
}

function lineStringsFromGeometry(geom) {
  if (!geom) return [];
  if (geom.type === "LineString") {
    const line = normalizeLine(geom.coordinates || []);
    return line.length >= 2 ? [line] : [];
  }
  if (geom.type === "MultiLineString") {
    const out = [];
    for (const part of geom.coordinates || []) {
      const line = normalizeLine(part);
      if (line.length >= 2) out.push(line);
    }
    return out;
  }
  return [];
}

async function run(options = {}) {
  const inputPath = options.inputPath;
  const province = String(options.province || "").toUpperCase();
  if (!inputPath || !fs.existsSync(inputPath)) {
    throw new Error("osm-roads requires inputPath to a GeoJSON sequence file");
  }
  if (!province) throw new Error("osm-roads requires province");

  const classification = emptyCounts();
  const excludedByReason = {};
  const features = [];
  let scanned = 0;

  const rl = readline.createInterface({
    input: fs.createReadStream(inputPath, { encoding: "utf8" }),
    crlfDelay: Infinity
  });

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    // geojsonseq may be RS-delimited (\x1e) or newline JSON.
    const jsonText = trimmed.charCodeAt(0) === 0x1e ? trimmed.slice(1) : trimmed;
    if (!jsonText) continue;
    let feat;
    try {
      feat = JSON.parse(jsonText);
    } catch (_) {
      bump(excludedByReason, "json_parse");
      continue;
    }
    scanned += 1;
    const props = feat.properties || {};
    const classified = classify(props);
    if (!classified.ok) {
      bump(excludedByReason, classified.reason || "excluded");
      continue;
    }
    const parts = lineStringsFromGeometry(feat.geometry);
    if (!parts.length) {
      bump(excludedByReason, "no_usable_geometry");
      continue;
    }

    const osmId =
      props["@id"] ||
      props.id ||
      props.osm_id ||
      props.osm_way_id ||
      `${scanned}`;

    for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
      const coords = parts[partIndex];
      const seed = ["osm", province, osmId, partIndex, coords[0].join(","), coords[coords.length - 1].join(",")].join(
        "|"
      );
      const edgeId = "osm-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
      bump(classification.surface, classified.surfaceClass);
      bump(classification.access, classified.accessClass);
      bump(classification.structure, classified.structureType);
      bump(classification.roadTrack, classified.roadTrackClass);
      features.push(
        createNormalizedEdge({
          edgeId,
          lineageId: `osm:${province}:${osmId}:${partIndex}`,
          province,
          sourceName: "OpenStreetMap",
          sourceDatasetVersion: options.datasetVersion || "geofabrik-extract",
          sourceFeatureId: String(osmId),
          sourceGeometryLineage: "osm-way",
          geometry: { type: "LineString", coordinates: coords },
          surfaceClass: classified.surfaceClass,
          roadTrackClass: classified.roadTrackClass,
          accessClass: classified.accessClass,
          structureType: classified.structureType,
          sourceConfidence: classified.confidence,
          roadName: props.name || props.ref || null,
          direction: "both",
          seasonal: false,
          distanceMeters: lineMeters(coords),
          meta: {
            highway: tag(props, "highway"),
            surface: tag(props, "surface") || null,
            gapFill: true
          }
        })
      );
    }
  }

  const report = makeReport({
    adapter: name,
    province,
    sourceName: "OpenStreetMap",
    sourceUrl: options.sourceUrl || "https://www.openstreetmap.org",
    downloadUrl: options.downloadUrl || options.sourceUrl || null,
    license: "OpenStreetMap contributors (ODbL)",
    sourceDatasetVersion: options.datasetVersion || "geofabrik-extract",
    status: "ok",
    featureCount: features.length,
    scannedCount: scanned,
    classification,
    excludedByReason,
    notes: [
      "OSM gap-fill for conventional motorized roads unmatched by NRN.",
      "Excluded foot/bike-only, private/no, abandoned, and non-motorized paths.",
      "track/service without clear surface default to motorized_unknown."
    ],
    knownLimitations: [
      "OSM tagging quality varies; not a legal access assertion.",
      "Does not replace NRN identity — conflation dedupes against NRN first."
    ]
  });

  return { features, report };
}

module.exports = {
  name,
  run,
  classify,
  INCLUDE_HIGHWAY
};
