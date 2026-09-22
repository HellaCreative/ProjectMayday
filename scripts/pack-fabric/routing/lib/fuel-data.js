"use strict";

const crypto = require("crypto");

/**
 * Candidate-aware packed fuel loader shared by the live fuel list and the
 * graph-connected fuel-chain planner. Fuel and routing must resolve the same
 * R2 candidate prefix or a pump can be present in one fabric and absent from
 * the other.
 */
const {
  resolveGraphRequest,
  graphCdnBaseUrlForRegion
} = require("../regional/select");

const MAX_CACHED_FUEL_REGIONS = 6;
const DEFAULT_FUEL_CACHE_TTL_MS = 5 * 60 * 1000;
const fuelCache = new Map();

function fuelCacheTtlMs() {
  const configured = Number(process.env.ROUTING_FUEL_CACHE_TTL_MS);
  return Number.isFinite(configured) && configured >= 0
    ? configured
    : DEFAULT_FUEL_CACHE_TTL_MS;
}

function touchFuelCache(url) {
  const entry = fuelCache.get(url);
  if (!entry) return null;
  fuelCache.delete(url);
  fuelCache.set(url, entry);
  return entry;
}

function trimFuelCache() {
  while (fuelCache.size > MAX_CACHED_FUEL_REGIONS) {
    fuelCache.delete(fuelCache.keys().next().value);
  }
}

async function fetchRegionFuel(id, url) {
  const started = Date.now();
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) {
    if (response.status === 404) {
      return {
        regionId: id,
        stations: [],
        loadDiagnostics: { cacheHit: false, fetchMs: Date.now() - started }
      };
    }
    throw new Error(`fuel_fetch_${id}_${response.status}`);
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  const payload = JSON.parse(bytes.toString("utf8"));
  const releaseMatch = url.match(/\/(?:candidates|releases)\/([^/]+)\//i);
  return {
    regionId: id,
    stations: Array.isArray(payload && payload.stations) ? payload.stations : [],
    packIdentity: {
      regionId: id,
      releaseId: releaseMatch ? decodeURIComponent(releaseMatch[1]) : null,
      fuelSource: url,
      fuelBytes: bytes.length,
      fuelSha256: crypto.createHash("sha256").update(bytes).digest("hex")
    },
    loadDiagnostics: { cacheHit: false, fetchMs: Date.now() - started }
  };
}

async function loadRegionFuel(regionId) {
  const id = String(regionId || "").toLowerCase();
  const url = `${graphCdnBaseUrlForRegion(id)}/${id}/fuel.v1.json`;
  const now = Date.now();
  const cached = touchFuelCache(url);
  if (cached && now - cached.createdAt <= fuelCacheTtlMs()) {
    const value = await cached.promise;
    return {
      ...value,
      loadDiagnostics: {
        ...(value.loadDiagnostics || {}),
        cacheHit: true,
        cacheAgeMs: Math.max(0, Date.now() - cached.createdAt)
      }
    };
  }
  if (cached) fuelCache.delete(url);
  const entry = {
    createdAt: now,
    promise: fetchRegionFuel(id, url)
  };
  fuelCache.set(url, entry);
  trimFuelCache();
  try {
    return await entry.promise;
  } catch (error) {
    if (fuelCache.get(url) === entry) fuelCache.delete(url);
    throw error;
  }
}

async function loadFuelForLocations(locations) {
  const selection = resolveGraphRequest({ locations: locations || [] });
  if (!selection.ok || !selection.regionIds.length) {
    return {
      ok: false,
      error: selection.error || "region_unknown",
      message: selection.message || "Could not resolve fuel regions.",
      regionIds: []
    };
  }

  const regionIds = [
    ...new Set(selection.regionIds.map((id) => String(id).toLowerCase()))
  ];
  const packs = await Promise.all(regionIds.map(loadRegionFuel));
  const stations = packs.flatMap((pack) => pack.stations);
  Object.defineProperty(stations, "routingCacheKey", {
    value: packs.map((pack) =>
      `${pack.regionId}:${pack.packIdentity && pack.packIdentity.fuelSha256 || "empty"}`
    ).join("|"),
    enumerable: false
  });
  return {
    ok: true,
    selection,
    regionIds,
    stations,
    packIdentity: packs.map((pack) => pack.packIdentity).filter(Boolean),
    loadDiagnostics: {
      cacheHit: packs.every((pack) => pack.loadDiagnostics && pack.loadDiagnostics.cacheHit),
      fetchMs: Math.max(0, ...packs.map((pack) =>
        Number(pack.loadDiagnostics && pack.loadDiagnostics.fetchMs) || 0
      ))
    }
  };
}

function clearFuelCache() {
  fuelCache.clear();
}

module.exports = {
  loadRegionFuel,
  loadFuelForLocations,
  clearFuelCache,
  MAX_CACHED_FUEL_REGIONS,
  DEFAULT_FUEL_CACHE_TTL_MS
};
