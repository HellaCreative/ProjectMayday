#!/usr/bin/env node
"use strict";

/**
 * OSM road fabric — motorized + dual-sport ways from Geofabrik extracts.
 *
 * Product role: the driveable basemap network (paved/gravel/dirt/service) plus
 * adventure ways (track + path). Standard roads use explicit OSM access where
 * present; legacy CanVec track/service imports without it are unknown. Positive
 * atv marks adventure trails as permissive (overrides vehicle-type deny; never
 * overrides access=private|no).
 * Untagged path is motorized_unknown and search-gated by Allow unknown.
 * Conflation: after NRN (NRN keeps identity on overlaps), before provincial
 * capillary that fills *between* OSM roads. Not a wholesale NRN replace.
 *
 * Excluded: footway / pedestrian / steps, cycleway, private/no, abandoned.
 * highway=path is kept (Allow unknown gates untagged motor legality at search).
 * Licence: OpenStreetMap contributors (ODbL).
 *
 * Options:
 *   includeAdventurePaths (default true) — keep highway=path
 *   (footway always excluded; cycleway never included)
 *
 * Usage (via build script):
 *   node -e "require('./routing/adapters/osm-roads').run({ inputPath, province })"
 */
const fs = require("fs");
const readline = require("readline");
const crypto = require("crypto");
const {
  createNormalizedEdge,
  normalizeLeafString,
  normalizeLayer
} = require("../schema/edge");
const {
  SURFACE_CLASS,
  ACCESS_CLASS,
  STRUCTURE_TYPE,
  ROAD_TRACK_CLASS,
  SOURCE_CONFIDENCE
} = require("../schema/enums");
const { bump, makeReport, emptyCounts } = require("./contract");
const {
  LEAF_NOT_APPLICABLE,
  ferryCrossingSeconds
} = require("../lib/ferry");
const { structureFromTags } = require("../lib/structure");
const { travelDirectionFromOsmTags } = require("../lib/travel-direction");

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
  "track",
  // Adventure: keep all track and path. cycleway dropped (LOCKED TAXONOMY 2026-08-23).
  "path"
]);

const POSITIVE_ATV = new Set(["yes", "designated", "permissive"]);
const HARD_LAND_DENY = new Set(["private", "no"]);
const VEHICLE_TYPE_ACCESS_KEYS = new Set(["motorcycle", "motor_vehicle", "vehicle"]);

const PAVED_SURFACE = new Set([
  "paved",
  "asphalt",
  "concrete",
  "concrete:plates",
  "concrete:lanes",
  "paving_stones",
  "sett",
  "cobblestone",
  "unhewn_cobblestone",
  "brick",
  "bricks",
  "chipseal",
  "sealcoat",
  "metal",
  "metal_grid",
  "steel",
  "boardwalk",
  "rubber",
  "wood"
]);

const GRAVEL_SURFACE = new Set([
  "gravel",
  "fine_gravel",
  "compacted",
  "pebblestone",
  "stone",
  "loose_gravel",
  "crushed_stone"
]);

const RESOURCE_SURFACE = new Set([
  "dirt",
  "ground",
  "earth",
  "mud",
  "sand",
  "grass",
  "unpaved",
  "woodchips",
  "bare_rock",
  "rock",
  "clay",
  "soil",
  "natural",
  "stones",
  "shale"
]);

const ACCESS_ALLOWED = new Set(["yes", "designated", "permissive", "official"]);
const ACCESS_DENIED = new Set([
  "no",
  "private",
  "agricultural",
  "forestry",
  "delivery",
  "customers",
  "permit",
  "emergency",
  "employees",
  "restricted",
  "military",
  "residents",
  "psv",
  "foot",
  "construction",
  "closed",
  "destination"
]);
const ACCESS_UNKNOWN = new Set([
  "unknown",
  "conditional",
  "discouraged",
  "seasonal",
  "tidal"
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

/** OSM access precedence: motorcycle > motor_vehicle > vehicle > access. */
function effectiveMotorcycleAccess(props) {
  for (const key of ["motorcycle", "motor_vehicle", "vehicle", "access"]) {
    const value = tag(props, key);
    if (value) return { key, value };
  }
  return { key: null, value: "" };
}

function positiveAtv(props) {
  return POSITIVE_ATV.has(tag(props, "atv"));
}

/**
 * Historic Canadian government road imports can remain in OSM long after the
 * mapped track has stopped being a public motor road. The source tag is useful
 * provenance, but is never permission.
 */
function isLegacyCanVecImport(props) {
  return [tag(props, "source"), tag(props, "source:geometry")]
    .some((value) => value.includes("canvec"));
}

/** Hard land deny — atv must never override these. */
function hardLandDeny(props) {
  return HARD_LAND_DENY.has(tag(props, "access"));
}

function isDenied(props) {
  const effective = effectiveMotorcycleAccess(props);
  if (ACCESS_DENIED.has(effective.value)) {
    // Positive atv overrides vehicle-type deny (motorcycle/motor_vehicle/vehicle=no, …)
    // but never a hard land deny (access=private|no), even when another key won precedence.
    const vehicleTypeDeny = VEHICLE_TYPE_ACCESS_KEYS.has(effective.key);
    if (positiveAtv(props) && vehicleTypeDeny && !hardLandDeny(props)) {
      // Adventure/ATV trail — permitted despite vehicle-type deny.
    } else {
      return "access_restricted";
    }
  }
  if (tag(props, "abandoned") === "yes" || tag(props, "disused") === "yes") return "abandoned";
  if (tag(props, "highway") === "abandoned") return "abandoned";
  // Always drop pedestrian foot infrastructure (not dual-sport).
  const hw = tag(props, "highway");
  if (hw === "footway" || hw === "pedestrian" || hw === "steps") {
    return "foot_bike_only";
  }
  return null;
}

/**
 * Normalize an explicit OSM surface value without letting road type overwrite it.
 * Mixed or unrecognized values remain unknown; guessing here corrupts both route
 * scoring and the percentage shown to the rider.
 */
function explicitSurfaceClass(surface) {
  if (!surface) return null;
  const tokens = String(surface)
    .toLowerCase()
    .split(/[;,]/)
    .map((value) => value.trim())
    .filter(Boolean);
  if (!tokens.length) return null;
  const classes = new Set();
  for (const value of tokens) {
    if (PAVED_SURFACE.has(value)) classes.add(SURFACE_CLASS.paved);
    else if (GRAVEL_SURFACE.has(value)) classes.add(SURFACE_CLASS.gravel);
    else if (RESOURCE_SURFACE.has(value)) classes.add(SURFACE_CLASS.resource);
    else return SURFACE_CLASS.unknown;
  }
  return classes.size === 1 ? classes.values().next().value : SURFACE_CLASS.unknown;
}

/**
 * OSM route=ferry ways (not highway=*). Timed connectors — not dirt fabric.
 */
function classifyFerry(props) {
  if (tag(props, "route") !== "ferry") return null;
  for (const key of ["motorcar", "motor_vehicle", "motorcycle"]) {
    if (tag(props, key) === "no") return { ok: false, reason: "ferry_vehicle_denied" };
  }
  if (hardLandDeny(props)) return { ok: false, reason: "access_restricted" };
  const effective = effectiveMotorcycleAccess(props);
  if (ACCESS_DENIED.has(effective.value)) {
    return { ok: false, reason: "access_restricted" };
  }
  let accessClass = ACCESS_CLASS.motorized_permissive;
  let confidence = SOURCE_CONFIDENCE.medium;
  if (ACCESS_UNKNOWN.has(effective.value)) {
    accessClass = ACCESS_CLASS.motorized_unknown;
    confidence = SOURCE_CONFIDENCE.low;
  }
  return {
    ok: true,
    isFerry: true,
    surfaceClass: SURFACE_CLASS.unknown,
    accessClass,
    structureType: STRUCTURE_TYPE.ferry,
    roadTrackClass: ROAD_TRACK_CLASS.unknown,
    confidence
  };
}

function classify(props, options = {}) {
  const ferry = classifyFerry(props);
  if (ferry) return ferry;

  const denied = isDenied(props);
  if (denied) return { ok: false, reason: denied };

  const hw = tag(props, "highway");
  const includeAdventure = options.includeAdventurePaths !== false;
  if (!INCLUDE_HIGHWAY.has(hw)) return { ok: false, reason: "highway_excluded" };
  if (!includeAdventure && hw === "path") {
    return { ok: false, reason: "adventure_paths_disabled" };
  }

  const surface = tag(props, "surface");
  let surfaceClass = SURFACE_CLASS.unknown;
  let roadTrackClass = ROAD_TRACK_CLASS.local;
  let accessClass = ACCESS_CLASS.motorized_permissive;
  let confidence = SOURCE_CONFIDENCE.medium;
  const effectiveAccess = effectiveMotorcycleAccess(props);
  const atvOk = positiveAtv(props);

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
  //   track        ≈ agricultural/forestry tracks + atv-positive path
  if (/motorway/.test(hw)) roadTrackClass = /_link$/.test(hw) ? ROAD_TRACK_CLASS.ramp : ROAD_TRACK_CLASS.freeway;
  else if (/trunk|primary/.test(hw))
    roadTrackClass = /_link$/.test(hw) ? ROAD_TRACK_CLASS.ramp : ROAD_TRACK_CLASS.arterial;
  else if (/secondary/.test(hw))
    roadTrackClass = /_link$/.test(hw) ? ROAD_TRACK_CLASS.ramp : ROAD_TRACK_CLASS.collector;
  else if (/tertiary/.test(hw))
    roadTrackClass = /_link$/.test(hw) ? ROAD_TRACK_CLASS.ramp : ROAD_TRACK_CLASS.local;
  else if (hw === "unclassified" || hw === "road") roadTrackClass = ROAD_TRACK_CLASS.local;
  else if (hw === "track" || hw === "path") roadTrackClass = ROAD_TRACK_CLASS.track;
  else if (hw === "service" || hw === "residential" || hw === "living_street")
    roadTrackClass = ROAD_TRACK_CLASS.service;

  if (atvOk) {
    // Adventure/ATV trail — permitted (overrides vehicle-type deny already handled in isDenied).
    accessClass = ACCESS_CLASS.motorized_permissive;
  } else if (ACCESS_UNKNOWN.has(effectiveAccess.value)) {
    accessClass = ACCESS_CLASS.motorized_unknown;
    confidence = SOURCE_CONFIDENCE.low;
  } else if (
    !effectiveAccess.value &&
    (hw === "track" || hw === "service") &&
    isLegacyCanVecImport(props)
  ) {
    // CanVec proves only that a line existed in the imported government data.
    // Without explicit OSM motor access, require the rider's Allow unknown choice.
    accessClass = ACCESS_CLASS.motorized_unknown;
    confidence = SOURCE_CONFIDENCE.low;
  } else if (hw === "path") {
    // Untagged / non-atv path: motorized_unknown, gated by Allow unknown at search.
    if (ACCESS_ALLOWED.has(effectiveAccess.value) || atvOk) {
      accessClass = ACCESS_CLASS.motorized_permissive;
    } else {
      accessClass = ACCESS_CLASS.motorized_unknown;
      confidence = SOURCE_CONFIDENCE.low;
    }
  }

  const explicitSurface = explicitSurfaceClass(surface);
  if (explicitSurface) {
    surfaceClass = explicitSurface;
    if (explicitSurface === SURFACE_CLASS.resource && roadTrackClass === ROAD_TRACK_CLASS.local) {
      roadTrackClass = ROAD_TRACK_CLASS.resource;
    }
  } else if (/motorway|trunk|primary|secondary|tertiary/.test(hw)) {
    // Conventional OSM road default. Untagged minor/service/track ways remain
    // unknown; roadTrackClass can guide search without inventing their surface.
    surfaceClass = SURFACE_CLASS.paved;
    confidence = SOURCE_CONFIDENCE.low;
  } else {
    // unclassified / residential / service / track / path with no surface tag.
    surfaceClass = SURFACE_CLASS.unknown;
    confidence = SOURCE_CONFIDENCE.low;
  }

  const structure = structureFromTags({
    bridge: tag(props, "bridge"),
    tunnel: tag(props, "tunnel"),
    ford: tag(props, "ford")
  });

  return {
    ok: true,
    surfaceClass,
    accessClass,
    structureType: structure.structureType,
    roadTrackClass,
    confidence
  };
}

/**
 * OSM leaf fields for Graph-v3 — preserved alongside coarse family/class.
 * Does not alter surfaceClass / roadTrackClass / structureType derivation.
 */
function leafFieldsFromProps(props) {
  const surfaceLeaf = normalizeLeafString(tag(props, "surface"));
  const roadClassLeaf = normalizeLeafString(tag(props, "highway")) || "unknown";
  const tracktype = normalizeLeafString(tag(props, "tracktype"));
  const smoothness = normalizeLeafString(tag(props, "smoothness"));
  const layer = normalizeLayer(tag(props, "layer"));
  const structure = structureFromTags({
    bridge: tag(props, "bridge"),
    tunnel: tag(props, "tunnel"),
    ford: tag(props, "ford")
  });
  const structureLeaf = structure.structureLeaf;
  const effective = effectiveMotorcycleAccess(props);
  const accessLeaf = normalizeLeafString(effective.value);
  const atv = normalizeLeafString(tag(props, "atv"));
  const atvDesignated = positiveAtv(props);
  return {
    surfaceLeaf,
    roadClassLeaf,
    tracktype,
    smoothness,
    layer,
    structureLeaf,
    accessLeaf,
    atv,
    atvDesignated
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
    const classified = classify(props, options);
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
      const distanceMeters = lineMeters(coords);
      const osmDuration = props.duration || tag(props, "duration") || null;
      const leaves = classified.isFerry
        ? {
            surfaceLeaf: LEAF_NOT_APPLICABLE,
            roadClassLeaf: LEAF_NOT_APPLICABLE,
            tracktype: null,
            smoothness: null,
            layer: 0,
            structureLeaf: "ferry",
            accessLeaf: normalizeLeafString(effectiveMotorcycleAccess(props).value),
            atv: null,
            atvDesignated: false
          }
        : leafFieldsFromProps(props);
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
          surfaceLeaf: leaves.surfaceLeaf,
          roadClassLeaf: leaves.roadClassLeaf,
          tracktype: leaves.tracktype,
          smoothness: leaves.smoothness,
          layer: leaves.layer,
          structureLeaf: leaves.structureLeaf,
          accessLeaf: leaves.accessLeaf,
          atv: leaves.atv,
          atvDesignated: leaves.atvDesignated,
          roadName: props.name || props.ref || null,
          direction: travelDirectionFromOsmTags(props),
          seasonal: false,
          distanceMeters,
          meta: {
            highway: tag(props, "highway") || null,
            route: tag(props, "route") || null,
            surface: tag(props, "surface") || null,
            tracktype: tag(props, "tracktype") || null,
            service: tag(props, "service") || null,
            layer: tag(props, "layer") || null,
            level: tag(props, "level") || null,
            atv: tag(props, "atv") || null,
            duration: osmDuration,
            ferryCrossingSeconds: classified.isFerry
              ? ferryCrossingSeconds(distanceMeters, osmDuration)
              : null,
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
      "OSM fabric for conventional motorized roads plus dual-sport track and path.",
      "Excluded cycleway, footway/pedestrian/steps, private/no, and abandoned ways.",
      "highway=path is kept. Untagged path is motorized_unknown (Allow unknown at search). Positive atv (yes/designated/permissive) → motorized_permissive; overrides motorcycle/motor_vehicle/vehicle deny; never overrides access=private|no.",
      "Missing surface stays unknown on service/track/path; road class guides search without inventing material.",
      "Travel direction follows OSM oneway, roundabouts, and implied motorway/motorway_link; missing or ambiguous tags stay two-way.",
      "OSM motorcycle access precedence is motorcycle > motor_vehicle > vehicle > access (atv consulted for override only).",
      "Legacy CanVec track/service imports without explicit motor access are motorized_unknown; source provenance never grants permission.",
      "route=ferry ways are timed connectors (structureType=ferry); not highway fabric."
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
  classifyFerry,
  explicitSurfaceClass,
  effectiveMotorcycleAccess,
  positiveAtv,
  isLegacyCanVecImport,
  leafFieldsFromProps,
  INCLUDE_HIGHWAY,
  travelDirectionFromOsmTags
};
