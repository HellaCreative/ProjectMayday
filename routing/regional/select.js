"use strict";

const fs = require("fs");
const path = require("path");
const { regionsForRoute } = require("./merge");

const REGIONS_DIR = path.join(__dirname, "..", "data", "regions");
const LEGACY_GRAPH = path.join(__dirname, "..", "data", "ns-graph.v1.json.gz");
const REGIONAL_NS = path.join(REGIONS_DIR, "ns", "graph.v1.json.gz");

/** Approximate province bboxes for region selection (W,S,E,N). */
const REGION_BBOX = {
  // Keep Maritimes bboxes tight — Halifax (-63.57) must not hit NB.
  ns: [-66.6, 43.3, -59.5, 47.2],
  pe: [-64.6, 45.8, -61.9, 47.2],
  nb: [-69.3, 44.5, -63.8, 48.2],
  nl: [-67.9, 46.5, -52.5, 60.5],
  qc: [-79.8, 44.9, -57.0, 62.7],
  on: [-95.2, 41.6, -74.3, 56.9],
  mb: [-102.1, 48.9, -88.9, 60.1],
  sk: [-110.1, 48.9, -101.3, 60.1],
  ab: [-120.1, 48.9, -109.9, 60.1],
  bc: [-139.1, 48.2, -114.0, 60.1],
  yt: [-141.1, 59.8, -123.8, 69.7],
  nt: [-136.5, 60.0, -102.0, 78.8],
  nu: [-120.9, 51.6, -60.9, 83.2]
};

function bboxArea(bbox) {
  return Math.max(0, bbox[2] - bbox[0]) * Math.max(0, bbox[3] - bbox[1]);
}

/** When a point sits in overlapping province bboxes, prefer the smallest. */
function primaryRegionForPoint(lon, lat) {
  let best = null;
  let bestArea = Infinity;
  for (const [id, bbox] of Object.entries(REGION_BBOX)) {
    if (!pointInBbox(lon, lat, bbox)) continue;
    const area = bboxArea(bbox);
    if (area < bestArea) {
      bestArea = area;
      best = id;
    }
  }
  return best;
}

function publicBaseUrl() {
  if (process.env.ROUTING_PUBLIC_BASE) return process.env.ROUTING_PUBLIC_BASE.replace(/\/$/, "");
  if (process.env.VERCEL_URL) return "https://" + process.env.VERCEL_URL.replace(/^https?:\/\//, "");
  return "https://dirt-mayday.vercel.app";
}

function pointInBbox(lon, lat, bbox) {
  return lon >= bbox[0] && lon <= bbox[2] && lat >= bbox[1] && lat <= bbox[3];
}

function locationsToPoints(locations) {
  return (locations || [])
    .map((loc) => {
      const lon = Number(loc.lon != null ? loc.lon : loc.lng);
      const lat = Number(loc.lat);
      if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
      return { lon, lat };
    })
    .filter(Boolean);
}

function listAvailableRegions(regionsDir = REGIONS_DIR) {
  if (!fs.existsSync(regionsDir)) return [];
  return fs
    .readdirSync(regionsDir)
    .filter((name) => fs.existsSync(path.join(regionsDir, name, "graph.v1.json.gz")))
    .sort();
}

function selectRegionsForLocations(locations) {
  const points = locationsToPoints(locations);
  const hit = new Set();
  for (const p of points) {
    const id = primaryRegionForPoint(p.lon, p.lat);
    if (id) hit.add(id);
  }
  return [...hit].sort();
}

function localGraphPath(regionId) {
  if (regionId === "__legacy_ns__") return LEGACY_GRAPH;
  return path.join(REGIONS_DIR, regionId, "graph.v1.json.gz");
}

function remoteGraphUrl(regionId) {
  const base = publicBaseUrl();
  if (regionId === "__legacy_ns__") return base + "/routing/data/ns-graph.v1.json.gz";
  return base + "/routing/data/regions/" + regionId + "/graph.v1.json.gz";
}

function graphPathForRegion(regionId) {
  const local = localGraphPath(regionId);
  if (fs.existsSync(local)) return local;
  return remoteGraphUrl(regionId);
}

function regionPackAvailable(regionId) {
  const local = localGraphPath(regionId);
  if (fs.existsSync(local)) return true;
  // Remote packs are assumed deployable once built; caller may still fetch-fail.
  return true;
}

/**
 * Resolve which graph(s) a route request should load.
 * Multi-province routes expand to the corridor of adjacent regions and merge
 * via boundary-node matching (no free-space connectors).
 */
function resolveGraphRequest(body = {}) {
  // NS-only production guard: keep live NS routes on the proven legacy pack
  // unless ROUTING_USE_REGIONAL=1. Other provinces always use regional packs.
  const forceRegional = process.env.ROUTING_USE_REGIONAL === "1";
  const preferLegacyNs = process.env.ROUTING_PREFER_LEGACY === "1" || !forceRegional;

  if (body.regionId) {
    const id = String(body.regionId).toLowerCase();
    return {
      ok: true,
      regionIds: [id],
      graphPath: graphPathForRegion(id),
      graphPaths: [graphPathForRegion(id)],
      mode: "explicit"
    };
  }

  const hitRegions = selectRegionsForLocations(body.locations);
  if (!hitRegions.length) {
    return {
      ok: false,
      error: "region_unknown",
      message: "Could not map route locations to a Canadian province or territory.",
      regionIds: []
    };
  }

  // Single-region NS → legacy production unless regional promoted.
  if (hitRegions.length === 1 && hitRegions[0] === "ns" && preferLegacyNs) {
    return {
      ok: true,
      regionIds: ["ns"],
      graphPath: graphPathForRegion("__legacy_ns__"),
      graphPaths: [graphPathForRegion("__legacy_ns__")],
      mode: "legacy-production"
    };
  }

  const corridor = regionsForRoute(hitRegions);
  const missing = corridor.filter((id) => !fs.existsSync(localGraphPath(id)) && !remoteGraphUrl(id));
  // Always allow remote URLs; check local for offline messaging only.
  const unavailableLocal = corridor.filter((id) => !fs.existsSync(localGraphPath(id)));

  if (corridor.length === 1) {
    const regionId = corridor[0];
    return {
      ok: true,
      regionIds: [regionId],
      graphPath: graphPathForRegion(regionId),
      graphPaths: [graphPathForRegion(regionId)],
      mode: fs.existsSync(localGraphPath(regionId)) ? "regional-local" : "regional-remote"
    };
  }

  return {
    ok: true,
    regionIds: corridor,
    graphPath: null,
    graphPaths: corridor.map(graphPathForRegion),
    mode: unavailableLocal.length ? "multi-regional-remote" : "multi-regional-local",
    hitRegions,
    missingLocal: unavailableLocal,
    note: missing.length
      ? "Some corridor regions lack packs: " + missing.join(",")
      : undefined
  };
}

module.exports = {
  REGION_BBOX,
  REGIONS_DIR,
  LEGACY_GRAPH,
  REGIONAL_NS,
  listAvailableRegions,
  selectRegionsForLocations,
  graphPathForRegion,
  remoteGraphUrl,
  resolveGraphRequest,
  publicBaseUrl,
  primaryRegionForPoint,
  regionPackAvailable
};
