#!/usr/bin/env node
"use strict";

/**
 * Rebuild a regional graph.v1 from its packed edges with capillary endpoint snap.
 * Avoids re-fetching FeatureServer / OSM when only topology join policy changed.
 *
 * Usage: node scripts/resnap-regional-graph.js nb
 *        node scripts/resnap-regional-graph.js nb --longhaul
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { spawnSync } = require("child_process");
const { buildRegionalGraph, writeRegionalGraph } = require("../routing/regional/package");
const { createNormalizedEdge } = require("../routing/schema/edge");

const ROOT = path.join(__dirname, "..");
const code = String(process.argv[2] || "").toLowerCase();
const wantLonghaul = process.argv.includes("--longhaul");
if (!code) {
  console.error("Usage: resnap-regional-graph.js <region> [--longhaul]");
  process.exit(1);
}

const dir = path.join(ROOT, "routing", "data", "regions", code);
const gzPath = path.join(dir, "graph.v1.json.gz");
if (!fs.existsSync(gzPath)) {
  console.error("Missing", gzPath);
  process.exit(1);
}

console.log("Loading", gzPath);
const prev = JSON.parse(zlib.gunzipSync(fs.readFileSync(gzPath)).toString("utf8"));
const surfaceName = prev.enums.SURFACE_NAME;
const accessName = prev.enums.ACCESS_NAME;
const structureName = prev.enums.STRUCTURE_NAME;

const features = [];
for (const e of prev.edges || []) {
  const coords = e.g && e.g.length >= 2 ? e.g : null;
  if (!coords) continue;
  const role = e.role || "";
  features.push(
    createNormalizedEdge({
      edgeId: e.i,
      lineageId: e.lin || e.i,
      province: (prev.province || code).toUpperCase(),
      sourceName: e.src || "unknown",
      sourceFeatureId: e.rid || "",
      geometry: { type: "LineString", coordinates: coords },
      surfaceClass: surfaceName[e.s] === "access" ? "resource" : surfaceName[e.s] || "unknown",
      accessClass: accessName[e.ac] || "motorized_unknown",
      structureType: structureName[e.t] || "none",
      roadTrackClass: e.rt || "unknown",
      sourceConfidence: e.conf || "medium",
      seasonal: !!e.seasonal,
      distanceMeters: e.m,
      meta: {
        conflationRole: role || undefined,
        sourceDescription: e.desc || ""
      }
    })
  );
}

console.log("Features", features.length, "prev components", prev.componentCount);
const lineage = {
  ...(prev.lineage || {}),
  resnapFrom: prev.generatedAt,
  resnapAt: new Date().toISOString()
};
const graph = buildRegionalGraph({
  features,
  province: prev.province || code.toUpperCase(),
  regionId: code,
  lineage,
  conflationReport: prev.conflation || null
});
console.log("Resnap:", {
  nodes: graph.nodeCount,
  edges: graph.edgeCount,
  components: graph.componentCount,
  snaps: graph.lineage.endpointSnap
});

const written = writeRegionalGraph(graph, dir);
console.log("Wrote", written.graphPath);

if (wantLonghaul) {
  console.log("Rebuilding longhaul pack for", code);
  const r = spawnSync(process.execPath, [path.join(__dirname, "build-longhaul-region-packs.js"), code], {
    cwd: ROOT,
    stdio: "inherit"
  });
  if (r.status !== 0) process.exit(r.status || 1);
}
