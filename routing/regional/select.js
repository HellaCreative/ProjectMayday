"use strict";

const fs = require("fs");
const path = require("path");

const REGIONS_DIR = path.join(__dirname, "..", "data", "regions");
const LEGACY_GRAPH = path.join(__dirname, "..", "data", "ns-graph.v1.json.gz");
const REGIONAL_NS = path.join(REGIONS_DIR, "ns", "graph.v1.json.gz");

/** Approximate province bboxes for region selection (W,S,E,N). */
const REGION_BBOX = {
  ns: [-66.6, 43.3, -59.5, 47.2],
  pe: [-64.6, 45.8, -61.9, 47.2],
  nb: [-69.3, 44.4, -63.5, 48.2],
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
    for (const [id, bbox] of Object.entries(REGION_BBOX)) {
      if (pointInBbox(p.lon, p.lat, bbox)) hit.add(id);
    }
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

/**
 * Resolve which graph a route request should load.
 * On Vercel the graph files are CDN static assets (not in the function bundle),
 * so we return https URLs when local files are absent.
 */
function resolveGraphRequest(body = {}) {
  // Temporary production guard: the conflated regional graph is larger and can
  // OOM Hobby isolates on cold start. Prefer the proven legacy NS graph for the
  // live API unless ROUTING_USE_REGIONAL=1. Local fixture runs still use
  // defaultGraphPath() which prefers the regional pack when present on disk.
  const forceRegional = process.env.ROUTING_USE_REGIONAL === "1";
  const forceLegacy = process.env.ROUTING_PREFER_LEGACY === "1" || !forceRegional;

  if (body.regionId) {
    const id = String(body.regionId).toLowerCase();
    return {
      ok: true,
      regionIds: [id],
      graphPath: graphPathForRegion(id),
      mode: "explicit"
    };
  }

  const regions = selectRegionsForLocations(body.locations);
  if (regions.length > 1) {
    return {
      ok: false,
      error: "cross_region_unsupported",
      message:
        "Cross-province routing requires adjacent regional graphs with boundary nodes. Regions: " +
        regions.join(","),
      regionIds: regions
    };
  }

  let regionId = regions[0] || "ns";
  if (forceLegacy && (regionId === "ns" || !regions.length)) {
    return {
      ok: true,
      regionIds: ["ns"],
      graphPath: graphPathForRegion("__legacy_ns__"),
      mode: "legacy-production"
    };
  }

  return {
    ok: true,
    regionIds: [regionId],
    graphPath: graphPathForRegion(regionId),
    mode: fs.existsSync(localGraphPath(regionId)) ? "regional-local" : "regional-remote"
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
  publicBaseUrl
};
