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

function defaultGraphPath() {
  if (process.env.ROUTING_GRAPH_PATH) return process.env.ROUTING_GRAPH_PATH;
  // Local/dev + fixture preference: regional pack when present on disk.
  // Serverless API uses resolveGraphRequest (legacy by default until regional
  // is explicitly promoted with ROUTING_USE_REGIONAL=1).
  if (fs.existsSync(DEFAULT_REGIONAL_NS_PATH)) return DEFAULT_REGIONAL_NS_PATH;
  return DEFAULT_LEGACY_GRAPH_PATH;
}

const DEFAULT_GRAPH_PATH = defaultGraphPath();

let cached = null;
let loadingPromise = null;

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
  if (cached && cached.path === graphPath) return cached.runtime;

  const started = Date.now();
  let data;
  if (graphPath.startsWith("http://") || graphPath.startsWith("https://")) {
    throw new Error("Use loadGraphAsync for remote graph URLs");
  }
  const raw = fs.readFileSync(graphPath);
  data = inflateGraphBuffer(raw);
  return materializeRuntime(graphPath, data, started);
}

async function loadGraphAsync(graphPath = defaultGraphPath()) {
  if (cached && cached.path === graphPath) return cached.runtime;
  if (loadingPromise && loadingPromise.path === graphPath) return loadingPromise.promise;

  const promise = (async () => {
    const started = Date.now();
    let data;
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
      return materializeRuntime(remote, data, started);
    }
    return materializeRuntime(graphPath, data, started);
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
  function cellKey(x, y) {
    return Math.floor(x / GRID) + ":" + Math.floor(y / GRID);
  }
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

  const runtime = {
    path: graphPath,
    data,
    adjacency,
    edgeGrid,
    GRID,
    loadMs: Date.now() - started,
    enums: data.enums
  };
  cached = { path: graphPath, runtime };
  return runtime;
}

function loadGraph(graphPath) {
  // Sync path for local fixture tests.
  return loadGraphSync(graphPath);
}

async function readGraphData(graphPath) {
  if (graphPath.startsWith("http://") || graphPath.startsWith("https://")) {
    const buf = await fetchBuffer(graphPath);
    return inflateGraphBuffer(buf);
  }
  if (!fs.existsSync(graphPath)) {
    throw new Error("Routing graph not found at " + graphPath);
  }
  return inflateGraphBuffer(fs.readFileSync(graphPath));
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
  if (cached && cached.path === cacheKey) return cached.runtime;
  if (loadingPromise && loadingPromise.path === cacheKey) return loadingPromise.promise;

  const promise = (async () => {
    const started = Date.now();
    if (paths.length === 1) {
      const data = await readGraphData(paths[0]);
      return materializeRuntime(cacheKey, data, started);
    }
    const graphs = [];
    const hit = new Set((resolution.hitRegions || []).map((r) => String(r).toLowerCase()));
    const longHaul = paths.length >= 4;
    for (const p of paths) {
      let g = await readGraphData(p);
      const regionId = String(g.regionId || path.basename(path.dirname(p)) || "").toLowerCase();
      const isEndpoint = hit.has(regionId);
      // Long-haul: drop track edges in mid provinces to reduce memory; keep
      // endpoints fuller for local access. Never invent free-space connectors.
      if (longHaul && !isEndpoint) {
        g = extractHighwayGraph(g);
      }
      if (corridorLocations.length >= 2) {
        const buf = isEndpoint ? Math.max(bufferMeters, 200000) : bufferMeters;
        g = clipGraphToCorridor(g, corridorLocations, buf);
      }
      if (!g.edges || g.edges.length < 1) continue;
      g.regionId = regionId;
      graphs.push(g);
    }
    if (!graphs.length) {
      throw new Error("Corridor clip removed all edges — widen corridorBufferMeters");
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
  cached = null;
  loadingPromise = null;
}

module.exports = {
  loadGraph,
  loadGraphSync,
  loadGraphAsync,
  loadGraphsForRequest,
  clearGraphCache,
  defaultGraphPath,
  DEFAULT_GRAPH_PATH,
  DEFAULT_LEGACY_GRAPH_PATH,
  DEFAULT_REGIONAL_NS_PATH
};
