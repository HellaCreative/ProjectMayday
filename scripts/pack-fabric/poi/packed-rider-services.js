"use strict";

const crypto = require("crypto");

const DEFAULT_BASE = (
  process.env.RIDER_SERVICES_BASE_URL ||
  "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/rider-services/v1"
).replace(/\/$/, "");
const MANIFEST_TTL_MS = 5 * 60 * 1000;
const REGION_TTL_MS = 30 * 60 * 1000;
const MAX_REGION_CACHE = 8;
const MAX_INTERSECTING_REGIONS = 8;
const FETCH_TIMEOUT_MS = 10_000;
const manifestCache = new Map();
const regionCache = new Map();

function validSha256(value) {
  return /^[a-f0-9]{64}$/i.test(String(value || ""));
}

function validateManifest(manifest) {
  if (!manifest || manifest.schema !== "rider-services-manifest.v1" || !Array.isArray(manifest.regions)) {
    throw new Error("invalid_rider_services_manifest");
  }
  const ids = new Set();
  for (const region of manifest.regions) {
    const id = String(region && region.id || "").toLowerCase();
    const bounds = region && region.bounds;
    const file = region && region.file;
    if (!/^[a-z]{2}$/.test(id) || ids.has(id)) throw new Error("invalid_rider_services_region");
    if (
      !Array.isArray(bounds) || bounds.length !== 4 || !bounds.every(Number.isFinite) ||
      bounds[0] < -180 || bounds[2] > 180 || bounds[1] < -90 || bounds[3] > 90 ||
      bounds[0] >= bounds[2] || bounds[1] >= bounds[3]
    ) {
      throw new Error(`invalid_rider_services_bounds_${id}`);
    }
    if (
      !file || !/^rider-services\.v1\.[a-f0-9]{12}\.json$/i.test(String(file.name || "")) ||
      !Number.isSafeInteger(Number(file.bytes)) || Number(file.bytes) <= 0 ||
      !validSha256(file.sha256)
    ) {
      throw new Error(`invalid_rider_services_identity_${id}`);
    }
    ids.add(id);
  }
  return manifest;
}

function intersects(bounds, regionBounds) {
  return !(
    bounds.maxLon < regionBounds[0] ||
    bounds.minLon > regionBounds[2] ||
    bounds.maxLat < regionBounds[1] ||
    bounds.minLat > regionBounds[3]
  );
}

function inside(bounds, element) {
  const lon = Number(element && (element.lon ?? (element.center && element.center.lon)));
  const lat = Number(element && (element.lat ?? (element.center && element.center.lat)));
  return Number.isFinite(lon) && Number.isFinite(lat) &&
    lon >= bounds.minLon && lon <= bounds.maxLon &&
    lat >= bounds.minLat && lat <= bounds.maxLat;
}

async function fetchBuffer(url, fetchImpl, maximumBytes) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const response = await fetchImpl(url, { cache: "no-store", signal: controller.signal });
    if (!response.ok) throw new Error(`rider_services_http_${response.status}`);
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > maximumBytes) throw new Error("rider_services_response_too_large");
    return buffer;
  } finally {
    clearTimeout(timer);
  }
}

async function loadManifest({ baseURL, fetchImpl, now }) {
  const cached = manifestCache.get(baseURL);
  if (cached && now - cached.createdAt <= MANIFEST_TTL_MS) return cached.promise;
  if (cached) manifestCache.delete(baseURL);
  const entry = {
    createdAt: now,
    promise: (async () => {
      const buffer = await fetchBuffer(`${baseURL}/manifest.json`, fetchImpl, 512 * 1024);
      return validateManifest(JSON.parse(buffer.toString("utf8")));
    })()
  };
  manifestCache.set(baseURL, entry);
  try {
    return await entry.promise;
  } catch (error) {
    if (manifestCache.get(baseURL) === entry) manifestCache.delete(baseURL);
    throw error;
  }
}

function touchRegionCache(key) {
  const entry = regionCache.get(key);
  if (!entry) return null;
  regionCache.delete(key);
  regionCache.set(key, entry);
  return entry;
}

function trimRegionCache() {
  while (regionCache.size > MAX_REGION_CACHE) {
    regionCache.delete(regionCache.keys().next().value);
  }
}

async function loadRegion(region, { baseURL, fetchImpl, now }) {
  const key = `${baseURL}/${region.id}/${region.file.sha256}`;
  const cached = touchRegionCache(key);
  if (cached && now - cached.createdAt <= REGION_TTL_MS) return cached.value;
  const promise = (async () => {
    const buffer = await fetchBuffer(
      `${baseURL}/${region.id}/${region.file.name}`,
      fetchImpl,
      16 * 1024 * 1024
    );
    const hash = crypto.createHash("sha256").update(buffer).digest("hex");
    if (buffer.length !== Number(region.file.bytes) || hash !== String(region.file.sha256).toLowerCase()) {
      throw new Error(`rider_services_identity_mismatch_${region.id}`);
    }
    const value = JSON.parse(buffer.toString("utf8"));
    if (
      value.schema !== "rider-services.v1" ||
      value.regionId !== region.id ||
      !Array.isArray(value.elements)
    ) {
      throw new Error(`invalid_rider_services_pack_${region.id}`);
    }
    return value;
  })();
  regionCache.set(key, { createdAt: now, value: promise });
  trimRegionCache();
  try {
    return await promise;
  } catch (error) {
    regionCache.delete(key);
    throw error;
  }
}

async function loadRiderServices(bounds, options = {}) {
  const baseURL = String(options.baseURL || DEFAULT_BASE).replace(/\/$/, "");
  const fetchImpl = options.fetchImpl || fetch;
  const now = Number.isFinite(options.now) ? options.now : Date.now();
  const manifest = await loadManifest({ baseURL, fetchImpl, now });
  const regions = manifest.regions.filter((region) => intersects(bounds, region.bounds));
  if (regions.length > MAX_INTERSECTING_REGIONS) {
    throw new Error("too_many_intersecting_rider_service_regions");
  }
  const packs = await Promise.all(regions.map((region) =>
    loadRegion(region, { baseURL, fetchImpl, now })
  ));
  const seen = new Set();
  const elements = [];
  for (const element of packs.flatMap((pack) => pack.elements)) {
    if (!inside(bounds, element)) continue;
    const key = `${element.type || "node"}:${element.id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    elements.push(element);
  }
  elements.sort((a, b) => {
    const aKey = `${a.type || "node"}:${String(a.id)}`;
    const bKey = `${b.type || "node"}:${String(b.id)}`;
    return aKey.localeCompare(bKey);
  });
  return {
    schema: "rider-services-response.v1",
    catalogGeneratedAt: manifest.generatedAt || null,
    regions: regions.map((region) => region.id),
    elements
  };
}

function clearCaches() {
  manifestCache.clear();
  regionCache.clear();
}

module.exports = {
  DEFAULT_BASE,
  clearCaches,
  inside,
  intersects,
  loadRiderServices,
  validateManifest
};
