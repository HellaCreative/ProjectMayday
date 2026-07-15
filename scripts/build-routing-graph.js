#!/usr/bin/env node
/**
 * Phase 2B — Build a compact offline routing graph from the Phase 2A pack.
 *
 * Input:  app/data/ns-gov-chunks/*.geojson.gz + manifest
 * Output: routing/data/ns-graph.v1.json.gz
 *
 * The browser never loads this file. Only the route service does.
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const ROOT = path.join(__dirname, "..");
const CHUNK_DIR = path.join(ROOT, "app", "data", "ns-gov-chunks");
const MANIFEST = path.join(ROOT, "app", "data", "ns-gov-roads.manifest.json");
const OUT_DIR = path.join(ROOT, "routing", "data");
const OUT_FILE = path.join(OUT_DIR, "ns-graph.v1.json.gz");

const SURFACE = { paved: 0, gravel: 1, access: 2, track: 3, unknown: 4 };
const STRUCTURE = { none: 0, bridge: 1, tunnel: 2, ford: 3 };
const ACCESS = {
  motorized_verified: 0,
  motorized_permissive: 1,
  motorized_unknown: 2,
  motorized_restricted: 3,
  motorized_excluded: 4
};
const ACCESS_NAME = Object.fromEntries(Object.entries(ACCESS).map(([k, v]) => [v, k]));
const SURFACE_NAME = Object.fromEntries(Object.entries(SURFACE).map(([k, v]) => [v, k]));
const STRUCTURE_NAME = Object.fromEntries(Object.entries(STRUCTURE).map(([k, v]) => [v, k]));

function nodeKey(c) {
  return c[0].toFixed(5) + "," + c[1].toFixed(5);
}

function main() {
  if (!fs.existsSync(CHUNK_DIR)) {
    throw new Error("Missing chunk dir: " + CHUNK_DIR);
  }
  const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  const files = fs.readdirSync(CHUNK_DIR).filter((f) => f.endsWith(".geojson.gz")).sort();

  const nodeLookup = new Map();
  const nodes = [];
  const edges = [];
  const accessCounts = {};
  const surfaceCounts = {};

  function addNode(coord) {
    const key = nodeKey(coord);
    let id = nodeLookup.get(key);
    if (id != null) return id;
    id = nodes.length;
    nodeLookup.set(key, id);
    nodes.push([Number(coord[0]), Number(coord[1])]);
    return id;
  }

  for (const file of files) {
    const fc = JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(CHUNK_DIR, file))).toString("utf8"));
    for (const feature of fc.features || []) {
      const p = feature.properties || {};
      const coords = feature.geometry && feature.geometry.coordinates;
      if (!coords || coords.length < 2) continue;
      const accessClass = p.accessClass || "motorized_unknown";
      if (accessClass === "motorized_excluded") continue;

      const a = addNode(coords[0]);
      const b = addNode(coords[coords.length - 1]);
      if (a === b) continue;

      const surfaceClass = p.surfaceClass || p.trackClass || "unknown";
      const structureType = p.structureType || "none";
      const meters = Math.max(1, Math.round(Number(p.distanceMeters || p.lengthMeters) || 0) || 1);

      accessCounts[accessClass] = (accessCounts[accessClass] || 0) + 1;
      surfaceCounts[surfaceClass] = (surfaceCounts[surfaceClass] || 0) + 1;

      edges.push({
        i: p.edgeId || ("edge-" + edges.length),
        a,
        b,
        m: meters,
        s: SURFACE[surfaceClass] != null ? SURFACE[surfaceClass] : SURFACE.unknown,
        t: STRUCTURE[structureType] != null ? STRUCTURE[structureType] : STRUCTURE.none,
        ac: ACCESS[accessClass] != null ? ACCESS[accessClass] : ACCESS.motorized_unknown,
        c: p.componentId != null ? Number(p.componentId) : -1,
        conf: p.confidence || "medium",
        seasonal: !!p.seasonal,
        src: p.source || "ns-gov",
        desc: p.sourceDescription || "",
        rid: p.sourceRecordId || "",
        g: coords.map((c) => [Number(c[0]), Number(c[1])])
      });
    }
  }

  // Adjacency is rebuilt at service load — do not serialize it.
  const graph = {
    version: 1,
    schemaVersion: manifest.schemaVersion || "2a-2",
    generatedAt: new Date().toISOString(),
    sourceManifestGeneratedAt: manifest.generatedAt || null,
    region: manifest.region || "Nova Scotia",
    enums: { SURFACE, STRUCTURE, ACCESS, ACCESS_NAME, SURFACE_NAME, STRUCTURE_NAME },
    nodeCount: nodes.length,
    edgeCount: edges.length,
    accessCounts,
    surfaceCounts,
    nodes,
    edges
  };

  fs.mkdirSync(OUT_DIR, { recursive: true });
  const json = JSON.stringify(graph);
  const gz = zlib.gzipSync(Buffer.from(json), { level: 9 });
  fs.writeFileSync(OUT_FILE, gz);

  const meta = {
    generatedAt: graph.generatedAt,
    schemaVersion: graph.schemaVersion,
    nodeCount: nodes.length,
    edgeCount: edges.length,
    accessCounts,
    surfaceCounts,
    jsonBytes: Buffer.byteLength(json),
    gzBytes: gz.length,
    outFile: path.relative(ROOT, OUT_FILE)
  };
  fs.writeFileSync(path.join(OUT_DIR, "ns-graph.v1.meta.json"), JSON.stringify(meta, null, 2));
  console.log(JSON.stringify(meta, null, 2));
}

main();
