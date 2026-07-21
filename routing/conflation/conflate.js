"use strict";

/**
 * Controlled conflation (live mental model):
 *   NRN owns national road identity on overlaps.
 *   OSM adds unmatched driveable fabric (basemap roads).
 *   Provincial data is capillary between OSM roads (resource/forest detail).
 * No free-space connectors. No blind overlay of duplicates.
 */

const { bump } = require("../adapters/contract");

const GRID = 0.002; // ~220 m
const DUPLICATE_METERS = 28;

function haversineMeters(a, b) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const r = 6371000;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function midpoint(coords) {
  const mid = Math.floor(coords.length / 2);
  return coords[mid];
}

function bearingRough(coords) {
  const a = coords[0];
  const b = coords[coords.length - 1];
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  let ang = (Math.atan2(dy, dx) * 180) / Math.PI;
  if (ang < 0) ang += 180;
  return ang % 180;
}

function cellKey(c) {
  return Math.floor(c[0] / GRID) + ":" + Math.floor(c[1] / GRID);
}

function addToIndex(index, edge, idx) {
  const coords = edge.geometry.coordinates;
  const samples = [coords[0], midpoint(coords), coords[coords.length - 1]];
  for (const c of samples) {
    const key = cellKey(c);
    let bucket = index.get(key);
    if (!bucket) {
      bucket = [];
      index.set(key, bucket);
    }
    bucket.push(idx);
  }
}

function nearbyIndices(index, coord) {
  const x0 = Math.floor(coord[0] / GRID);
  const y0 = Math.floor(coord[1] / GRID);
  const out = new Set();
  for (let x = x0 - 1; x <= x0 + 1; x += 1) {
    for (let y = y0 - 1; y <= y0 + 1; y += 1) {
      const bucket = index.get(x + ":" + y);
      if (bucket) for (const i of bucket) out.add(i);
    }
  }
  return out;
}

function conflateRegion(options = {}) {
  const backbone = options.backbone || [];
  const supplement = options.supplement || [];
  const province = options.province || "";
  const stats = {
    backboneKept: 0,
    supplementAdded: 0,
    supplementDuplicateSkipped: 0,
    supplementConventionalSkipped: 0,
    backboneSurfaceEnriched: 0,
    conflicts: 0
  };
  const reasons = {};

  const out = [];
  const index = new Map();

  for (const edge of backbone) {
    const idx = out.length;
    out.push({
      ...edge,
      meta: { ...(edge.meta || {}), conflationRole: "backbone", conflationSource: edge.sourceName }
    });
    addToIndex(index, edge, idx);
    stats.backboneKept += 1;
  }

  for (const edge of supplement) {
    const near = findNearDuplicate(edge, out, index);
    if (near) {
      // When NRN lacks pavement status, adopt provincial paved/gravel attributes
      // rather than keeping a parallel unknown conventional edge.
      if (
        (near.surfaceClass === "unknown" || !near.surfaceClass) &&
        (edge.surfaceClass === "paved" || edge.surfaceClass === "gravel" || edge.surfaceClass === "resource")
      ) {
        near.surfaceClass = edge.surfaceClass;
        near.surfaceForCosting = edge.surfaceForCosting || edge.surfaceClass;
        near.sourceConfidence = edge.sourceConfidence || near.sourceConfidence;
        near.meta = {
          ...(near.meta || {}),
          surfaceEnrichedFrom: edge.sourceName,
          surfaceEnrichedLineage: edge.lineageId
        };
        stats.backboneSurfaceEnriched += 1;
        bump(reasons, "backbone_surface_enriched");
      }
      stats.supplementDuplicateSkipped += 1;
      bump(reasons, "duplicate_of_backbone");
      continue;
    }

    const idx = out.length;
    out.push({
      ...edge,
      meta: { ...(edge.meta || {}), conflationRole: "supplement", conflationSource: edge.sourceName }
    });
    addToIndex(index, edge, idx);
    stats.supplementAdded += 1;
  }

  return {
    features: out,
    report: {
      province,
      generatedAt: new Date().toISOString(),
      precedence: {
        backbone: "NRN owns national road identity and conventional-road attributes",
        osmFabric:
          "OpenStreetMap is the driveable road fabric (unmatched motorized ways after NRN); always permissive; never replaces NRN identity",
        supplement:
          "Provincial capillary fills between OSM roads (forest/resource); default motorized_unknown",
        surfaceEnrichment: "Provincial or OSM paved/gravel may enrich NRN edges whose pavement status is unknown",
        freeSpace: "No free-space connectors"
      },
      stats,
      skipReasons: reasons,
      featureCount: out.length,
      freeSpaceConnectors: 0,
      notes: [
        "No free-space connectors were created.",
        "Duplicates detected by midpoint proximity + bearing + endpoint proximity.",
        "Genuine dead ends remain dead ends — no proximity stitching of endpoints."
      ]
    }
  };
}

function findNearDuplicate(candidate, backboneEdges, index) {
  const coords = candidate.geometry.coordinates;
  const mid = midpoint(coords);
  const candBearing = bearingRough(coords);
  for (const idx of nearbyIndices(index, mid)) {
    const other = backboneEdges[idx];
    const otherCoords = other.geometry.coordinates;
    const otherMid = midpoint(otherCoords);
    const dist = haversineMeters(mid, otherMid);
    if (dist > DUPLICATE_METERS) continue;
    const bearingDelta = Math.abs(candBearing - bearingRough(otherCoords));
    const bearingOk = Math.min(bearingDelta, 180 - bearingDelta) <= 28;
    if (!bearingOk) continue;
    const endA = haversineMeters(coords[0], otherCoords[0]);
    const endB = haversineMeters(coords[coords.length - 1], otherCoords[otherCoords.length - 1]);
    const endC = haversineMeters(coords[0], otherCoords[otherCoords.length - 1]);
    const endD = haversineMeters(coords[coords.length - 1], otherCoords[0]);
    if (Math.min(endA, endB, endC, endD, dist) <= DUPLICATE_METERS) return other;
  }
  return null;
}

function isNearDuplicate(candidate, backboneEdges, index) {
  return !!findNearDuplicate(candidate, backboneEdges, index);
}

module.exports = {
  conflateRegion,
  isNearDuplicate,
  findNearDuplicate,
  isProvincialSupplement,
  DUPLICATE_METERS
};

function isProvincialSupplement(edge) {
  const s = edge.surfaceClass;
  return s === "track" || s === "resource" || s === "double_track" || s === "access";
}
