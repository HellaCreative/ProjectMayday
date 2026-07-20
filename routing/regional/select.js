"use strict";

const fs = require("fs");
const path = require("path");

const REGIONS_DIR = path.join(__dirname, "..", "data", "regions");
const LEGACY_GRAPH = path.join(__dirname, "..", "data", "ns-graph.v1.json.gz");

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

function selectRegionsForLocations(locations, regionsDir = REGIONS_DIR) {
  const points = locationsToPoints(locations);
  const available = new Set(listAvailableRegions(regionsDir));
  const hit = new Set();

  for (const p of points) {
    for (const [id, bbox] of Object.entries(REGION_BBOX)) {
      if (available.has(id) && pointInBbox(p.lon, p.lat, bbox)) hit.add(id);
    }
  }

  // Fallback: legacy single NS graph when regional packs are absent.
  if (!hit.size) {
    if (available.has("ns")) return ["ns"];
    if (fs.existsSync(LEGACY_GRAPH)) return ["__legacy_ns__"];
    return [];
  }
  return [...hit].sort();
}

function graphPathForRegion(regionId, regionsDir = REGIONS_DIR) {
  if (regionId === "__legacy_ns__") return LEGACY_GRAPH;
  return path.join(regionsDir, regionId, "graph.v1.json.gz");
}

/**
 * Resolve which graph file(s) a route request should load.
 * Cross-region multi-graph merge is reserved for a later boundary-node phase;
 * for now we require a single matching region or legacy NS.
 */
function resolveGraphRequest(body = {}, regionsDir = REGIONS_DIR) {
  if (body.regionId) {
    const id = String(body.regionId).toLowerCase();
    const p = graphPathForRegion(id, regionsDir);
    if (fs.existsSync(p) || id === "__legacy_ns__") {
      return { ok: true, regionIds: [id], graphPath: p, mode: "explicit" };
    }
    return {
      ok: false,
      error: "region_unavailable",
      message: "Requested region graph is not available: " + id
    };
  }

  const regions = selectRegionsForLocations(body.locations, regionsDir);
  if (!regions.length) {
    return {
      ok: false,
      error: "no_region_graph",
      message: "No verified regional routing graph covers the requested locations."
    };
  }
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
  const regionId = regions[0];
  return {
    ok: true,
    regionIds: [regionId],
    graphPath: graphPathForRegion(regionId, regionsDir),
    mode: regionId === "__legacy_ns__" ? "legacy" : "regional"
  };
}

module.exports = {
  REGION_BBOX,
  REGIONS_DIR,
  LEGACY_GRAPH,
  listAvailableRegions,
  selectRegionsForLocations,
  graphPathForRegion,
  resolveGraphRequest
};
