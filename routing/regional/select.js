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
  // One province pack (OSM-only longhaul). Legacy qc-* quadrant ids still
  // map via provinceFamily / isQcRegion for emergency packs and old deploys.
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

function isQcRegion(id) {
  return id === "qc" || String(id || "").startsWith("qc-");
}

/**
 * Piecewise Ottawa River bank split for overlapping ON/QC bboxes.
 * South bank ≈ Ontario (Ottawa metro); north bank ≈ Québec (Gatineau / Aylmer).
 */
function isNorthOfOttawaRiver(lon, lat) {
  if (lon < -76.5 || lon > -74.5) return false;
  if (lon >= -75.55) return lat >= 45.475; // Orleans / east — river farther north
  if (lon >= -75.75) return lat >= 45.44; // downtown Ottawa / Hull
  if (lon >= -75.95) return lat >= 45.4; // Aylmer / Britannia
  return lat >= 45.38; // west toward Quyon
}

/** Collapse legacy QC quadrant ids to one province family. */
function provinceFamily(regionId) {
  const id = String(regionId || "").toLowerCase();
  if (isQcRegion(id)) return "qc";
  return id;
}

function bboxArea(bbox) {
  return Math.max(0, bbox[2] - bbox[0]) * Math.max(0, bbox[3] - bbox[1]);
}

/**
 * When a point sits in overlapping province bboxes, prefer the smallest —
 * except AB/BC, whose rectangular bboxes intentionally overlap. Alberta's
 * west edge is ~120°W north of 54°N (meridian) but follows the continental
 * divide (~114–116°W) farther south. Smallest-bbox would always pick AB and
 * mis-assign Kelowna/Okanagan as Alberta.
 */
function primaryRegionForPoint(lon, lat) {
  const hits = [];
  for (const [id, bbox] of Object.entries(REGION_BBOX)) {
    if (!pointInBbox(lon, lat, bbox)) continue;
    hits.push({ id, area: bboxArea(bbox) });
  }
  if (!hits.length) return null;

  const ids = new Set(hits.map((h) => h.id));
  if (ids.has("ab") && ids.has("bc")) {
    // North of ~54°N the border is the 120th meridian.
    if (lat >= 54) return lon < -120 ? "bc" : "ab";
    // South: continental divide. Lake Louise AB ≈ -116.2; Golden BC ≈ -117.0.
    return lon < -116.4 ? "bc" : "ab";
  }

  // ON vs Quebec. Laurentians / Gatineau stay QC; Ottawa metro stays ON.
  const qcHit = [...ids].find((id) => isQcRegion(id));
  if (ids.has("on") && qcHit) {
    // Montreal side / east of Ottawa River mouth.
    if (lon >= -74.5) return "qc";
    // Laurentian / Tremblant plateau (north), but not upper Ottawa Valley ON towns.
    if (lat >= 45.9 && lon >= -76.0) return "qc";
    // Gatineau / Outaouais — north bank of Ottawa River only (not Parliament / Orleans).
    if (isNorthOfOttawaRiver(lon, lat)) return "qc";
    return "on";
  }

  // NS vs NB — Tantramar / Missaguash. Must run before NB↔QC: Quebec's
  // rectangular bbox covers the Maritimes and would steal Amherst as NB.
  // NS's bbox also covers PE + Cape Jourimain — never claim those as NS.
  if (ids.has("ns") && ids.has("nb") && ids.has("pe")) {
    // Three-way: Tantramar south of ~46°N; Northumberland / bridge north.
    if (lat < 46.0) return lon >= -64.27 ? "ns" : "nb";
    if (lon >= -63.75) return "pe";
    return "nb"; // Cape Jourimain / Port Elgin mainland
  }
  if (ids.has("ns") && ids.has("pe") && !ids.has("nb")) {
    // NS rectangle covers the island; PE wins.
    return "pe";
  }
  if (ids.has("ns") && ids.has("nb")) {
    // Roughly east of the interprovincial line stays Nova Scotia.
    if (lon >= -64.27) return "ns";
    return "nb";
  }

  // NB vs PE — Northumberland Strait / Confederation Bridge.
  // PE bbox overlaps eastern NB (Sackville / Cape Tormentine); smallest-bbox
  // would steal mainland points as PE.
  if (ids.has("nb") && ids.has("pe")) {
    // Island / PE side of bridge midpoint (~-63.75). Mainland + Cape Jourimain → NB.
    if (lat < 46.0) return "nb";
    if (lon >= -63.75) return "pe";
    return "nb";
  }

  // NB vs Quebec river corridor (Dégelis / Témiscouata) only — not Maritimes.
  if (ids.has("nb") && qcHit && !ids.has("ns") && !ids.has("pe")) {
    if (lon <= -68.45) return "qc";
    if (lat >= 47.7 && lon <= -68.2) return "qc";
    // Only claim NB when we're in the Madawaska / Témiscouata pocket.
    if (lon <= -67.2 && lat >= 47.0) return "nb";
  }

  hits.sort((a, b) => a.area - b.area);
  return hits[0].id;
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

function localGraphPath(regionId, { longhaul = false } = {}) {
  if (regionId === "__legacy_ns__") return LEGACY_GRAPH;
  if (longhaul) {
    return path.join(REGIONS_DIR, regionId, "longhaul.v1.json.gz");
  }
  // Legacy quadrant IDs: full graph lives under qc/; longhaul under the id if present.
  if (String(regionId).startsWith("qc-") && !longhaul) {
    return path.join(REGIONS_DIR, "qc", "graph.v1.json.gz");
  }
  return path.join(REGIONS_DIR, regionId, "graph.v1.json.gz");
}

function remoteGraphUrl(regionId, { longhaul = false } = {}) {
  const base = publicBaseUrl();
  if (regionId === "__legacy_ns__") return base + "/routing/data/ns-graph.v1.json.gz";
  if (longhaul) {
    return base + "/routing/data/regions/" + regionId + "/longhaul.v1.json.gz";
  }
  if (String(regionId).startsWith("qc-")) {
    return base + "/routing/data/regions/qc/graph.v1.json.gz";
  }
  return base + "/routing/data/regions/" + regionId + "/graph.v1.json.gz";
}

function graphPathForRegion(regionId, opts = {}) {
  const local = localGraphPath(regionId, opts);
  if (fs.existsSync(local)) return local;
  // On disk missing: still point at remote longhaul/full URL when requested.
  if (opts.longhaul) {
    const fullLocal = localGraphPath(regionId, { longhaul: false });
    // Prefer remote longhaul; callers on Vercel fetch from CDN after deploy.
    return remoteGraphUrl(regionId, { longhaul: true });
  }
  return remoteGraphUrl(regionId, opts);
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
  // Prefer regional packs (NS/NB = OSM+provincial, no NRN). Opt back into the
  // pre-OSM legacy NS pack only with ROUTING_PREFER_LEGACY=1. ROUTING_USE_REGIONAL
  // remains accepted as an explicit regional force for older deploy docs.
  const forceLegacyNs = process.env.ROUTING_PREFER_LEGACY === "1";
  const forceRegional = process.env.ROUTING_USE_REGIONAL === "1";

  if (body.regionId) {
    const id = String(body.regionId).toLowerCase();
    const onVercel = !!(process.env.VERCEL || process.env.VERCEL_ENV);
    const opts =
      onVercel || body.preferLonghaulPacks
        ? { longhaul: true }
        : {};
    return {
      ok: true,
      regionIds: [id],
      graphPath: graphPathForRegion(id, opts),
      graphPaths: [graphPathForRegion(id, opts)],
      mode: opts.longhaul ? "explicit-longhaul" : "explicit"
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

  // Escape hatch: single-region NS → pre-OSM legacy pack when explicitly requested.
  if (hitRegions.length === 1 && hitRegions[0] === "ns" && forceLegacyNs && !forceRegional) {
    return {
      ok: true,
      regionIds: ["ns"],
      graphPath: graphPathForRegion("__legacy_ns__"),
      graphPaths: [graphPathForRegion("__legacy_ns__")],
      mode: "legacy-production"
    };
  }

  const corridor = regionsForRoute(hitRegions);
  const longhaulPath = path.join(REGIONS_DIR, "canada-longhaul", "graph.v1.json.gz");
  // Local longhaul pack is for developer machines with enough RAM. On Vercel the
  // isolate uses chained regional hops so each request only loads 1–2 provinces.
  const onVercel = !!(process.env.VERCEL || process.env.VERCEL_ENV);

  if (
    !onVercel &&
    corridor.length >= 4 &&
    fs.existsSync(longhaulPath) &&
    !body.disableLonghaul &&
    corridor.includes("ns") &&
    corridor.includes("bc")
  ) {
    return {
      ok: true,
      regionIds: corridor,
      graphPath: longhaulPath,
      graphPaths: [longhaulPath],
      mode: "canada-longhaul-local",
      hitRegions,
      note: "Using prebuilt thinned Canada long-haul corridor pack"
    };
  }

  // On Vercel, chain multi-province routes. Skip chaining when every endpoint
  // resolves to the same primary province — in-QC From-here must not hop via
  // Ontario/Ottawa just because bboxes overlap.
  const uniquePrimary = [
    ...new Set(
      locationsToPoints(body.locations || [])
        .map((p) => primaryRegionForPoint(p.lon, p.lat))
        .filter(Boolean)
        .map(provinceFamily)
    )
  ];
  const sameProvince = uniquePrimary.length === 1;
  const useCanadaChain =
    !body.disableChain &&
    !sameProvince &&
    corridor.length >= 2 &&
    (onVercel || corridor.length >= 4);
  if (useCanadaChain) {
    return {
      ok: true,
      regionIds: corridor,
      graphPath: null,
      graphPaths: [],
      mode: "canada-chain",
      hitRegions,
      chain: true
    };
  }

  // Hobby isolates cannot inflate QC/ON full packs (~400MB+ JSON). Always use
  // thinned longhaul packs on Vercel, including single-province requests.
  const useLonghaulPacks = !!body.preferLonghaulPacks || onVercel;
  const pathOpts = useLonghaulPacks ? { longhaul: true } : {};

  const unavailableLocal = corridor.filter(
    (id) => !fs.existsSync(localGraphPath(id, pathOpts))
  );

  if (corridor.length === 1) {
    const regionId = corridor[0];
    const opts = useLonghaulPacks ? { longhaul: true } : {};
    return {
      ok: true,
      regionIds: [regionId],
      graphPath: graphPathForRegion(regionId, opts),
      graphPaths: [graphPathForRegion(regionId, opts)],
      mode: fs.existsSync(localGraphPath(regionId, opts))
        ? opts.longhaul
          ? "longhaul-local"
          : "regional-local"
        : opts.longhaul
          ? "longhaul-remote"
          : "regional-remote"
    };
  }

  return {
    ok: true,
    regionIds: corridor,
    graphPath: null,
    graphPaths: corridor.map((id) => graphPathForRegion(id, pathOpts)),
    mode: pathOpts.longhaul
      ? unavailableLocal.length
        ? "multi-longhaul-remote"
        : "multi-longhaul-local"
      : unavailableLocal.length
        ? "multi-regional-remote"
        : "multi-regional-local",
    hitRegions,
    missingLocal: unavailableLocal,
    longhaulPacks: !!pathOpts.longhaul
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
  provinceFamily,
  isQcRegion,
  regionPackAvailable
};
