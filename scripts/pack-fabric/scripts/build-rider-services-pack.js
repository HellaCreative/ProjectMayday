#!/usr/bin/env node
"use strict";

/** Build one whole-region campground/lodging/liquor sidecar from osmium GeoJSONSeq. */

const fs = require("fs");
const path = require("path");
const { REGION_BBOX } = require("../routing/regional/select");

const LODGING = new Set([
  "hotel", "motel", "hostel", "guest_house", "chalet", "bed_and_breakfast", "apartment"
]);
const CAMPING = new Set(["camp_site", "caravan_site"]);
const LIQUOR = new Set(["alcohol", "wine"]);
const RETAINED_TAGS = new Set([
  "name", "brand", "operator", "opening_hours", "phone", "contact:phone",
  "website", "contact:website", "addr:housenumber", "addr:street", "addr:city",
  "addr:province", "addr:state", "addr:postcode", "tourism", "shop"
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

function category(properties) {
  if (CAMPING.has(properties.tourism)) return "campground";
  if (LODGING.has(properties.tourism)) return "lodging";
  if (LIQUOR.has(properties.shop)) return "liquor";
  return null;
}

function isClosed(properties) {
  const yes = (value) => ["yes", "true", "1"].includes(String(value || "").toLowerCase());
  return yes(properties.disused) || yes(properties.abandoned) ||
    ["closed", "off"].includes(String(properties.opening_hours || "").trim().toLowerCase());
}

function elementIdentity(feature) {
  const raw = String(feature.id || feature.properties && feature.properties["@id"] || "");
  const match = raw.match(/^([nwr])?(\d+)$/);
  if (!match) return null;
  const type = match[1] === "w" ? "way" : match[1] === "r" ? "relation" : "node";
  return { id: Number(match[2]), type };
}

function retainedTags(properties, normalizedCategory) {
  const tags = {};
  for (const [key, raw] of Object.entries(properties || {})) {
    if (!RETAINED_TAGS.has(key) || raw == null) continue;
    const value = String(raw).trim();
    if (value) tags[key] = value;
  }
  tags["dirt:category"] = normalizedCategory;
  return tags;
}

function round6(value) {
  return Math.round(value * 1e6) / 1e6;
}

function buildPack(text, options = {}) {
  const regionId = String(options.regionId || "").toLowerCase();
  const generatedAt = options.generatedAt || new Date().toISOString();
  const sourceUpdatedAt = options.sourceUpdatedAt || null;
  if (!/^[a-z]{2}$/.test(regionId)) throw new Error("A two-letter region id is required");
  const byIdentity = new Map();
  const counts = { campground: 0, lodging: 0, liquor: 0 };
  let droppedClosed = 0;
  let droppedGeometry = 0;
  for (const feature of records(text)) {
    const properties = feature.properties || {};
    const normalizedCategory = category(properties);
    if (!normalizedCategory) continue;
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
    const key = `${identity.type}:${identity.id}`;
    if (byIdentity.has(key)) continue;
    byIdentity.set(key, {
      id: identity.id,
      type: identity.type,
      lat: round6(point[1]),
      lon: round6(point[0]),
      tags: retainedTags(properties, normalizedCategory)
    });
    counts[normalizedCategory] += 1;
  }
  const elements = [...byIdentity.values()].sort((a, b) =>
    a.type === b.type ? a.id - b.id : a.type.localeCompare(b.type)
  );
  const bounds = REGION_BBOX[regionId];
  if (!Array.isArray(bounds) || bounds.length !== 4) {
    throw new Error(`No regional bounds for '${regionId}'`);
  }
  return {
    schema: "rider-services.v1",
    regionId,
    generatedAt,
    source: "openstreetmap",
    sourceUpdatedAt,
    license: "Open Database License (ODbL)",
    attribution: "© OpenStreetMap contributors",
    bounds,
    counts,
    dropped: { closed: droppedClosed, invalidGeometry: droppedGeometry },
    elements
  };
}

function main() {
  const inputPath = process.argv[2];
  const outputPath = process.argv[3];
  const regionId = String(process.env.RIDER_SERVICES_REGION_ID || "").toLowerCase();
  if (!inputPath || !outputPath || !/^[a-z]{2}$/.test(regionId)) {
    throw new Error(
      "Usage: RIDER_SERVICES_REGION_ID=ns build-rider-services-pack.js <services.geojsonseq> <rider-services.v1.json>"
    );
  }
  const pack = buildPack(fs.readFileSync(inputPath, "utf8"), {
    regionId,
    generatedAt: process.env.RIDER_SERVICES_GENERATED_AT,
    sourceUpdatedAt: process.env.RIDER_SERVICES_SOURCE_UPDATED_AT
  });
  if (!pack.elements.length) throw new Error(`No Rider Services features produced for '${regionId}'`);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(pack));
  console.log(
    `packed rider services ${regionId}: ` +
    `camp=${pack.counts.campground} lodging=${pack.counts.lodging} liquor=${pack.counts.liquor} ` +
    `bytes=${fs.statSync(outputPath).size}`
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

module.exports = { buildPack, category, representativePoint };
