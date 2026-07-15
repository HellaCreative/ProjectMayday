"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const DEFAULT_GRAPH_PATH = path.join(__dirname, "..", "data", "ns-graph.v1.json.gz");

let cached = null;

function loadGraph(graphPath = process.env.ROUTING_GRAPH_PATH || DEFAULT_GRAPH_PATH) {
  if (cached && cached.path === graphPath) return cached.runtime;

  const started = Date.now();
  const raw = zlib.gunzipSync(fs.readFileSync(graphPath));
  const data = JSON.parse(raw.toString("utf8"));

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

function clearGraphCache() {
  cached = null;
}

module.exports = { loadGraph, clearGraphCache, DEFAULT_GRAPH_PATH };
