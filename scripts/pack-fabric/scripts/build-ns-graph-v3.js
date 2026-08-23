#!/usr/bin/env node
"use strict";

/**
 * Phase E1: rebuild NS as local graph.v3.bin + geometry.v1.bin (leaves + family map).
 * Keeps shipped graph.v2.bin; snapshots prior geometry.v1.bin → geometry.v1.v2-rollback.bin.
 *
 *   node --max-old-space-size=8192 scripts/pack-fabric/scripts/build-ns-graph-v3.js
 *
 * Device install (Simulator or phone via Files):
 *   Copy graph.v3.bin + geometry.v1.bin into the app's Documents/DirtLocalPacks/ns/
 *   (GraphPackStore seeds that folder into the pack cache on launch).
 */
const fs = require("fs");
const path = require("path");
const osmRoads = require("../routing/adapters/osm-roads");
const { buildRegionalGraph } = require("../routing/regional/package");
const { encodeFromV1 } = require("../routing/lib/pack-v2");

const ROOT = path.join(__dirname, "../../..");
const SEQ = path.join(
  __dirname,
  "..",
  "data-raw",
  "osm-roads",
  "nova-scotia",
  "roads.geojsonseq"
);
const OUT_DIR = path.join(__dirname, "..", "routing", "data", "regions", "ns");
const OUT_GRAPH = path.join(OUT_DIR, "graph.v3.bin");
const OUT_GEOM = path.join(OUT_DIR, "geometry.v1.bin");
const V2_GRAPH = path.join(OUT_DIR, "graph.v2.bin");
const V2_GEOM_ROLLBACK = path.join(OUT_DIR, "geometry.v1.v2-rollback.bin");
const EXISTING_GEOM = path.join(OUT_DIR, "geometry.v1.bin");

async function main() {
  if (!fs.existsSync(SEQ)) throw new Error("missing NS OSM extract: " + SEQ);
  fs.mkdirSync(OUT_DIR, { recursive: true });

  if (fs.existsSync(EXISTING_GEOM) && fs.existsSync(V2_GRAPH) && !fs.existsSync(V2_GEOM_ROLLBACK)) {
    fs.copyFileSync(EXISTING_GEOM, V2_GEOM_ROLLBACK);
    console.log("preserved v2 geometry →", V2_GEOM_ROLLBACK);
  }
  if (!fs.existsSync(V2_GRAPH)) {
    console.warn("warning: graph.v2.bin missing — rollback pair incomplete");
  }

  console.log("building NS intermediate (post-B membership + leaves)…");
  const { features } = await osmRoads.run({
    inputPath: SEQ,
    province: "NS",
    datasetVersion: "phase-e1-v3"
  });
  const graph = buildRegionalGraph({
    features,
    regionId: "ns",
    province: "NS",
    lineage: { phase: "E1-graph-v3" }
  });
  console.log("encoding graph.v3.bin… edges=", graph.edges.length);
  const { graphBuffer, geomBuffer } = encodeFromV1(graph);
  fs.writeFileSync(OUT_GRAPH, graphBuffer);
  fs.writeFileSync(OUT_GEOM, geomBuffer);

  // Also stage Documents seed folder for Simulator/device copy.
  const seedDir = path.join(ROOT, "DirtTests", "Fixtures", "DirtLocalPacks", "ns");
  fs.mkdirSync(seedDir, { recursive: true });
  fs.copyFileSync(OUT_GRAPH, path.join(seedDir, "graph.v3.bin"));
  fs.copyFileSync(OUT_GEOM, path.join(seedDir, "geometry.v1.bin"));

  console.log(
    JSON.stringify(
      {
        outGraph: OUT_GRAPH,
        outGeom: OUT_GEOM,
        graphBytes: graphBuffer.length,
        geomBytes: geomBuffer.length,
        edges: graph.edges.length,
        v2Kept: fs.existsSync(V2_GRAPH),
        v2GeomRollback: fs.existsSync(V2_GEOM_ROLLBACK),
        seedDir
      },
      null,
      2
    )
  );
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
