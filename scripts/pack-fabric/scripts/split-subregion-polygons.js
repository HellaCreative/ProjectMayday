#!/usr/bin/env node
"use strict";

/**
 * Split a parent admin polygon into latitude-band subregions for pack clipping.
 *
 * Recipe (Ontario first):
 *   node scripts/pack-fabric/scripts/split-subregion-polygons.js \
 *     --parent on --south on-s --north on-n --cut-lat 46.0
 *
 * Pure Node clip (no ogr2ogr) so the factory still runs when Homebrew GDAL
 * dylibs are broken. Writes clip GeoJSON + updates region-polygons.v1.json
 * and iOS RegionPolygons.json.
 */
const fs = require("fs");
const path = require("path");
const { clipGeojsonPath, loadUnified, writeUnified } = require("./fetch-admin-polygon");

const FABRIC = path.join(__dirname, "..");
const POLYGON_DIR = path.join(FABRIC, "routing", "data", "region-polygons");

function parseArgs(argv) {
  const opts = { parent: null, south: null, north: null, cutLat: null, overlapDeg: 0.25, keepParent: true };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--parent") opts.parent = String(argv[++i]).toLowerCase();
    else if (value === "--south") opts.south = String(argv[++i]).toLowerCase();
    else if (value === "--north") opts.north = String(argv[++i]).toLowerCase();
    else if (value === "--cut-lat") opts.cutLat = Number(argv[++i]);
    else if (value === "--overlap-deg") opts.overlapDeg = Number(argv[++i]);
    else if (value === "--drop-parent") opts.keepParent = false;
    else throw new Error(`unknown argument ${value}`);
  }
  if (!opts.parent || !opts.south || !opts.north || !Number.isFinite(opts.cutLat)) {
    throw new Error("Usage: split-subregion-polygons.js --parent on --south on-s --north on-n --cut-lat 46.0 [--overlap-deg 0.25]");
  }
  if (!Number.isFinite(opts.overlapDeg) || opts.overlapDeg < 0) {
    throw new Error("--overlap-deg must be a non-negative number");
  }
  return opts;
}

function writeClip(id, geometry) {
  const clipPath = path.join(POLYGON_DIR, `${id}.clip.geojson`);
  fs.mkdirSync(POLYGON_DIR, { recursive: true });
  fs.writeFileSync(
    clipPath,
    JSON.stringify({
      type: "FeatureCollection",
      features: [{ type: "Feature", properties: { id }, geometry }]
    })
  );
  return clipPath;
}

function loadParentGeometry(parentClip) {
  const doc = JSON.parse(fs.readFileSync(parentClip, "utf8"));
  const feature = (doc.features && doc.features[0]) || doc;
  const geometry = feature.geometry || feature;
  if (!geometry || !["Polygon", "MultiPolygon"].includes(geometry.type)) {
    throw new Error("parent clip has no polygon geometry");
  }
  return geometry;
}

/** Clip a closed ring to one half-plane. edge: 'south-of' | 'north-of' cutLat. */
function clipRingToHalf(ring, edge, cutLat) {
  const inside = (lat) => (edge === "south-of" ? lat <= cutLat : lat >= cutLat);
  const out = [];
  if (!Array.isArray(ring) || ring.length < 4) return out;
  for (let i = 0; i < ring.length - 1; i += 1) {
    const a = ring[i];
    const b = ring[i + 1];
    const aIn = inside(a[1]);
    const bIn = inside(b[1]);
    if (aIn && bIn) {
      out.push([b[0], b[1]]);
    } else if (aIn && !bIn) {
      out.push(intersectLat(a, b, cutLat));
    } else if (!aIn && bIn) {
      out.push(intersectLat(a, b, cutLat));
      out.push([b[0], b[1]]);
    }
  }
  if (out.length < 3) return [];
  const first = out[0];
  const last = out[out.length - 1];
  if (first[0] !== last[0] || first[1] !== last[1]) out.push([first[0], first[1]]);
  return out;
}

function intersectLat(a, b, cutLat) {
  const dy = b[1] - a[1];
  if (Math.abs(dy) < 1e-12) return [a[0], cutLat];
  const t = (cutLat - a[1]) / dy;
  return [a[0] + t * (b[0] - a[0]), cutLat];
}

function clipPolygonCoords(rings, edge, cutLat) {
  if (!Array.isArray(rings) || !rings.length) return null;
  const exterior = clipRingToHalf(rings[0], edge, cutLat);
  if (exterior.length < 4) return null;
  const holes = [];
  for (let i = 1; i < rings.length; i += 1) {
    const hole = clipRingToHalf(rings[i], edge, cutLat);
    if (hole.length >= 4) holes.push(hole);
  }
  return [exterior, ...holes];
}

function clipGeometry(geometry, edge, cutLat) {
  if (geometry.type === "Polygon") {
    const clipped = clipPolygonCoords(geometry.coordinates, edge, cutLat);
    if (!clipped) return null;
    return { type: "Polygon", coordinates: clipped };
  }
  const parts = [];
  for (const rings of geometry.coordinates || []) {
    const clipped = clipPolygonCoords(rings, edge, cutLat);
    if (clipped) parts.push(clipped);
  }
  if (!parts.length) return null;
  if (parts.length === 1) return { type: "Polygon", coordinates: parts[0] };
  return { type: "MultiPolygon", coordinates: parts };
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const overlap = opts.overlapDeg;
  const parentClip = clipGeojsonPath(opts.parent);
  if (!parentClip) throw new Error(`missing parent clip for ${opts.parent}; run prepare-v4-polygons.js ${opts.parent}`);
  const parentGeom = loadParentGeometry(parentClip);

  const southGeom = clipGeometry(parentGeom, "south-of", opts.cutLat + overlap);
  const northGeom = clipGeometry(parentGeom, "north-of", opts.cutLat - overlap);
  if (!southGeom || !northGeom) throw new Error("latitude-band clip produced an empty half");

  writeClip(opts.south, southGeom);
  writeClip(opts.north, northGeom);

  const unified = loadUnified();
  unified.regions = unified.regions || {};
  unified.osmRelations = unified.osmRelations || {};
  unified.regions[opts.south] = southGeom;
  unified.regions[opts.north] = northGeom;
  if (unified.osmRelations[opts.parent] != null) {
    unified.osmRelations[opts.south] = unified.osmRelations[opts.parent];
    unified.osmRelations[opts.north] = unified.osmRelations[opts.parent];
  }
  if (!opts.keepParent) delete unified.regions[opts.parent];
  unified.subregions = unified.subregions || {};
  unified.subregions[opts.parent] = {
    recipe: "latitude-band",
    cutLat: opts.cutLat,
    overlapDeg: overlap,
    south: opts.south,
    north: opts.north,
    southClipMaxLat: opts.cutLat + overlap,
    northClipMinLat: opts.cutLat - overlap,
    ownershipCutLat: opts.cutLat,
    updatedAt: new Date().toISOString()
  };
  writeUnified(unified);

  console.log(
    JSON.stringify(
      {
        parent: opts.parent,
        cutLat: opts.cutLat,
        overlapDeg: overlap,
        south: opts.south,
        north: opts.north,
        southClip: path.join(POLYGON_DIR, `${opts.south}.clip.geojson`),
        northClip: path.join(POLYGON_DIR, `${opts.north}.clip.geojson`)
      },
      null,
      2
    )
  );
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = { main, parseArgs, clipGeometry };
