#!/usr/bin/env node
"use strict";

/**
 * Split a parent admin polygon into banded subregions for pack clipping.
 *
 * Latitude recipe (Ontario / Quebec / California):
 *   node scripts/pack-fabric/scripts/split-subregion-polygons.js \
 *     --parent on --south on-s --north on-n --cut-lat 46.0
 *
 * Longitude recipe (Newfoundland island / Labrador):
 *   node scripts/pack-fabric/scripts/split-subregion-polygons.js \
 *     --parent nl --east nl-island --west nl-lab --cut-lon -56.8
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
  const opts = {
    parent: null,
    south: null,
    north: null,
    east: null,
    west: null,
    cutLat: null,
    cutLon: null,
    overlapDeg: 0.25,
    keepParent: true
  };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--parent") opts.parent = String(argv[++i]).toLowerCase();
    else if (value === "--south") opts.south = String(argv[++i]).toLowerCase();
    else if (value === "--north") opts.north = String(argv[++i]).toLowerCase();
    else if (value === "--east") opts.east = String(argv[++i]).toLowerCase();
    else if (value === "--west") opts.west = String(argv[++i]).toLowerCase();
    else if (value === "--cut-lat") opts.cutLat = Number(argv[++i]);
    else if (value === "--cut-lon") opts.cutLon = Number(argv[++i]);
    else if (value === "--overlap-deg") opts.overlapDeg = Number(argv[++i]);
    else if (value === "--drop-parent") opts.keepParent = false;
    else throw new Error(`unknown argument ${value}`);
  }
  const latMode = Number.isFinite(opts.cutLat);
  const lonMode = Number.isFinite(opts.cutLon);
  if (!opts.parent || latMode === lonMode) {
    throw new Error(
      "Usage: split-subregion-polygons.js --parent on --south on-s --north on-n --cut-lat 46.0 [--overlap-deg 0.25]\n" +
        "   or: split-subregion-polygons.js --parent nl --east nl-island --west nl-lab --cut-lon -56.8 [--overlap-deg 0.25]"
    );
  }
  if (latMode && (!opts.south || !opts.north)) {
    throw new Error("latitude-band split requires --south and --north");
  }
  if (lonMode && (!opts.east || !opts.west)) {
    throw new Error("longitude-band split requires --east and --west");
  }
  if (!Number.isFinite(opts.overlapDeg) || opts.overlapDeg < 0) {
    throw new Error("--overlap-deg must be a non-negative number");
  }
  opts.mode = latMode ? "latitude-band" : "longitude-band";
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

function intersectLat(a, b, cutLat) {
  const t = (cutLat - a[1]) / (b[1] - a[1]);
  return [a[0] + t * (b[0] - a[0]), cutLat];
}

function intersectLon(a, b, cutLon) {
  const t = (cutLon - a[0]) / (b[0] - a[0]);
  return [cutLon, a[1] + t * (b[1] - a[1])];
}

/** Clip a closed ring to one half-plane. */
function clipRingToHalf(ring, edge, cut) {
  const inside = (pt) => {
    if (edge === "south-of") return pt[1] <= cut;
    if (edge === "north-of") return pt[1] >= cut;
    if (edge === "west-of") return pt[0] <= cut;
    if (edge === "east-of") return pt[0] >= cut;
    throw new Error(`unknown edge ${edge}`);
  };
  const intersect = (a, b) =>
    edge === "south-of" || edge === "north-of" ? intersectLat(a, b, cut) : intersectLon(a, b, cut);
  const out = [];
  if (!Array.isArray(ring) || ring.length < 4) return out;
  for (let i = 0; i < ring.length - 1; i += 1) {
    const a = ring[i];
    const b = ring[i + 1];
    const aIn = inside(a);
    const bIn = inside(b);
    if (aIn && bIn) {
      out.push([b[0], b[1]]);
    } else if (aIn && !bIn) {
      out.push(intersect(a, b));
    } else if (!aIn && bIn) {
      out.push(intersect(a, b));
      out.push([b[0], b[1]]);
    }
  }
  if (out.length >= 3) {
    const first = out[0];
    const last = out[out.length - 1];
    if (first[0] !== last[0] || first[1] !== last[1]) out.push([first[0], first[1]]);
  }
  return out;
}

function clipPolygonCoords(rings, edge, cut) {
  if (!Array.isArray(rings) || !rings.length) return null;
  const exterior = clipRingToHalf(rings[0], edge, cut);
  if (exterior.length < 4) return null;
  const holes = [];
  for (let i = 1; i < rings.length; i += 1) {
    const hole = clipRingToHalf(rings[i], edge, cut);
    if (hole.length >= 4) holes.push(hole);
  }
  return [exterior, ...holes];
}

function clipGeometry(geometry, edge, cut) {
  if (geometry.type === "Polygon") {
    const clipped = clipPolygonCoords(geometry.coordinates, edge, cut);
    if (!clipped) return null;
    return { type: "Polygon", coordinates: clipped };
  }
  const parts = [];
  for (const rings of geometry.coordinates || []) {
    const clipped = clipPolygonCoords(rings, edge, cut);
    if (clipped) parts.push(clipped);
  }
  if (!parts.length) return null;
  if (parts.length === 1) return { type: "Polygon", coordinates: parts[0] };
  return { type: "MultiPolygon", coordinates: parts };
}

function registerHalf(unified, parent, id, geometry) {
  unified.regions = unified.regions || {};
  unified.osmRelations = unified.osmRelations || {};
  unified.regions[id] = geometry;
  if (unified.osmRelations[parent] != null) {
    unified.osmRelations[id] = unified.osmRelations[parent];
  }
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const overlap = opts.overlapDeg;
  const parentClip = clipGeojsonPath(opts.parent);
  if (!parentClip) throw new Error(`missing parent clip for ${opts.parent}; run prepare-v4-polygons.js ${opts.parent}`);
  const parentGeom = loadParentGeometry(parentClip);

  let firstId;
  let secondId;
  let firstGeom;
  let secondGeom;
  let meta;

  if (opts.mode === "latitude-band") {
    firstId = opts.south;
    secondId = opts.north;
    firstGeom = clipGeometry(parentGeom, "south-of", opts.cutLat + overlap);
    secondGeom = clipGeometry(parentGeom, "north-of", opts.cutLat - overlap);
    meta = {
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
  } else {
    firstId = opts.east;
    secondId = opts.west;
    firstGeom = clipGeometry(parentGeom, "east-of", opts.cutLon - overlap);
    secondGeom = clipGeometry(parentGeom, "west-of", opts.cutLon + overlap);
    meta = {
      recipe: "longitude-band",
      cutLon: opts.cutLon,
      overlapDeg: overlap,
      east: opts.east,
      west: opts.west,
      eastClipMinLon: opts.cutLon - overlap,
      westClipMaxLon: opts.cutLon + overlap,
      ownershipCutLon: opts.cutLon,
      updatedAt: new Date().toISOString()
    };
  }

  if (!firstGeom || !secondGeom) throw new Error(`${opts.mode} clip produced an empty half`);

  writeClip(firstId, firstGeom);
  writeClip(secondId, secondGeom);

  const unified = loadUnified();
  registerHalf(unified, opts.parent, firstId, firstGeom);
  registerHalf(unified, opts.parent, secondId, secondGeom);
  if (!opts.keepParent) delete unified.regions[opts.parent];
  unified.subregions = unified.subregions || {};
  unified.subregions[opts.parent] = meta;
  writeUnified(unified);

  console.log(
    JSON.stringify(
      {
        parent: opts.parent,
        mode: opts.mode,
        ...meta,
        clips: {
          [firstId]: path.join(POLYGON_DIR, `${firstId}.clip.geojson`),
          [secondId]: path.join(POLYGON_DIR, `${secondId}.clip.geojson`)
        }
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
