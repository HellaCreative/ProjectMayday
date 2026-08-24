"use strict";

const path = require("path");

const RECORD_PATH = path.join(__dirname, "..", "data", "v3-regions.json");
const RECORD = require("../data/v3-regions.json");

let cached = null;

function loadV3RegionRecord() {
  if (cached) return cached;
  const record = RECORD;
  if (!record || !Array.isArray(record.regions)) {
    throw new Error("v3-regions.json is missing a regions array");
  }
  cached = {
    graphFileName: String(record.graphFileName || "graph.v3.bin"),
    fallbackGraphFileName: String(record.fallbackGraphFileName || "graph.v2.bin"),
    regions: new Set(record.regions.map((id) => String(id).toLowerCase()))
  };
  return cached;
}

function isV3Region(regionId) {
  const id = String(regionId || "").toLowerCase();
  if (id === "__legacy_ns__") return true;
  return loadV3RegionRecord().regions.has(id);
}

function phoneGraphFileNameForRegion(regionId) {
  const record = loadV3RegionRecord();
  return isV3Region(regionId) ? record.graphFileName : record.fallbackGraphFileName;
}

function resetV3RegionCache() {
  cached = null;
}

module.exports = {
  RECORD_PATH,
  isV3Region,
  phoneGraphFileNameForRegion,
  resetV3RegionCache,
  loadV3RegionRecord
};
