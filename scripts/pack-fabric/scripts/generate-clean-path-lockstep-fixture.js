#!/usr/bin/env node
"use strict";

/**
 * Phase E2: Clean path lockstep fixture (JS decoder + findPathV2).
 * Writes edge-id sequence for fixed NS A→B Clean routes.
 *
 *   node --max-old-space-size=8192 scripts/pack-fabric/scripts/generate-clean-path-lockstep-fixture.js
 */
const fs = require("fs");
const path = require("path");
const { decodeGraphV2, decodeGeometryV1 } = require("../routing/lib/pack-v2");
const { findPathV2 } = require("../routing/lib/find-path-v2");
const { roadTierOf, isCleanPavementEligible } = require("../routing/lib/road-tier");
const { surfaceFamilyOf, honestSurfaceStatsFromLeaves } = require("../routing/lib/surface-family");

const ROOT = path.join(__dirname, "../../..");
const BIN = path.join(ROOT, "DirtTests/Fixtures/DirtLocalPacks/ns/graph.v3.bin");
const GEOM = path.join(ROOT, "DirtTests/Fixtures/DirtLocalPacks/ns/geometry.v1.bin");
const OUT = path.join(ROOT, "DirtTests/Fixtures/ns-graph.v3.clean-path.lockstep.json");

/** Rural NS paved back-road corridor (expect ~0% honest dirt). */
const ROUTES = [
  {
    id: "ns-clean-backroad-a",
    // Near Bridgewater → near Mahone Bay hinterland (collector/local fabric)
    from: [-64.5185, 44.3782],
    to: [-64.3815, 44.4488]
  },
  {
    id: "ns-clean-backroad-b",
    from: [-63.5750, 44.6480],
    to: [-63.4700, 44.7200]
  }
];

function matchNearest(pack, geom, lon, lat) {
  let best = null;
  const E = pack.undirectedEdgeCount;
  for (let ei = 0; ei < E; ei += 1) {
    const leaves = pack.edgeLeaves(ei);
    const family = surfaceFamilyOf(leaves.surfaceLeaf, pack.surfaceFamilyMap);
    const tier = roadTierOf(leaves.roadClassLeaf, pack.roadTierMap);
    if (!isCleanPavementEligible(family, tier)) continue;
    const poly = geom.polyline(ei);
    if (!poly || poly.length < 2) continue;
    for (let i = 0; i < poly.length - 1; i += 1) {
      const a = poly[i];
      const b = poly[i + 1];
      // project point onto segment (approx)
      const dx = b[0] - a[0];
      const dy = b[1] - a[1];
      const len2 = dx * dx + dy * dy || 1e-12;
      let t = ((lon - a[0]) * dx + (lat - a[1]) * dy) / len2;
      t = Math.max(0, Math.min(1, t));
      const cx = a[0] + t * dx;
      const cy = a[1] + t * dy;
      const dlon = (lon - cx) * Math.cos((lat * Math.PI) / 180);
      const dlat = lat - cy;
      const m = Math.sqrt(dlon * dlon + dlat * dlat) * 111000;
      if (!best || m < best.distanceM) {
        const along = approxAlong(poly, i, t);
        best = {
          ok: true,
          edgeIndex: ei,
          coord: [cx, cy],
          distanceM: m,
          distanceAlongM: along,
          edgeMeters: pack.edgeMeters[ei],
          segmentIndex: i,
          nodeA: pack.edgeFrom ? pack.edgeFrom[ei] : -1,
          nodeB: pack.edgeTo ? pack.edgeTo[ei] : -1
        };
      }
    }
  }
  return best;
}

function approxAlong(poly, seg, t) {
  let m = 0;
  for (let i = 0; i < seg; i += 1) {
    const a = poly[i];
    const b = poly[i + 1];
    const dlon = (b[0] - a[0]) * Math.cos((a[1] * Math.PI) / 180);
    const dlat = b[1] - a[1];
    m += Math.sqrt(dlon * dlon + dlat * dlat) * 111000;
  }
  const a = poly[seg];
  const b = poly[seg + 1];
  const dlon = (b[0] - a[0]) * Math.cos((a[1] * Math.PI) / 180);
  const dlat = b[1] - a[1];
  m += t * Math.sqrt(dlon * dlon + dlat * dlat) * 111000;
  return m;
}

function tierStats(pack, edgeIds) {
  const counts = Object.create(null);
  const rows = [];
  for (const id of edgeIds) {
    // resolve ei by scanning — fixture keeps indexes too
  }
  return counts;
}

function main() {
  const pack = decodeGraphV2(fs.readFileSync(BIN));
  const geom = decodeGeometryV1(fs.readFileSync(GEOM));
  if (!pack.hasLeaves) throw new Error("pack missing leaves");
  pack.geometry = geom;

  // Build edgeId → index map once
  const idToEi = new Map();
  for (let ei = 0; ei < pack.undirectedEdgeCount; ei += 1) {
    idToEi.set(pack.edgeId(ei), ei);
  }

  const routes = [];
  for (const spec of ROUTES) {
    const startMatch = matchNearest(pack, geom, spec.from[0], spec.from[1]);
    const endMatch = matchNearest(pack, geom, spec.to[0], spec.to[1]);
    if (!startMatch || !endMatch) throw new Error("snap failed for " + spec.id);
    const runtime = { pack, geom, enums: pack.enums };
    const path = findPathV2(
      runtime,
      startMatch,
      endMatch,
      "cleanest",
      { motorizedUnknown: false, motorizedPermissive: true },
      new Set(),
      undefined,
      {
        costMode: "profile",
        pavedOnly: true,
        cityWall: true,
        variety: false,
        settlementFallback: false,
        avoidMotorways: true,
        preferBackRoads: false,
        sessionSeed: 1,
        boundedSearch: false
      }
    );
    if (!path || !path.segments) throw new Error("no Clean path for " + spec.id);
    const edgeIndexes = [];
    const edgeIds = [];
    const tierCounts = Object.create(null);
    const leafRows = [];
    for (const seg of path.segments) {
      if (!seg.edgeId || String(seg.edgeId).startsWith("soft-")) continue;
      // Match Swift reconstruct: drop sub-0.5 m virt stubs (mid-edge snap noise).
      if (!(Number(seg.distanceMeters) > 0.5)) continue;
      const ei = idToEi.get(seg.edgeId);
      if (ei == null) continue;
      edgeIndexes.push(ei);
      edgeIds.push(seg.edgeId);
      const leaves = pack.edgeLeaves(ei);
      const tier = roadTierOf(leaves.roadClassLeaf, pack.roadTierMap);
      tierCounts[tier] = (tierCounts[tier] || 0) + 1;
      leafRows.push({ meters: seg.distanceMeters, surfaceLeaf: leaves.surfaceLeaf });
    }
    const honest = honestSurfaceStatsFromLeaves(leafRows, path.distanceMeters);
    routes.push({
      id: spec.id,
      from: spec.from,
      to: spec.to,
      startEdgeIndex: startMatch.edgeIndex,
      endEdgeIndex: endMatch.edgeIndex,
      startCoord: startMatch.coord,
      endCoord: endMatch.coord,
      startAlongM: startMatch.distanceAlongM,
      endAlongM: endMatch.distanceAlongM,
      distanceMeters: Math.round(path.distanceMeters),
      dirtPercent: honest.dirtPercent,
      pavedPercent: honest.pavedPercent,
      unknownSurfacePercent: honest.unknownSurfacePercent,
      tierCounts,
      edgeIndexes,
      edgeIds
    });
    console.log(spec.id, {
      km: (path.distanceMeters / 1000).toFixed(1),
      dirt: honest.dirtPercent,
      tiers: tierCounts,
      edges: edgeIndexes.length
    });
  }

  const fixture = {
    generatedAt: new Date().toISOString(),
    candidateFile: "DirtLocalPacks/ns/graph.v3.bin",
    note: "Clean path lockstep — edgeIndexes must match Swift OnDeviceRouter cleanest",
    routes
  };
  fs.writeFileSync(OUT, JSON.stringify(fixture, null, 2) + "\n");
  console.log("wrote", OUT);
}

main();
