"use strict";

/** DIRT-owned campground/lodging/liquor viewport service. No runtime OSM calls. */

const { loadRiderServices } = require("../poi/packed-rider-services");

const GRID_DEGREES = 0.05;
const FRESH_MS = 5 * 60 * 1000;
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

function cacheKey(bounds) {
  return [bounds.minLon, bounds.minLat, bounds.maxLon, bounds.maxLat]
    .map((value) => value.toFixed(4))
    .join(",");
}

function cached(key, now = Date.now()) {
  const entry = cache.get(key);
  return entry && now - entry.storedAt <= FRESH_MS ? entry.value : null;
}

function storeCache(key, value, now = Date.now()) {
  cache.delete(key);
  cache.set(key, { value, storedAt: now });
  while (cache.size > MAX_CACHE_ENTRIES) cache.delete(cache.keys().next().value);
}

async function handleRequest(req, res, dependencies = {}) {
  const load = dependencies.loadRiderServices || loadRiderServices;
  const id = requestId(req);
  res.setHeader("X-Dirt-Request-ID", id);
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, X-Dirt-Request-ID");
  res.setHeader("Cache-Control", "no-store");

  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method === "GET") {
    return res.status(200).json({
      ok: true,
      service: "dirt-rider-services",
      source: "packed-r2",
      categories: ["campground", "lodging", "liquor"]
    });
  }
  if (req.method !== "POST") {
    return res.status(405).json({ ok: false, error: "method_not_allowed" });
  }

  let body;
  try {
    body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
  } catch (_) {
    return res.status(400).json({ ok: false, error: "invalid_json" });
  }
  const bounds = normalizedBounds(body);
  if (!bounds) return res.status(400).json({ ok: false, error: "invalid_bounds" });

  const key = cacheKey(bounds);
  const hit = cached(key);
  if (hit) {
    res.setHeader("X-Dirt-POI-Source", "packed-memory-cache");
    return res.status(200).json(hit);
  }

  const started = Date.now();
  try {
    const payload = await load(bounds);
    storeCache(key, payload);
    res.setHeader("X-Dirt-POI-Source", "packed-r2");
    console.log(
      `poi request complete id=${id} source=packed-r2 ` +
      `regions=${payload.regions.join(",")} elements=${payload.elements.length} ` +
      `elapsedMs=${Date.now() - started}`
    );
    return res.status(200).json(payload);
  } catch (error) {
    console.error(
      `poi request failed id=${id} source=packed-r2 elapsedMs=${Date.now() - started} ` +
      `error=${error && error.message || "unknown"}`
    );
    return res.status(503).json({
      ok: false,
      error: "poi_source_unavailable",
      message: "Rider-service points are temporarily unavailable."
    });
  }
}

module.exports = (req, res) => handleRequest(req, res);
module.exports.handleRequest = handleRequest;
module.exports.normalizedBounds = normalizedBounds;
module.exports.config = { maxDuration: 30, memory: 1024 };
