"use strict";

const path = require("path");

const RECORD_PATH = path.join(__dirname, "..", "schema", "region-polygons.v1.json");
const RECORD = require("../schema/region-polygons.v1.json");

let cached = null;

function loadRegionPolygons() {
  if (cached) return cached;
  cached = RECORD;
  return cached;
}

function pointInRing(lon, lat, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = Number(ring[i][0]);
    const yi = Number(ring[i][1]);
    const xj = Number(ring[j][0]);
    const yj = Number(ring[j][1]);
    const intersect = yi > lat !== yj > lat && lon < ((xj - xi) * (lat - yi)) / (yj - yi + 0.0) + xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

function pointInPolygonCoords(lon, lat, rings) {
  if (!Array.isArray(rings) || !rings[0] || !pointInRing(lon, lat, rings[0])) return false;
  for (let h = 1; h < rings.length; h += 1) {
    if (pointInRing(lon, lat, rings[h])) return false;
  }
  return true;
}

function pointInGeometry(lon, lat, geom) {
  if (!geom || !geom.type) return false;
  if (geom.type === "Polygon") return pointInPolygonCoords(lon, lat, geom.coordinates);
  if (geom.type === "MultiPolygon") {
    return (geom.coordinates || []).some((polygon) => pointInPolygonCoords(lon, lat, polygon));
  }
  return false;
}

function pointInRegionPolygon(regionId, lon, lat) {
  const id = String(regionId || "").toLowerCase();
  const geom = loadRegionPolygons().regions && loadRegionPolygons().regions[id];
  if (!geom) return false;
  return pointInGeometry(lon, lat, geom);
}

function geometryBbox(geom) {
  let minLon = Infinity;
  let minLat = Infinity;
  let maxLon = -Infinity;
  let maxLat = -Infinity;
  function walk(coords) {
    if (!Array.isArray(coords) || !coords.length) return;
    if (typeof coords[0] === "number") {
      const lon = Number(coords[0]);
      const lat = Number(coords[1]);
      if (lon < minLon) minLon = lon;
      if (lat < minLat) minLat = lat;
      if (lon > maxLon) maxLon = lon;
      if (lat > maxLat) maxLat = lat;
      return;
    }
    for (const child of coords) walk(child);
  }
  walk(geom && geom.coordinates);
  if (!Number.isFinite(minLon)) return null;
  return { minLon, minLat, maxLon, maxLat };
}

function bboxArea(box) {
  if (!box) return Infinity;
  return Math.max(0, box.maxLon - box.minLon) * Math.max(0, box.maxLat - box.minLat);
}

function expandBbox(box, padDeg) {
  return {
    minLon: box.minLon - padDeg,
    minLat: box.minLat - padDeg,
    maxLon: box.maxLon + padDeg,
    maxLat: box.maxLat + padDeg
  };
}

function intersectBboxes(a, b) {
  const box = {
    minLon: Math.max(a.minLon, b.minLon),
    minLat: Math.max(a.minLat, b.minLat),
    maxLon: Math.min(a.maxLon, b.maxLon),
    maxLat: Math.min(a.maxLat, b.maxLat)
  };
  if (box.minLon >= box.maxLon || box.minLat >= box.maxLat) return null;
  return box;
}

function seamCorridor(leftId, rightId, padDeg = 0.15) {
  const regions = loadRegionPolygons().regions || {};
  const left = geometryBbox(regions[String(leftId || "").toLowerCase()]);
  const right = geometryBbox(regions[String(rightId || "").toLowerCase()]);
  if (!left || !right) return null;
  const overlap = intersectBboxes(expandBbox(left, padDeg), expandBbox(right, padDeg));
  return overlap;
}

function pointInBbox(lon, lat, box) {
  return lon >= box.minLon && lon <= box.maxLon && lat >= box.minLat && lat <= box.maxLat;
}

/**
 * Admin-polygon owner. Null when the point is in none of the loaded polygons.
 * NS/NB overlap on the isthmus uses the meridian already proven in the field.
 */
function polygonOwner(lon, lat) {
  const regions = loadRegionPolygons().regions || {};
  const hits = [];
  for (const id of Object.keys(regions)) {
    const box = geometryBbox(regions[id]);
    if (box && !pointInBbox(lon, lat, box)) continue;
    if (pointInRegionPolygon(id, lon, lat)) hits.push(id);
  }
  if (!hits.length) return null;
  if (hits.length === 1) return hits[0];
  if (hits.includes("ns") && hits.includes("nb")) {
    return lon >= -64.27 ? "ns" : "nb";
  }
  const txPieces = hits.filter(id => id.startsWith("tx-")).sort();
  if (txPieces.length) {
    const owner = `tx-${lat >= 31 ? "n" : "s"}${lon >= -97.25 ? "e" : "w"}`;
    return txPieces.includes(owner) ? owner : txPieces[0];
  }
  // Ontario South/North share the cut edge; prefer the published half by latitude.
  const onHalves = hits.filter((id) => id === "on-s" || id === "on-n");
  if (onHalves.length) {
    return lat >= 46.0 ? (onHalves.includes("on-n") ? "on-n" : onHalves[0]) : (onHalves.includes("on-s") ? "on-s" : onHalves[0]);
  }
  hits.sort((a, b) => bboxArea(geometryBbox(regions[a])) - bboxArea(geometryBbox(regions[b])));
  return hits[0];
}

function maritimesOwner(lon, lat) {
  return polygonOwner(lon, lat);
}

function resetPolygonCache() {
  cached = null;
}

module.exports = {
  RECORD_PATH,
  geometryBbox,
  loadRegionPolygons,
  maritimesOwner,
  pointInBbox,
  pointInGeometry,
  pointInRegionPolygon,
  polygonOwner,
  resetPolygonCache,
  seamCorridor
};
