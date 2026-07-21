"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const https = require("https");
const http = require("http");
const { mergeRegionalGraphs, corridorLocationsForRoute } = require("../regional/merge");
const { clipGraphToCorridor, extractHighwayGraph } = require("../regional/corridor");

const DEFAULT_LEGACY_GRAPH_PATH = path.join(__dirname, "..", "data", "ns-graph.v1.json.gz");
const DEFAULT_REGIONAL_NS_PATH = path.join(__dirname, "..", "data", "regions", "ns", "graph.v1.json.gz");

/** Stage 0: LRU cap of inflated packs per isolate (ROUTING-PERFORMANCE-REV-2.1). */
const MAX_CACHED_PACKS = 3;

function defaultGraphPath() {
  if (process.env.ROUTING_GRAPH_PATH) return process.env.ROUTING_GRAPH_PATH;
  // Local/dev + fixture preference: regional pack when present on disk.
  // Serverless API uses resolveGraphRequest (legacy by default until regional
  // is explicitly promoted with ROUTING_USE_REGIONAL=1).
  if (fs.existsSync(DEFAULT_REGIONAL_NS_PATH)) return DEFAULT_REGIONAL_NS_PATH;
  return DEFAULT_LEGACY_GRAPH_PATH;
}

const DEFAULT_GRAPH_PATH = defaultGraphPath();

/** @type {Map<string, { runtime: object }>} insertion order = LRU (oldest first) */
const packCache = new Map();
/** @type {Map<string, { data: object }>} inflated JSON before adjacency build */
const dataCache = new Map();
let loadingPromise = null;

const cacheStats = {
  loads: 0,
  hits: 0,
  inflateMs: 0
};

/**
 * Stage 0 chain pack retention. Default on after median-of-three re-bench.
 * Explicit ROUTING_CHAIN_CACHE=0 disables.
 */
function chainCacheEnabled() {
  const v = process.env.ROUTING_CHAIN_CACHE;
  if (v === "0" || v === "false" || v === "off") return false;
  if (v === "1" || v === "true" || v === "on") return true;
  return true;
}

function resetCacheStats() {
  cacheStats.loads = 0;
  cacheStats.hits = 0;
  cacheStats.inflateMs = 0;
}

function getCacheStats() {
  return {
    loads: cacheStats.loads,
    hits: cacheStats.hits,
    inflateMs: cacheStats.inflateMs,
    cachedPacks: packCache.size,
    cachedDataPacks: dataCache.size,
    maxCachedPacks: MAX_CACHED_PACKS,
    chainCacheEnabled: chainCacheEnabled()
  };
}

function lruGet(map, key) {
  if (!map.has(key)) return null;
  const entry = map.get(key);
  map.delete(key);
  map.set(key, entry);
  return entry;
}

function lruPut(map, key, entry) {
  if (map.has(key)) map.delete(key);
  map.set(key, entry);
  while (map.size > MAX_CACHED_PACKS) {
    const oldest = map.keys().next().value;
    map.delete(oldest);
  }
}

function touchCached(key) {
  const entry = lruGet(packCache, key);
  return entry ? entry.runtime : null;
}

function putCached(key, runtime) {
  lruPut(packCache, key, { runtime });
}

function fetchBuffer(url) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith("https") ? https : http;
    lib.get(url, (res) => {
      if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        fetchBuffer(res.headers.location).then(resolve, reject);
        return;
      }
      if (res.statusCode !== 200) {
        reject(new Error("Graph fetch HTTP " + res.statusCode + " for " + url));
        return;
      }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve(Buffer.concat(chunks)));
      res.on("error", reject);
    }).on("error", reject);
  });
}

function inflateGraphBuffer(buf) {
  // Accept gzip bytes or raw JSON.
  if (buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b) {
    return JSON.parse(zlib.gunzipSync(buf).toString("utf8"));
  }
  return JSON.parse(buf.toString("utf8"));
}

function loadGraphSync(graphPath = defaultGraphPath()) {
  const hit = touchCached(graphPath);
  if (hit) {
    cacheStats.hits += 1;
    return hit;
  }

  const started = Date.now();
  if (graphPath.startsWith("http://") || graphPath.startsWith("https://")) {
    throw new Error("Use loadGraphAsync for remote graph URLs");
  }
  const dataCached = lruGet(dataCache, graphPath);
  let data;
  if (dataCached) {
    cacheStats.hits += 1;
    data = dataCached.data;
  } else {
    const raw = fs.readFileSync(graphPath);
    data = inflateGraphBuffer(raw);
    cacheStats.loads += 1;
    cacheStats.inflateMs += Date.now() - started;
    lruPut(dataCache, graphPath, { data });
  }
  return materializeRuntime(graphPath, data, started);
}

async function loadGraphAsync(graphPath = defaultGraphPath()) {
  const hit = touchCached(graphPath);
  if (hit) {
    cacheStats.hits += 1;
    return hit;
  }
  if (loadingPromise && loadingPromise.path === graphPath) return loadingPromise.promise;

  const promise = (async () => {
    const started = Date.now();
    let data;
    let materializePath = graphPath;
    if (graphPath.startsWith("http://") || graphPath.startsWith("https://")) {
      const buf = await fetchBuffer(graphPath);
      data = inflateGraphBuffer(buf);
    } else if (fs.existsSync(graphPath)) {
      data = inflateGraphBuffer(fs.readFileSync(graphPath));
    } else {
      // On Vercel Hobby, prefer the static asset so the function bundle stays small.
      const base = process.env.VERCEL_URL ? ("https://" + process.env.VERCEL_URL) : "https://dirt-mayday.vercel.app";
      const remote = process.env.ROUTING_GRAPH_URL || (base + "/routing/data/ns-graph.v1.json.gz");
      if (!remote.startsWith("http")) {
        throw new Error("Routing graph not found at " + graphPath);
      }
      const buf = await fetchBuffer(remote);
      data = inflateGraphBuffer(buf);
      materializePath = remote;
    }
    return materializeRuntime(materializePath, data, started);
  })();

  loadingPromise = { path: graphPath, promise };

  try {
    return await promise;
  } finally {
    if (loadingPromise && loadingPromise.promise === promise) loadingPromise = null;
  }
}

function materializeRuntime(graphPath, data, started) {
  const adjacency = Array.from({ length: data.nodeCount }, () => []);
  for (let index = 0; index < data.edges.length; index += 1) {
    const edge = data.edges[index];
    adjacency[edge.a].push(index);
    adjacency[edge.b].push(index);
  }

  // Spatial grid for snap matching (approx 0.01 deg ~ 1 km)
  const GRID = 0.01;
  const edgeGrid = new Map();
  function addToGrid(index, coords) {
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const c of coords) {
      minX = Math.min(minX, c[0]);
      minY = Math.min(minY, c[1]);
      maxX = Math.max(maxX, c[0]);
      maxY = Math.max(maxY, c[1]);
    }
    const x0 = Math.floor(minX / GRID);
    const y0 = Math.floor(minY / GRID);
    const x1 = Math.floor(maxX / GRID);
    const y1 = Math.floor(maxY / GRID);
    for (let x = x0; x <= x1; x += 1) {
      for (let y = y0; y <= y1; y += 1) {
        const key = x + ":" + y;
        let bucket = edgeGrid.get(key);
        if (!bucket) {
          bucket = [];
          edgeGrid.set(key, bucket);
        }
        bucket.push(index);
      }
    }
  }
  data.edges.forEach((edge, index) => addToGrid(index, edge.g));

  const loadMs = Date.now() - started;
  const runtime = {
    path: graphPath,
    data,
    adjacency,
    edgeGrid,
    GRID,
    loadMs,
    enums: data.enums
  };
  putCached(graphPath, runtime);
  return runtime;
}

function loadGraph(graphPath) {
  // Sync path for local fixture tests.
  return loadGraphSync(graphPath);
}

async function readGraphData(graphPath) {
  const cached = lruGet(dataCache, graphPath);
  if (cached) {
    cacheStats.hits += 1;
    return cached.data;
  }
  const started = Date.now();
  let data;
  if (graphPath.startsWith("http://") || graphPath.startsWith("https://")) {
    const buf = await fetchBuffer(graphPath);
    data = inflateGraphBuffer(buf);
  } else if (!fs.existsSync(graphPath)) {
    throw new Error("Routing graph not found at " + graphPath);
  } else {
    data = inflateGraphBuffer(fs.readFileSync(graphPath));
  }
  cacheStats.loads += 1;
  cacheStats.inflateMs += Date.now() - started;
  lruPut(dataCache, graphPath, { data });
  return data;
}

/**
 * Load one or more regional graphs. Multiple packs are merged on boundary nodes.
 * Long corridors are clipped to the route envelope to control memory.
 */
async function loadGraphsForRequest(resolution, options = {}) {
  const paths =
    resolution.graphPaths && resolution.graphPaths.length
      ? resolution.graphPaths
      : resolution.graphPath
        ? [resolution.graphPath]
        : [];
  if (!paths.length) {
    throw new Error("No graph paths in resolution");
  }

  const locations = options.locations || [];
  const corridorLocations = corridorLocationsForRoute(locations);
  const multi = paths.length > 1;
  // Wider buffer for dirt profiles; tighter for long cleanest/direct hauls.
  const bufferMeters = Number(options.corridorBufferMeters) || (paths.length >= 4 ? 220000 : 150000);
  const cacheKey = paths.join("|") + (multi ? `|c${bufferMeters}` : "");

  const hit = touchCached(cacheKey);
  if (hit) {
    cacheStats.hits += 1;
    return hit;
  }
  if (loadingPromise && loadingPromise.path === cacheKey) return loadingPromise.promise;

  const promise = (async () => {
    const started = Date.now();
    if (paths.length === 1) {
      // Prefer per-path cache so chain hops sharing a province hit LRU.
      const singleHit = touchCached(paths[0]);
      if (singleHit) {
        cacheStats.hits += 1;
        if (cacheKey !== paths[0]) putCached(cacheKey, singleHit);
        return singleHit;
      }
      const data = await readGraphData(paths[0]);
      const runtime = materializeRuntime(paths[0], data, started);
      if (cacheKey !== paths[0]) putCached(cacheKey, runtime);
      return runtime;
    }
    const graphs = [];
    const hitRegions = new Set((resolution.hitRegions || []).map((r) => String(r).toLowerCase()));
    const longHaul = paths.length >= 4;
    for (const p of paths) {
      let g = await readGraphData(p);
      const regionId = String(g.regionId || path.basename(path.dirname(p)) || "").toLowerCase();
      const isEndpoint = hitRegions.has(regionId);
      const alreadyLonghaul =
        resolution.longhaulPacks ||
        String(g.schemaVersion || "").startsWith("longhaul") ||
        /longhaul\.v1\.json\.gz$/.test(String(p));
      // Long-haul: drop track edges in mid provinces to reduce memory; keep
      // endpoints fuller for local access. Never invent free-space connectors.
      // Prebuilt longhaul packs are already spine/corridor thinned; do not
      // re-filter (NS/NB have no road class; length filters shatter them).
      if (!alreadyLonghaul && longHaul && !isEndpoint) {
        g = extractHighwayGraph(g);
      }
      if (!alreadyLonghaul && corridorLocations.length >= 2) {
        const buf = isEndpoint ? Math.max(bufferMeters, 200000) : bufferMeters;
        g = clipGraphToCorridor(g, corridorLocations, buf);
      }
      if (!g.edges || g.edges.length < 1) continue;
      g.regionId = regionId;
      graphs.push(g);
    }
    if (!graphs.length) {
      throw new Error("Corridor clip removed all edges; widen corridorBufferMeters");
    }
    const merged = mergeRegionalGraphs(graphs);
    if (!merged.report.boundaryMatches && paths.length > 1) {
      merged.report.warning = "no_boundary_matches";
    }
    const runtime = materializeRuntime(cacheKey, merged.graph, started);
    runtime.mergeReport = merged.report;
    return runtime;
  })();

  loadingPromise = { path: cacheKey, promise };
  try {
    return await promise;
  } finally {
    if (loadingPromise && loadingPromise.promise === promise) loadingPromise = null;
  }
}

function clearGraphCache() {
  packCache.clear();
  dataCache.clear();
  loadingPromise = null;
}

module.exports = {
  loadGraph,
  loadGraphSync,
  loadGraphAsync,
  loadGraphsForRequest,
  clearGraphCache,
  resetCacheStats,
  getCacheStats,
  chainCacheEnabled,
  defaultGraphPath,
  DEFAULT_GRAPH_PATH,
  DEFAULT_LEGACY_GRAPH_PATH,
  DEFAULT_REGIONAL_NS_PATH,
  MAX_CACHED_PACKS
};
