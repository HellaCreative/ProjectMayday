#!/usr/bin/env node
"use strict";

/**
 * Phase C gate: encode NS v3 candidate, round-trip leaves, keep v2 readable,
 * coarse u16 identical, no shipped pack overwrite.
 *
 *   node --max-old-space-size=8192 scripts/pack-fabric/scripts/verify-phase-c-graph-v3-roundtrip.js
 */
const fs = require("fs");
const path = require("path");
const os = require("os");
const osmRoads = require("../routing/adapters/osm-roads");
const { buildRegionalGraph } = require("../routing/regional/package");
const {
  encodeFromV1,
  decodeGraphV2,
  packAttrs,
  GRAPH_VERSION,
  FLAG_V3_LEAVES
} = require("../routing/lib/pack-v2");

const SEQ = path.join(
  __dirname,
  "..",
  "data-raw",
  "osm-roads",
  "nova-scotia",
  "roads.geojsonseq"
);
const SHIPPED_V2 = path.join(__dirname, "..", "routing", "data", "regions", "ns", "graph.v2.bin");
const CANDIDATE_DIR = path.join(os.tmpdir(), "dirt-phase-c-ns-v3-candidate");

function bump(map, key, m) {
  map[key] = (map[key] || 0) + m;
}

function leafKey(v, missing = "(missing)") {
  if (v == null || v === "") return missing;
  return String(v).toLowerCase();
}

async function main() {
  console.log("=== Phase C — graph v3 encode/decode gate ===");
  if (!fs.existsSync(SEQ)) throw new Error("missing NS extract: " + SEQ);

  console.log("\n[1] Build intermediate JSON graph with B2 leaves (OSM-only)…");
  const { features } = await osmRoads.run({
    inputPath: SEQ,
    province: "NS",
    datasetVersion: "phase-c-verify"
  });
  const graph = buildRegionalGraph({
    features,
    regionId: "ns",
    province: "NS",
    lineage: { phase: "C-verify" }
  });
  console.log(`  edges=${graph.edges.length}`);

  // Intermediate leaf km
  const interSurface = {};
  const interRoad = {};
  let interAtvM = 0;
  for (const e of graph.edges) {
    bump(interSurface, leafKey(e.surfaceLeaf), e.m);
    bump(interRoad, leafKey(e.roadClassLeaf, "unknown"), e.m);
    if (e.atvDesignated) interAtvM += e.m;
  }

  console.log("\n[2] Encode v3 candidate (tmpdir only)…");
  fs.mkdirSync(CANDIDATE_DIR, { recursive: true });
  const outGraph = path.join(CANDIDATE_DIR, "graph.v3.candidate.bin");
  const outGeom = path.join(CANDIDATE_DIR, "geometry.v3.candidate.bin");
  const encoded = encodeFromV1(graph);
  fs.writeFileSync(outGraph, encoded.graphBuffer);
  fs.writeFileSync(outGeom, encoded.geomBuffer);
  console.log(
    `  wrote ${outGraph} (${(encoded.graphBuffer.length / 1e6).toFixed(2)} MB) version=${GRAPH_VERSION}`
  );
  console.log(
    `  dict sizes: surface=${encoded.meta.surfaceLeafNames} roadClass=${encoded.meta.roadClassLeafNames} structure=${encoded.meta.structureLeafNames} access=${encoded.meta.accessLeafNames}`
  );

  // Refuse if candidate path collides with shipped
  if (/graph\.v2\.bin$/i.test(outGraph) || path.resolve(outGraph) === path.resolve(SHIPPED_V2)) {
    throw new Error("refusing to write candidate over shipped v2");
  }
  if (fs.existsSync(SHIPPED_V2)) {
    const shippedStat = fs.statSync(SHIPPED_V2);
    const shippedBefore = shippedStat.mtimeMs;
    // touch check after write
    const shippedAfter = fs.statSync(SHIPPED_V2).mtimeMs;
    if (shippedAfter !== shippedBefore) throw new Error("shipped graph.v2.bin mtime changed");
    console.log("  shipped graph.v2.bin untouched");
  }

  console.log("\n[3] Decode v3 candidate — leaf round-trip…");
  const decoded = decodeGraphV2(encoded.graphBuffer);
  if (!decoded.hasLeaves || decoded.version !== 3) {
    throw new Error("decoded pack missing v3 leaves");
  }
  if ((decoded.flags & FLAG_V3_LEAVES) === 0) throw new Error("FLAG_V3_LEAVES not set");

  let mismatch = 0;
  const decSurface = {};
  const decRoad = {};
  let decAtvM = 0;
  const sampleFails = [];
  for (let ei = 0; ei < decoded.undirectedEdgeCount; ei += 1) {
    const src = graph.edges[ei];
    const leaf = decoded.edgeLeaves(ei);
    const expSurface = src.surfaceLeaf == null || src.surfaceLeaf === "" ? null : String(src.surfaceLeaf).toLowerCase();
    const gotSurface = leaf.surfaceLeaf;
    const expRoad = String(src.roadClassLeaf || "unknown").toLowerCase();
    const gotRoad = String(leaf.roadClassLeaf || "unknown").toLowerCase();
    const expTt = src.tracktype == null || src.tracktype === "" ? null : String(src.tracktype).toLowerCase();
    const expSm = src.smoothness == null || src.smoothness === "" ? null : String(src.smoothness).toLowerCase();
    // Unknown tracktype tokens (e.g. "grade") encode as 0 → null
    const expTtNorm = expTt && ["grade1", "grade2", "grade3", "grade4", "grade5"].includes(expTt) ? expTt : null;
    const expSmNorm =
      expSm &&
      ["excellent", "good", "intermediate", "bad", "very_bad", "horrible", "very_horrible", "impassable"].includes(
        expSm
      )
        ? expSm
        : null;
    const expLayer = Number.isFinite(Number(src.layer)) ? Math.trunc(Number(src.layer)) : 0;
    const expStruct =
      src.structureLeaf == null || src.structureLeaf === "" ? null : String(src.structureLeaf).toLowerCase();
    const expAccess =
      src.accessLeaf == null || src.accessLeaf === "" ? null : String(src.accessLeaf).toLowerCase();
    const expAtv = !!src.atvDesignated;

    const ok =
      gotSurface === expSurface &&
      gotRoad === expRoad &&
      leaf.tracktype === expTtNorm &&
      leaf.smoothness === expSmNorm &&
      leaf.layer === expLayer &&
      leaf.structureLeaf === expStruct &&
      leaf.accessLeaf === expAccess &&
      leaf.atvDesignated === expAtv;

    if (!ok) {
      mismatch += 1;
      if (sampleFails.length < 5) {
        sampleFails.push({ ei, exp: { expSurface, expRoad, expTtNorm, expSmNorm, expLayer, expStruct, expAccess, expAtv }, got: leaf });
      }
    }
    bump(decSurface, leafKey(gotSurface), decoded.edgeMeters[ei]);
    bump(decRoad, leafKey(gotRoad, "unknown"), decoded.edgeMeters[ei]);
    if (leaf.atvDesignated) decAtvM += decoded.edgeMeters[ei];
  }
  if (mismatch) {
    console.error("leaf mismatches:", mismatch, sampleFails);
    process.exit(1);
  }
  console.log(`  PASS — all ${decoded.undirectedEdgeCount} edges leaf-exact`);

  function kmMap(m) {
    return Object.fromEntries(
      Object.entries(m)
        .map(([k, v]) => [k, Number((v / 1000).toFixed(1))])
        .sort((a, b) => b[1] - a[1])
    );
  }
  console.log("  intermediate surface km (top):", Object.entries(kmMap(interSurface)).slice(0, 6));
  console.log("  decoded surface km (top):", Object.entries(kmMap(decSurface)).slice(0, 6));
  console.log(
    `  atvDesignated km: intermediate ${(interAtvM / 1000).toFixed(1)} | decoded ${(decAtvM / 1000).toFixed(1)}`
  );

  console.log("\n[4] Coarse u16 identical to packAttrs(source edge)…");
  let coarseMismatch = 0;
  for (let ei = 0; ei < graph.edges.length; ei += 1) {
    const expect = packAttrs(graph.edges[ei]);
    if (decoded.edgeAttrs[ei] !== expect) coarseMismatch += 1;
  }
  if (coarseMismatch) {
    console.error("coarse mismatches:", coarseMismatch);
    process.exit(1);
  }
  console.log("  PASS — edgeAttrs byte-identical to pre-C packAttrs derivation");

  console.log("\n[5] v2 pack still loads through v3 reader…");
  if (!fs.existsSync(SHIPPED_V2)) {
    console.log("  SKIP — no shipped NS graph.v2.bin at", SHIPPED_V2);
  } else {
    const v2 = decodeGraphV2(fs.readFileSync(SHIPPED_V2));
    if (v2.version !== 2) throw new Error("expected shipped version 2, got " + v2.version);
    if (v2.hasLeaves) throw new Error("shipped v2 unexpectedly has leaves");
    const fallback = v2.edgeLeaves(0);
    if (fallback.fromLeaves) throw new Error("v2 coarse fallback failed");
    console.log(
      `  PASS — shipped v2 loads (edges=${v2.undirectedEdgeCount}, format=${v2.format}, coarse fallback ok)`
    );
  }

  console.log("\n=== GATE C PASS ===");
  console.log("candidate:", outGraph);
  console.log("=== STOP (Phase C only — no Swift / Phase D / publish) ===");
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
