"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const https = require("https");
const http = require("http");

const DEFAULT_LEGACY_GRAPH_PATH = path.join(__dirname, "..", "data", "ns-graph.v1.json.gz");
const DEFAULT_REGIONAL_NS_PATH = path.join(__dirname, "..", "data", "regions", "ns", "graph.v1.json.gz");

function defaultGraphPath() {
  if (process.env.ROUTING_GRAPH_PATH) return process.env.ROUTING_GRAPH_PATH;
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
      const base = process.env.VERCEL_URL ? ("https://" + process.env.VERCEL_URL) : "";
      const remote = process.env.ROUTING_GRAPH_URL ||
        (base + "/routing/data/regions/ns/graph.v1.json.gz");
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

function clearGraphCache() {
  cached = null;
  loadingPromise = null;
}

module.exports = {
  loadGraph,
  loadGraphSync,
  loadGraphAsync,
  clearGraphCache,
  defaultGraphPath,
  DEFAULT_GRAPH_PATH,
  DEFAULT_LEGACY_GRAPH_PATH,
  DEFAULT_REGIONAL_NS_PATH
};
