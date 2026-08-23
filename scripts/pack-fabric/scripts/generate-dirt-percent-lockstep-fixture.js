#!/usr/bin/env node
"use strict";

/**
 * Phase E1: golden Dirt% lockstep fixture from JS decoder + surface-family table.
 * Samples fixed edge sets on the NS v3 pack and records honest percents.
 *
 *   node scripts/pack-fabric/scripts/generate-dirt-percent-lockstep-fixture.js
 */
const fs = require("fs");
const path = require("path");
const { decodeGraphV2 } = require("../routing/lib/pack-v2");
const {
  SURFACE_FAMILY_MAP,
  surfaceFamilyOf,
  honestSurfaceStatsFromLeaves
} = require("../routing/lib/surface-family");

const ROOT = path.join(__dirname, "../../..");
const BIN = path.join(ROOT, "scripts/pack-fabric/routing/data/regions/ns/graph.v3.bin");
const OUT = path.join(ROOT, "DirtTests/Fixtures/ns-graph.v3.dirt-percent.lockstep.json");

function sampleRoutes(pack) {
  const E = pack.undirectedEdgeCount;
  // Deterministic synthetic "routes": every Nth edge as a multi-edge bag,
  // plus all atvDesignated edges as one route, plus a paved-heavy slice.
  const every = [];
  for (let ei = 0; ei < E; ei += 791) every.push(ei);
  const atv = [];
  for (let ei = 0; ei < E; ei += 1) {
    if (pack.edgeFlags[ei] & 1) atv.push(ei);
  }
  const first2k = [];
  for (let ei = 0; ei < Math.min(2000, E); ei += 1) first2k.push(ei);
  return [
    { id: "every-791", edgeIndexes: every },
    { id: "atv-designated", edgeIndexes: atv },
    { id: "first-2000", edgeIndexes: first2k }
  ];
}

function rowsFor(pack, edgeIndexes) {
  return edgeIndexes.map((ei) => {
    const leaves = pack.edgeLeaves(ei);
    return {
      edgeIndex: ei,
      meters: pack.edgeMeters[ei],
      surfaceLeaf: leaves.surfaceLeaf,
      family: surfaceFamilyOf(leaves.surfaceLeaf, pack.surfaceFamilyMap || SURFACE_FAMILY_MAP)
    };
  });
}

function main() {
  if (!fs.existsSync(BIN)) throw new Error("missing " + BIN);
  const pack = decodeGraphV2(fs.readFileSync(BIN));
  if (!pack.hasLeaves) throw new Error("pack missing leaves");
  const routes = sampleRoutes(pack).map((route) => {
    const detail = rowsFor(pack, route.edgeIndexes);
    const stats = honestSurfaceStatsFromLeaves(
      detail.map((r) => ({ meters: r.meters, surfaceLeaf: r.surfaceLeaf })),
      detail.reduce((s, r) => s + r.meters, 0)
    );
    return {
      id: route.id,
      edgeCount: route.edgeIndexes.length,
      edgeIndexes: route.edgeIndexes,
      dirtPercent: stats.dirtPercent,
      pavedPercent: stats.pavedPercent,
      gravelPercent: stats.gravelPercent,
      unknownSurfacePercent: stats.unknownSurfacePercent
    };
  });

  const fixture = {
    generatedAt: new Date().toISOString(),
    candidateFile: "ns-graph.v3.bin",
    undirectedEdgeCount: pack.undirectedEdgeCount,
    surfaceFamilyMap: pack.surfaceFamilyMap || SURFACE_FAMILY_MAP,
    note: "Dirt% = loose+unknown families; gravel and paved excluded",
    routes
  };
  fs.writeFileSync(OUT, JSON.stringify(fixture, null, 2) + "\n");
  console.log(JSON.stringify({
    out: OUT,
    routes: routes.map((r) => ({
      id: r.id,
      edges: r.edgeCount,
      dirt: r.dirtPercent,
      paved: r.pavedPercent,
      gravel: r.gravelPercent,
      unknown: r.unknownSurfacePercent
    }))
  }, null, 2));
}

main();
