"use strict";

/**
 * Bounded campground / lodging / liquor viewport service. The phone talks to
 * DIRT, while this function handles public Overpass fallback and short-lived
 * caching. Fuel remains pack-only through /api/fuel.
 */

const OVERPASS_ENDPOINTS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass.private.coffee/api/interpreter"
];
const GRID_DEGREES = 0.05;
const FRESH_MS = 5 * 60 * 1000;
const STALE_MS = 24 * 60 * 60 * 1000;
const MAX_CACHE_ENTRIES = 64;
const cache = new Map();

function requestId(req) {
  const supplied = String(req.headers && req.headers["x-dirt-request-id"] || "").trim();
  return /^[a-zA-Z0-9-]{1,64}$/.test(supplied)
    ? supplied
    : `poi-${Date.now().toString(36)}`;
}

function finite(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function normalizedBounds(body) {
  const minLon = finite(body && body.minLon);
  const minLat = finite(body && body.minLat);
  const maxLon = finite(body && body.maxLon);
  const maxLat = finite(body && body.maxLat);
  if ([minLon, minLat, maxLon, maxLat].some((value) => value == null)) return null;
  if (minLon < -180 || maxLon > 180 || minLat < -90 || maxLat > 90) return null;
  if (minLon >= maxLon || minLat >= maxLat) return null;
  if (maxLon - minLon > 20 || maxLat - minLat > 20) return null;
  const floor = (value) => Math.floor(value / GRID_DEGREES) * GRID_DEGREES;
  const ceil = (value) => Math.ceil(value / GRID_DEGREES) * GRID_DEGREES;
  return {
    minLon: Math.max(-180, floor(minLon)),
    minLat: Math.max(-90, floor(minLat)),
    maxLon: Math.min(180, ceil(maxLon)),
    maxLat: Math.min(90, ceil(maxLat))
  };
}

function overpassQuery(bounds) {
  const bbox = `${bounds.minLat},${bounds.minLon},${bounds.maxLat},${bounds.maxLon}`;
  return `[out:json][timeout:12];(` +
    `nwr["tourism"~"^(hotel|motel|hostel|guest_house|chalet)$"](${bbox});` +
    `nwr["tourism"~"^(camp_site|caravan_site)$"](${bbox});` +
    `nwr["shop"="alcohol"](${bbox});` +
    `);out center tags;`;
}

function cacheKey(bounds) {
  return [bounds.minLon, bounds.minLat, bounds.maxLon, bounds.maxLat]
    .map((value) => value.toFixed(4))
    .join(",");
}

function storeCache(key, value, now = Date.now()) {
  cache.delete(key);
  cache.set(key, { value, storedAt: now });
  while (cache.size > MAX_CACHE_ENTRIES) cache.delete(cache.keys().next().value);
}

function cached(key, maximumAge, now = Date.now()) {
  const entry = cache.get(key);
  return entry && now - entry.storedAt <= maximumAge ? entry.value : null;
}

async function fetchWithTimeout(url, options, timeoutMs, fetchImpl) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function fetchOverpass(query, {
  fetchImpl = fetch,
  endpoints = OVERPASS_ENDPOINTS,
  timeoutMs = 7000
} = {}) {
  const body = new URLSearchParams({ data: query }).toString();
  const failures = [];
  for (const endpoint of endpoints) {
    try {
      const response = await fetchWithTimeout(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
          "User-Agent": "DIRT-POI/1.0 (dual-sport navigator)"
        },
        body
      }, timeoutMs, fetchImpl);
      if (!response.ok) {
        failures.push(`${new URL(endpoint).host}:http_${response.status}`);
        continue;
      }
      const text = await response.text();
      if (text.length > 8 * 1024 * 1024) {
        failures.push(`${new URL(endpoint).host}:response_too_large`);
        continue;
      }
      const parsed = JSON.parse(text);
      if (!Array.isArray(parsed.elements)) {
        failures.push(`${new URL(endpoint).host}:invalid_payload`);
        continue;
      }
      return { payload: { elements: parsed.elements }, endpoint };
    } catch (error) {
      failures.push(`${new URL(endpoint).host}:${error && error.name || "failed"}`);
    }
  }
  const error = new Error("all_upstreams_failed");
  error.failures = failures;
  throw error;
}

async function handler(req, res) {
  const id = requestId(req);
  res.setHeader("X-Dirt-Request-ID", id);
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, X-Dirt-Request-ID");
  res.setHeader("Cache-Control", "no-store");

  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method === "GET") {
    return res.status(200).json({ ok: true, service: "dirt-rider-services", categories: [
      "campground", "lodging", "liquor"
    ] });
  }
  if (req.method !== "POST") {
    return res.status(405).json({ ok: false, error: "method_not_allowed" });
  }

  let body;
  try {
    body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
  } catch {
    return res.status(400).json({ ok: false, error: "invalid_json" });
  }
  const bounds = normalizedBounds(body);
  if (!bounds) return res.status(400).json({ ok: false, error: "invalid_bounds" });

  const key = cacheKey(bounds);
  const fresh = cached(key, FRESH_MS);
  if (fresh) {
    res.setHeader("X-Dirt-POI-Source", "memory-cache");
    return res.status(200).json(fresh);
  }

  const started = Date.now();
  try {
    const result = await fetchOverpass(overpassQuery(bounds));
    storeCache(key, result.payload);
    const source = new URL(result.endpoint).host;
    res.setHeader("X-Dirt-POI-Source", source);
    console.log(
      `poi request complete id=${id} source=${source} ` +
      `elements=${result.payload.elements.length} elapsedMs=${Date.now() - started}`
    );
    return res.status(200).json(result.payload);
  } catch (error) {
    const stale = cached(key, STALE_MS);
    if (stale) {
      res.setHeader("X-Dirt-POI-Source", "stale-memory-cache");
      console.warn(`poi request stale id=${id} elapsedMs=${Date.now() - started}`);
      return res.status(200).json(stale);
    }
    console.error(
      `poi request failed id=${id} elapsedMs=${Date.now() - started} ` +
      `upstreams=${Array.isArray(error.failures) ? error.failures.join(",") : "unknown"}`
    );
    return res.status(503).json({
      ok: false,
      error: "poi_source_unavailable",
      message: "Rider-service points are temporarily unavailable."
    });
  }
}

module.exports = handler;
module.exports.normalizedBounds = normalizedBounds;
module.exports.overpassQuery = overpassQuery;
module.exports.fetchOverpass = fetchOverpass;
module.exports.config = { maxDuration: 30, memory: 1024 };

