#!/usr/bin/env node
"use strict";

/**
 * BC test pack: OSM core + DRA RD_CLASS=resource capillary.
 *
 * Laws (docs/08-MAP-REFINEMENT.md §1a):
 *   OSM owns identity motorway → smallest OSM road/track.
 *   DRA resource is additive dirt only (no highway→local, no paved, no trail).
 *   Drop duplicates within 28 m of OSM; no free-space connectors.
 *   Capillary endpoints snap onto OSM nodes (~18 m). Access = unknown.
 *   Publish to R2 when you want the phone to ride it:
 *   node scripts/pack-fabric/scripts/ship-routing.js --pack bc
 *
 * Usage:
 *   NODE_OPTIONS=--max-old-space-size=12288 \
 *     node experiments/bc-osm-only/build-dra-resource-test.js
 */

const fs = require("fs");
const path = require("path");
const readline = require("readline");
const crypto = require("crypto");

const DIRT = path.resolve(__dirname, "../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const OSM_GRAPH = path.join(FABRIC, "app/data/packs/v1/bc/graph.v2.bin");
const OSM_GEOM = path.join(FABRIC, "app/data/packs/v1/bc/geometry.v1.bin");
const DRA_SEQ = path.join(FABRIC, "data-raw/bc-dra/capillary.geojsonseq");
const OUT_DIR = path.join(__dirname, "out/dra-resource");

const {
  decodeGraphV2,
  decodeGeometryV1,
  unpackSurface,
  unpackAccess,
  unpackRoadClass,
  unpackConfidence,
  ROAD_CLASS_NAME,
  writePacksFromV1
} = require(path.join(DIRT, "scripts/pack-fabric/routing/lib/pack-v2"));
const { createNormalizedEdge } = require(path.join(FABRIC, "routing/schema/edge"));
const { conflateRegion } = require(path.join(FABRIC, "routing/conflation/conflate"));
const { buildRegionalGraph } = require(path.join(FABRIC, "routing/regional/package"));

const SURFACE_NAME = ["paved", "gravel", "access", "track", "unknown"];
const ACCESS_NAME = [
  "motorized_verified",
  "motorized_permissive",
  "motorized_unknown",
  "motorized_restricted",
  "motorized_excluded"
];

function haversineMeters(a, b) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const r = 6371000;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function lineMeters(coords) {
  let total = 0;
  for (let i = 1; i < coords.length; i += 1) {
    total += haversineMeters(coords[i - 1], coords[i]);
  }
  return total;
}

function normalizeLine(raw) {
  const out = [];
  for (const c of raw || []) {
    if (!Array.isArray(c) || c.length < 2) continue;
    const lon = Number(c[0]);
    const lat = Number(c[1]);
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) continue;
    if (Math.abs(lon) > 180 || Math.abs(lat) > 90) continue;
    const last = out[out.length - 1];
    if (last && last[0] === lon && last[1] === lat) continue;
    out.push([lon, lat]);
  }
  return out;
}

function geometryParts(geometry) {
  if (!geometry) return [];
  if (geometry.type === "LineString") {
    const line = normalizeLine(geometry.coordinates);
    return line.length >= 2 ? [line] : [];
  }
  if (geometry.type === "MultiLineString") {
    return geometry.coordinates.map(normalizeLine).filter((c) => c.length >= 2);
  }
  return [];
}

function osmFeaturesFromPack() {
  const graph = decodeGraphV2(fs.readFileSync(OSM_GRAPH));
  const geom = decodeGeometryV1(fs.readFileSync(OSM_GEOM));
  const enumsAccess = Array.isArray(graph.enums.ACCESS_NAME) ? graph.enums.ACCESS_NAME : ACCESS_NAME;
  const features = [];
  for (let ei = 0; ei < graph.undirectedEdgeCount; ei += 1) {
    const coords = geom.polyline(ei);
    if (coords.length < 2) continue;
    const id = graph.edgeId(ei);
    const attr = graph.edgeAttrs[ei];
    const surface = SURFACE_NAME[unpackSurface(attr)] || "unknown";
    const access = enumsAccess[unpackAccess(attr)] || "motorized_permissive";
    const road = ROAD_CLASS_NAME[unpackRoadClass(attr)] || "unknown";
    const conf = unpackConfidence(attr);
    features.push(
      createNormalizedEdge({
        edgeId: id,
        lineageId: id,
        province: "BC",
        sourceName: "OpenStreetMap",
        sourceDatasetVersion: "osm-core-pack",
        sourceFeatureId: id,
        sourceGeometryLineage: "graph.v2",
        geometry: { type: "LineString", coordinates: coords },
        surfaceClass: surface,
        roadTrackClass: road,
        accessClass: access,
        structureType: "none",
        sourceConfidence: conf || "medium",
        direction: "both",
        seasonal: false,
        distanceMeters: graph.edgeMeters[ei] || lineMeters(coords),
        meta: { conflationRole: "backbone" }
      })
    );
  }
  return features;
}

async function loadDraResource() {
  const features = [];
  const skipped = { not_resource: 0, paved: 0, no_geometry: 0, bad_json: 0 };
  const rl = readline.createInterface({
    input: fs.createReadStream(DRA_SEQ, { encoding: "utf8" }),
    crlfDelay: Infinity
  });
  let scanned = 0;
  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    scanned += 1;
    let row;
    try {
      row = JSON.parse(trimmed);
    } catch {
      skipped.bad_json += 1;
      continue;
    }
    const p = row.properties || {};
    const roadClass = String(p.RD_CLASS || p.ROAD_CLASS || "").toLowerCase().trim();
    const surface = String(p.RD_SURFACE || p.ROAD_SURFACE || "").toLowerCase().trim();
    if (roadClass !== "resource") {
      skipped.not_resource += 1;
      continue;
    }
    if (/paved|asphalt|concrete|seal/.test(surface)) {
      skipped.paved += 1;
      continue;
    }
    const parts = geometryParts(row.geometry);
    if (!parts.length) {
      skipped.no_geometry += 1;
      continue;
    }
    const featureId = p.ID || p.DIGITAL_ROAD_ATLAS_LINE_ID || p.OBJECTID || scanned;
    for (let partIndex = 0; partIndex < parts.length; partIndex += 1) {
      const coords = parts[partIndex];
      const seed = ["bc-dra", featureId, partIndex, coords[0].join(","), coords[coords.length - 1].join(",")].join("|");
      const edgeId = "bc-dra-" + crypto.createHash("sha1").update(seed).digest("hex").slice(0, 12);
      let surfaceClass = "resource";
      if (/loose|gravel|crush/.test(surface)) surfaceClass = "gravel";
      features.push(
        createNormalizedEdge({
          edgeId,
          lineageId: `bc-dra:${featureId}:${partIndex}`,
          province: "BC",
          sourceName: "BC Digital Road Atlas",
          sourceDatasetVersion: "DRA_DGTL_ROAD_ATLAS_MPAR_SP",
          sourceFeatureId: String(featureId),
          sourceGeometryLineage: "WHSE_BASEMAPPING.DRA_DGTL_ROAD_ATLAS_MPAR_SP",
          geometry: { type: "LineString", coordinates: coords },
          surfaceClass,
          roadTrackClass: "resource",
          accessClass: "motorized_unknown",
          structureType: "none",
          sourceConfidence: "medium",
          roadName: p.NAME_FULL || p.ROAD_NAME_FULL || null,
          direction: "both",
          seasonal: /seasonal/.test(surface),
          distanceMeters: lineMeters(coords),
          meta: { conflationRole: "supplement", roadClass, roadSurface: surface || null }
        })
      );
    }
  }
  return { features, skipped, scanned };
}

function joinStats(graph) {
  const osmNodes = new Set();
  for (const e of graph.edges) {
    if (/openstreetmap/i.test(String(e.src || ""))) {
      osmNodes.add(e.a);
      osmNodes.add(e.b);
    }
  }
  const out = { draEdges: 0, bothOnOsm: 0, oneOnOsm: 0, island: 0, draKm: 0, joinedKm: 0, islandKm: 0 };
  for (const e of graph.edges) {
    if (!/digital road atlas|\bdra\b/i.test(String(e.src || ""))) continue;
    out.draEdges += 1;
    const km = (e.m || 0) / 1000;
    out.draKm += km;
    const a = osmNodes.has(e.a);
    const b = osmNodes.has(e.b);
    if (a && b) {
      out.bothOnOsm += 1;
      out.joinedKm += km;
    } else if (a || b) {
      out.oneOnOsm += 1;
      out.joinedKm += km;
    } else {
      out.island += 1;
      out.islandKm += km;
    }
  }
  return out;
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  console.error("[1/5] OSM core from current BC pack…");
  const osm = osmFeaturesFromPack();
  console.error(`[osm] features=${osm.length}`);

  console.error("[2/5] DRA resource (unpaved)…");
  const dra = await loadDraResource();
  console.error(
    `[dra] scanned=${dra.scanned} resource=${dra.features.length} skipped=${JSON.stringify(dra.skipped)}`
  );

  console.error("[3/5] Conflate (OSM identity, 28 m duplicate)…");
  const conflated = conflateRegion({
    backbone: osm,
    supplement: dra.features,
    province: "BC"
  });
  console.error("[conflate]", JSON.stringify(conflated.report.stats));

  console.error("[4/5] Build graph (18 m endpoint snap onto OSM)…");
  const graph = buildRegionalGraph({
    features: conflated.features,
    province: "BC",
    regionId: "bc",
    endpointSnapMeters: 18,
    lineage: {
      test: "osm-core + dra-resource",
      laws: "08-MAP-REFINEMENT.md §1a"
    },
    conflationReport: conflated.report
  });
  const joins = joinStats(graph);
  console.error("[join]", joins);
  console.error("[graph] nodes=%s edges=%s snaps=%s", graph.nodeCount, graph.edgeCount, graph.lineage?.endpointSnap?.snappedEndpoints);

  console.error("[5/5] Write v2 from memory (v1 JSON is too large to re-inflate)…");
  writePacksFromV1(
    graph,
    path.join(OUT_DIR, "graph.v2.bin"),
    path.join(OUT_DIR, "geometry.v1.bin")
  );
  const summary = {
    generatedAt: new Date().toISOString(),
    osmFeatures: osm.length,
    draScanned: dra.scanned,
    draResourceLoaded: dra.features.length,
    draSkipped: dra.skipped,
    conflation: conflated.report.stats,
    skipReasons: conflated.report.skipReasons,
    endpointSnap: graph.lineage && graph.lineage.endpointSnap,
    join: joins,
    graph: {
      nodes: graph.nodeCount,
      edges: graph.edgeCount,
      sources: graph.sourceCounts,
      access: graph.accessCounts,
      surface: graph.surfaceCounts
    },
    outDir: OUT_DIR
  };
  fs.writeFileSync(path.join(OUT_DIR, "test-summary.json"), JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
