"use strict";

const path = require("path");

const RECORD_PATH = path.join(__dirname, "..", "data", "region-polygons", "maritimes.v1.json");
const RECORD = require("../data/region-polygons/maritimes.v1.json");

let cached = null;

function loadMaritimesPolygons() {
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
  const geom = loadMaritimesPolygons().regions && loadMaritimesPolygons().regions[id];
  if (!geom) return false;
  return pointInGeometry(lon, lat, geom);
}

/**
 * Admin-polygon owner for Nova Scotia / New Brunswick.
 * Returns null when the point is in neither polygon so bbox logic can continue.
 */
function maritimesOwner(lon, lat) {
  const ns = pointInRegionPolygon("ns", lon, lat);
  const nb = pointInRegionPolygon("nb", lon, lat);
  if (ns && !nb) return "ns";
  if (nb && !ns) return "nb";
  if (ns && nb) return lon >= -64.27 ? "ns" : "nb";
  return null;
}

function resetPolygonCache() {
  cached = null;
}

module.exports = {
  RECORD_PATH,
  loadMaritimesPolygons,
  maritimesOwner,
  pointInGeometry,
  pointInRegionPolygon,
  resetPolygonCache
};
