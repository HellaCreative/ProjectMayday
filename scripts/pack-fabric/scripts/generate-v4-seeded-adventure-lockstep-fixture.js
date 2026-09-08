#!/usr/bin/env node
"use strict";

/**
 * Generate the seeded Dirt JS/Swift lockstep expectation from the immutable
 * DEV-only V4 fabric. This reads and verifies sealed bytes; it never builds,
 * compacts, uploads, promotes, or edits a pack.
 *
 *   node scripts/pack-fabric/scripts/generate-v4-seeded-adventure-lockstep-fixture.js
 */
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const { decodeGraphV4, decodeGeometryV1 } = require("../routing/lib/pack-v4");
const { findPathV2 } = require("../routing/lib/find-path-v2");
const {
  bearingDeg,
  legalSnapDetailed,
  selectConnectedSnapPair
} = require("../routing/lib/legal-topology/snap");

const ROOT = path.join(__dirname, "../../..");
const RELEASE_ID = "fabric-v4-20260907-01";
const DEFAULT_PACK_ROOT = path.join(
  ROOT,
  "scripts/pack-fabric/routing/candidates",
  RELEASE_ID,
  "packs/ns"
);
const PACK_ROOT = process.env.DIRT_V4_TEST_PACK_ROOT
  ? path.resolve(process.env.DIRT_V4_TEST_PACK_ROOT)
  : DEFAULT_PACK_ROOT;
const OUT = path.join(
  ROOT,
  "DirtTests/Fixtures/ns-graph.v4.seeded-adventure.lockstep.json"
);
const ROUTE_SEED = 0xD1_47_0008;

const ROUTE = {
  id: "ns-v4-seeded-dirt-bridgewater-mahone",
  from: [-64.5185, 44.3782],
  to: [-64.3815, 44.4488]
};

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function verifyFile(root, identity) {
  const file = path.join(root, identity.name);
  const stat = fs.statSync(file);
  if (stat.size !== identity.bytes || sha256(file) !== identity.sha256) {
    throw new Error(`${identity.name} differs from the sealed manifest`);
  }
  return file;
}

function match(candidate, pack) {
  return {
    ok: true,
    edgeIndex: candidate.edgeIndex,
    coord: [candidate.lon, candidate.lat],
    distanceM: candidate.distanceM,
    distanceAlongM: candidate.distanceAlongM,
    edgeMeters: pack.edgeMeters[candidate.edgeIndex],
    segmentIndex: candidate.segmentIndex,
    nodeA: pack.edgeFrom[candidate.edgeIndex],
    nodeB: pack.edgeTo[candidate.edgeIndex]
  };
}

function buildFixture() {
  const manifest = readJSON(path.join(PACK_ROOT, "pack-manifest.v2.json"));
  if (
    manifest.schema !== "pack-manifest.v2" ||
    manifest.fabricReleaseId !== RELEASE_ID ||
    manifest.regionId !== "ns" ||
    !manifest.capabilities.includes("legal-topology.v1") ||
    !manifest.capabilities.includes("cross-pack-seams.v2")
  ) {
    throw new Error("pack root is not the sealed NS V4 DEV release");
  }
  const graphFile = verifyFile(PACK_ROOT, manifest.graph);
  const geometryFile = verifyFile(PACK_ROOT, manifest.geometry);
  verifyFile(PACK_ROOT, manifest.fuel);
  verifyFile(PACK_ROOT, manifest.seams);

  const graphBytes = fs.readFileSync(graphFile);
  const geometryBytes = fs.readFileSync(geometryFile);
  const pack = decodeGraphV4(graphBytes, geometryBytes);
  const geom = decodeGeometryV1(geometryBytes);
  pack.geometry = geom;
  if (
    pack.graphBinaryVersion !== 4 ||
    !pack.capabilities.includes("legal-topology.v1") ||
    (pack.provenance && pack.provenance.sourceEpoch) !== manifest.sourceEpoch
  ) {
    throw new Error("decoded graph identity does not match its V4 manifest");
  }

  const seams = readJSON(path.join(PACK_ROOT, manifest.seams.name));
  if (
    seams.schemaVersion !== "dirt-cross-pack-seams.v2" ||
    seams.fabricReleaseId !== RELEASE_ID ||
    seams.regionId !== "ns" ||
    seams.sourceEpoch !== manifest.sourceEpoch
  ) {
    throw new Error("V2 seam sidecar is outside the sealed graph contract");
  }

  const intent = bearingDeg(ROUTE.from, ROUTE.to);
  const start = legalSnapDetailed(
    pack,
    geom,
    { lon: ROUTE.from[0], lat: ROUTE.from[1] },
    { allowUnknown: false, maxMeters: 2_000, intentBearingDeg: intent }
  );
  const end = legalSnapDetailed(
    pack,
    geom,
    { lon: ROUTE.to[0], lat: ROUTE.to[1] },
    { allowUnknown: false, maxMeters: 2_000, intentBearingDeg: (intent + 180) % 360 }
  );
  const picked = selectConnectedSnapPair(pack, start.candidates, end.candidates, {
    allowUnknown: false
  });
  if (!picked.ok) throw new Error(`legal V4 snap failed: ${picked.reason}`);

  const startMatch = match(picked.start, pack);
  const endMatch = match(picked.end, pack);
  const route = findPathV2(
    { pack, geom, enums: pack.enums },
    startMatch,
    endMatch,
    "dirt",
    { motorizedUnknown: false, motorizedPermissive: true },
    new Set(),
    undefined,
    {
      sessionSeed: ROUTE_SEED,
      cityWall: true,
      settlementFallback: true,
      boundedSearch: true
    }
  );
  if (!route || !Array.isArray(route.segments)) {
    throw new Error("sealed V4 Dirt route did not complete");
  }

  const edgeIds = route.segments
    .filter((segment) =>
      segment.edgeId &&
      !String(segment.edgeId).startsWith("soft-") &&
      !String(segment.edgeId).startsWith("perm-") &&
      Number(segment.distanceMeters) > 0.5
    )
    .map((segment) => String(segment.edgeId));
  if (!edgeIds.length) throw new Error("sealed V4 route returned no graph edges");

  return {
    generatedAt: new Date().toISOString(),
    releaseId: RELEASE_ID,
    regionId: "ns",
    graphVersion: 4,
    legalTopologyCapability: "legal-topology.v1",
    seamContract: "dirt-cross-pack-seams.v2",
    sourceEpoch: manifest.sourceEpoch,
    files: {
      graph: manifest.graph,
      geometry: manifest.geometry,
      fuel: manifest.fuel,
      seams: manifest.seams
    },
    route: {
      ...ROUTE,
      profile: "dirt",
      allowUnknown: false,
      routeSeed: ROUTE_SEED,
      startEdgeIndex: startMatch.edgeIndex,
      endEdgeIndex: endMatch.edgeIndex,
      startCoord: startMatch.coord,
      endCoord: endMatch.coord,
      startAlongM: startMatch.distanceAlongM,
      endAlongM: endMatch.distanceAlongM,
      distanceMeters: Math.round(route.distanceMeters),
      dirtPercent: route.stats && route.stats.dirtPercent,
      forwardCandidateCount: route.searchMeta && route.searchMeta.forwardCandidateCount,
      selectedCandidateIndex: route.searchMeta && route.searchMeta.selectedCandidateIndex,
      edgeIds
    }
  };
}

function main() {
  const fixture = buildFixture();
  fs.writeFileSync(OUT, `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(JSON.stringify({
    releaseId: RELEASE_ID,
    route: ROUTE.id,
    kilometers: (fixture.route.distanceMeters / 1_000).toFixed(1),
    dirtPercent: fixture.route.dirtPercent,
    candidates: fixture.route.forwardCandidateCount,
    selected: fixture.route.selectedCandidateIndex,
    edges: fixture.route.edgeIds.length,
    output: OUT
  }, null, 2));
}

if (require.main === module) main();

module.exports = { buildFixture, RELEASE_ID, OUT };
