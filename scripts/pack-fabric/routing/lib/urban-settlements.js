"use strict";

const fallbackData = require("./urban-settlements.v1.json");

function fallbackSettlementsForRegion(regionId) {
  const key = String(regionId || "").toLowerCase();
  const rows = fallbackData && fallbackData.regions && fallbackData.regions[key];
  return Array.isArray(rows) ? rows : [];
}

/** Embedded pack metadata is authoritative; compatibility data only fills an empty v3 pack. */
function settlementBoxesForPack(pack, profile) {
  const embedded = pack && pack.meta && Array.isArray(pack.meta.settlements)
    ? pack.meta.settlements
    : [];
  if (embedded.length) return embedded;
  if (String(profile || "").toLowerCase() !== "cleanest") return [];
  const regionId = pack && (pack.regionId || (pack.meta && pack.meta.regionId));
  return fallbackSettlementsForRegion(regionId);
}

module.exports = {
  fallbackSettlementsForRegion,
  settlementBoxesForPack
};
