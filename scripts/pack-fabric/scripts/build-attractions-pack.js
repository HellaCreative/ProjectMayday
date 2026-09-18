#!/usr/bin/env node
"use strict";

/** Build one whole-region attractions sidecar from osmium GeoJSONSeq. */

const fs = require("fs");
const path = require("path");
const { REGION_BBOX } = require("../routing/regional/select");

const KINDS = ["viewpoint", "attraction", "cave", "waterfall", "lighthouse", "beach"];
const RETAINED_TAGS = new Set([
  "name", "alt_name", "tourism", "natural", "waterway", "man_made", "leisure",
  "amenity", "historic", "website", "contact:website", "addr:city", "addr:province",
  "addr:state"
]);

function records(text) {
  return text
    .split(/\x1e|\r?\n/)
    .map((value) => value.trim())
    .filter(Boolean)
    .map((value) => {
      try { return JSON.parse(value); } catch (_) { return null; }
    })
    .filter(Boolean);
}

function averageCoordinates(values) {
  let longitude = 0;
  let latitude = 0;
  let count = 0;
  for (const coordinate of values || []) {
    if (!Array.isArray(coordinate) || !Number.isFinite(coordinate[0]) || !Number.isFinite(coordinate[1])) continue;
    longitude += coordinate[0];
    latitude += coordinate[1];
    count += 1;
  }
  return count ? [longitude / count, latitude / count] : null;
}

function representativePoint(geometry) {
  if (!geometry) return null;
  if (geometry.type === "Point") return geometry.coordinates;
  if (geometry.type === "LineString") return averageCoordinates(geometry.coordinates);
  if (geometry.type === "Polygon") return averageCoordinates(geometry.coordinates[0]);
  if (geometry.type === "MultiLineString") return averageCoordinates(geometry.coordinates.flat());
  if (geometry.type === "MultiPolygon") {
    const rings = geometry.coordinates.map((polygon) => polygon[0] || []);
    const largest = rings.sort((a, b) => b.length - a.length)[0] || [];
    return averageCoordinates(largest);
  }
  return null;
}

function kind(properties) {
  const tourism = String(properties.tourism || "");
  const natural = String(properties.natural || "");
  const waterway = String(properties.waterway || "");
  const manMade = String(properties.man_made || "");
  const leisure = String(properties.leisure || "");
  const amenity = String(properties.amenity || "");
  if (tourism === "viewpoint") return "viewpoint";
  if (natural === "waterfall" || waterway === "waterfall") return "waterfall";
  if (natural === "cave_entrance" || amenity === "cave_entrance") return "cave";
  if (manMade === "lighthouse") return "lighthouse";
  if (natural === "beach" || leisure === "beach") return "beach";
  if (tourism === "attraction") return "attraction";
  return null;
}

function isClosed(properties) {
  const yes = (value) => ["yes", "true", "1"].includes(String(value || "").toLowerCase());
  return yes(properties.disused) || yes(properties.abandoned);
}

function elementIdentity(feature) {
  const raw = String(feature.id || feature.properties && feature.properties["@id"] || "");
  const match = raw.match(/^([nwr])?(\d+)$/);
  if (!match) return null;
  const type = match[1] === "w" ? "way" : match[1] === "r" ? "relation" : "node";
  return { id: Number(match[2]), type };
}

function retainedTags(properties, normalizedKind) {
  const tags = {};
  for (const [key, raw] of Object.entries(properties || {})) {
    if (!RETAINED_TAGS.has(key) || raw == null) continue;
    const value = String(raw).trim();
    if (value) tags[key] = value;
  }
  tags["dirt:category"] = "attraction";
  tags["dirt:kind"] = normalizedKind;
  return tags;
}

function round6(value) {
  return Math.round(value * 1e6) / 1e6;
}

function inBounds(lon, lat, bounds) {
  return lon >= bounds[0] && lon <= bounds[2] && lat >= bounds[1] && lat <= bounds[3];
}

function buildPack(text, options = {}) {
  const regionId = String(options.regionId || "").toLowerCase();
  const generatedAt = options.generatedAt || new Date().toISOString();
  const sourceUpdatedAt = options.sourceUpdatedAt || null;
  if (!/^[a-z]{2}(-[a-z0-9]+)?$/.test(regionId)) throw new Error("A region id is required");
  const bounds = REGION_BBOX[regionId];
  if (!Array.isArray(bounds) || bounds.length !== 4) {
    throw new Error(`No regional bounds for '${regionId}'`);
  }
  const byIdentity = new Map();
  const counts = Object.fromEntries(KINDS.map((id) => [id, 0]));
  let droppedClosed = 0;
  let droppedGeometry = 0;
  let droppedBounds = 0;
  for (const feature of records(text)) {
    const properties = feature.properties || {};
    const normalizedKind = kind(properties);
    if (!normalizedKind) continue;
    if (isClosed(properties)) {
      droppedClosed += 1;
      continue;
    }
    const identity = elementIdentity(feature);
    const point = representativePoint(feature.geometry);
    if (!identity || !point || !Number.isFinite(point[0]) || !Number.isFinite(point[1])) {
      droppedGeometry += 1;
      continue;
    }
    if (!inBounds(point[0], point[1], bounds)) {
      droppedBounds += 1;
      continue;
    }
    const key = `${identity.type}:${identity.id}`;
    if (byIdentity.has(key)) continue;
    byIdentity.set(key, {
      id: identity.id,
      type: identity.type,
      lat: round6(point[1]),
      lon: round6(point[0]),
      tags: retainedTags(properties, normalizedKind)
    });
    counts[normalizedKind] += 1;
  }
  const elements = [...byIdentity.values()].sort((a, b) =>
    a.type === b.type ? a.id - b.id : a.type.localeCompare(b.type)
  );
  return {
    schema: "attractions.v1",
    regionId,
    generatedAt,
    source: "openstreetmap",
    sourceUpdatedAt,
    license: "Open Database License (ODbL)",
    attribution: "© OpenStreetMap contributors",
    bounds,
    counts,
    dropped: {
      closed: droppedClosed,
      invalidGeometry: droppedGeometry,
      outsideBounds: droppedBounds
    },
    elements
  };
}

function main() {
  const inputPath = process.argv[2];
  const outputPath = process.argv[3];
  const regionId = String(process.env.ATTRACTIONS_REGION_ID || "").toLowerCase();
  if (!inputPath || !outputPath || !/^[a-z]{2}(-[a-z0-9]+)?$/.test(regionId)) {
    throw new Error(
      "Usage: ATTRACTIONS_REGION_ID=ns build-attractions-pack.js <attractions.geojsonseq> <attractions.v1.json>"
    );
  }
  const pack = buildPack(fs.readFileSync(inputPath, "utf8"), {
    regionId,
    generatedAt: process.env.ATTRACTIONS_GENERATED_AT,
    sourceUpdatedAt: process.env.ATTRACTIONS_SOURCE_UPDATED_AT
  });
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(pack));
  console.log(
    `packed attractions ${regionId}: ` +
    KINDS.map((id) => `${id}=${pack.counts[id]}`).join(" ") +
    ` bytes=${fs.statSync(outputPath).size}`
  );
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error && error.message ? error.message : String(error));
    process.exit(1);
  }
}

module.exports = { buildPack, kind, representativePoint };
