"use strict";

const {
  candidateRegionsForPoint,
  resolveGraphRequest
} = require("./select");
const { loadGraphsForRequest } = require("../lib/graph");
const { unpackAccess } = require("../lib/pack-v2");

const EARTH_M = 6371000;
const DEFAULT_SNAP_METERS = 500;

function haversineMeters(a, b) {
  const toRad = (value) => value * Math.PI / 180;
  const dLat = toRad(b[1] - a[1]);
  const dLon = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_M * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

function projectOnSegment(point, a, b) {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const lengthSquared = dx * dx + dy * dy;
  const t = lengthSquared > 0
    ? Math.max(0, Math.min(1, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / lengthSquared))
    : 0;
  const projected = [a[0] + dx * t, a[1] + dy * t];
  return { coordinate: projected, meters: haversineMeters(point, projected) };
}

function accessEligible(name, allowUnknown) {
  if (name === "motorized_verified" || name === "motorized_permissive") return true;
  if (name === "motorized_unknown") return !!allowUnknown;
  return false;
}

function candidateEdgeIndexes(runtime, point, radiusMeters) {
  if (runtime.format !== "v2") {
    return runtime.data.edges.map((_, index) => index);
  }
  const grid = Number(runtime.GRID) || 0.01;
  const latPad = radiusMeters / 111320;
  const lonPad = radiusMeters / (111320 * Math.max(0.2, Math.cos(point[1] * Math.PI / 180)));
  const indexes = new Set();
  for (let x = Math.floor((point[0] - lonPad) / grid); x <= Math.floor((point[0] + lonPad) / grid); x += 1) {
    for (let y = Math.floor((point[1] - latPad) / grid); y <= Math.floor((point[1] + latPad) / grid); y += 1) {
      for (const index of runtime.edgeGrid.get(`${x}:${y}`) || []) indexes.add(index);
    }
  }
  return [...indexes];
}

function nearestEligibleEdge(runtime, location, options = {}) {
  const lon = Number(location && (location.lon != null ? location.lon : location.lng));
  const lat = Number(location && location.lat);
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
    return { ok: false, reason: "invalid_location" };
  }
  const point = [lon, lat];
  const radiusMeters = Number(options.radiusMeters) || DEFAULT_SNAP_METERS;
  const allowUnknown = !!options.allowUnknown;
  const enums = runtime.enums;
  let nearest = null;
  for (const index of candidateEdgeIndexes(runtime, point, radiusMeters)) {
    let accessName;
    let edgeId;
    let coordinates;
    if (runtime.format === "v2") {
      const attr = runtime.pack.edgeAttrs[index];
      accessName = enums.ACCESS_NAME[unpackAccess(attr)];
      edgeId = runtime.pack.edgeId(index);
      coordinates = runtime.geom.polyline(index);
    } else {
      const edge = runtime.data.edges[index];
      accessName = enums.ACCESS_NAME[edge.ac];
      edgeId = edge.i;
      coordinates = edge.g || [];
    }
    if (!accessEligible(accessName, allowUnknown)) continue;
    for (let segment = 1; segment < coordinates.length; segment += 1) {
      const projected = projectOnSegment(point, coordinates[segment - 1], coordinates[segment]);
      if (!nearest || projected.meters < nearest.distanceM) {
        nearest = {
          ok: projected.meters <= radiusMeters,
          edgeId: String(edgeId),
          accessClass: accessName,
          distanceM: projected.meters,
          coordinate: projected.coordinate
        };
      }
    }
  }
  if (!nearest || !nearest.ok) {
    return {
      ok: false,
      reason: "snap_no_eligible_edge",
      nearestMeters: nearest ? Math.round(nearest.distanceM) : null
    };
  }
  return nearest;
}

async function probeRegion(regionId, location, body) {
  const lon = Number(location.lon != null ? location.lon : location.lng);
  const lat = Number(location.lat);
  const probeLocations = [
    { lon, lat },
    { lon: lon + 0.002, lat: lat + 0.002 }
  ];
  const resolution = resolveGraphRequest({
    regionId,
    locations: probeLocations,
    disableLonghaul: true,
    disableChain: true
  });
  const runtime = await loadGraphsForRequest(resolution, {
    locations: probeLocations,
    profile: body.profile,
    forceCorridorClip: true,
    corridorBufferMeters: 1200
  });
  return nearestEligibleEdge(runtime, location, {
    radiusMeters: DEFAULT_SNAP_METERS,
    allowUnknown: body.allowUnknown === true
      || (body.accessPolicy && body.accessPolicy.motorizedUnknown === true)
  });
}

async function resolveLocationsByEligibleEdge(body = {}, dependencies = {}) {
  if (body.regionId || !Array.isArray(body.locations)) {
    return { body, resolutions: [] };
  }
  const runProbe = dependencies.probeRegion || probeRegion;
  const resolutions = [];
  const locations = [];
  for (let index = 0; index < body.locations.length; index += 1) {
    const location = body.locations[index];
    const lon = Number(location && (location.lon != null ? location.lon : location.lng));
    const lat = Number(location && location.lat);
    const candidates = candidateRegionsForPoint(lon, lat);
    if (candidates.length <= 1) {
      locations.push(location);
      if (candidates[0]) resolutions.push({ index, regionId: candidates[0], candidates, probes: [] });
      continue;
    }

    const probes = [];
    let selected = null;
    for (const regionId of candidates) {
      try {
        const result = await runProbe(regionId, location, body);
        probes.push({ regionId, ...result });
        if (result && result.ok) {
          selected = { regionId, ...result };
          break;
        }
      } catch (error) {
        probes.push({
          regionId,
          ok: false,
          reason: "probe_failed",
          message: error && error.message ? error.message : String(error)
        });
      }
    }
    const regionId = selected ? selected.regionId : candidates[0];
    locations.push({ ...location, resolvedRegionId: regionId });
    resolutions.push({ index, regionId, candidates, probes });
  }
  return { body: { ...body, locations }, resolutions };
}

module.exports = {
  DEFAULT_SNAP_METERS,
  nearestEligibleEdge,
  resolveLocationsByEligibleEdge
};
