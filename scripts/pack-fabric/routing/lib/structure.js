"use strict";

/**
 * Structure leaves + rider labels (Phase G2).
 * Lockstep with Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift.
 *
 * Packed codes match regional/package.js STRUCTURE.
 * Leaves are OSM tag values; "yes" is stored as the kind token (bridge/tunnel/ford)
 * so the dictionary distinguishes kinds.
 */

const { STRUCTURE_FERRY, FERRY_CROSSING_LABEL } = require("./ferry");

const STRUCTURE_NONE = 0;
const STRUCTURE_BRIDGE = 1;
const STRUCTURE_TUNNEL = 2;
const STRUCTURE_FORD = 3;

const FALSE_TAG = new Set(["no", "false", "0", "n"]);

const LABEL_BY_LEAF = Object.freeze({
  ford: "Ford",
  stepping_stones: "Ford",
  stream: "Ford",
  tidal: "Ford",
  seasonal: "Ford",
  low_water_crossing: "Low-water crossing",
  boardwalk: "Boardwalk",
  viaduct: "Viaduct",
  culvert: "Culvert",
  building_passage: "Building passage",
  tunnel: "Tunnel",
  bridge: "Bridge"
});

function isPresentTag(raw) {
  if (raw == null) return false;
  const s = String(raw).trim().toLowerCase();
  if (!s) return false;
  return !FALSE_TAG.has(s);
}

function normalizeStructureLeaf(raw) {
  if (raw == null) return null;
  const s = String(raw).trim().toLowerCase();
  return s || null;
}

/**
 * Map OSM bridge/tunnel/ford tags → coarse structureType + preserved leaf.
 * Ford wins (water-crossing safety), then tunnel, then bridge.
 */
function structureFromTags({ bridge, tunnel, ford } = {}) {
  if (isPresentTag(ford)) {
    const v = normalizeStructureLeaf(ford);
    return {
      structureType: "ford",
      structureLeaf: v === "yes" ? "ford" : v
    };
  }
  if (isPresentTag(tunnel)) {
    const v = normalizeStructureLeaf(tunnel);
    return {
      structureType: "tunnel",
      structureLeaf: v === "yes" ? "tunnel" : v
    };
  }
  if (isPresentTag(bridge)) {
    const v = normalizeStructureLeaf(bridge);
    const leaf = v === "yes" ? "bridge" : v;
    // At-grade floodable bridges behave as water crossings for grade + labeling.
    if (leaf === "low_water_crossing") {
      return { structureType: "ford", structureLeaf: leaf };
    }
    return {
      structureType: "bridge",
      structureLeaf: leaf
    };
  }
  return { structureType: "none", structureLeaf: null };
}

function structureCodeFromType(structureType) {
  if (structureType === "bridge") return STRUCTURE_BRIDGE;
  if (structureType === "tunnel") return STRUCTURE_TUNNEL;
  if (structureType === "ford") return STRUCTURE_FORD;
  if (structureType === "ferry") return STRUCTURE_FERRY;
  return STRUCTURE_NONE;
}

function isWaterCrossing({ structureCode, structureLeaf } = {}) {
  if (Number(structureCode) === STRUCTURE_FORD) return true;
  const leaf = normalizeStructureLeaf(structureLeaf);
  if (!leaf) return false;
  return (
    leaf === "ford" ||
    leaf === "low_water_crossing" ||
    leaf === "stepping_stones" ||
    leaf === "stream" ||
    leaf === "tidal"
  );
}

/**
 * Rider-facing structure label. Tunnel stays "Tunnel" even when layer < 0 so
 * overpass / underpass / tunnel stay distinguishable.
 */
function structureCrossingLabel({ structureCode, structureLeaf, layer } = {}) {
  const code = Number(structureCode);
  if (code === STRUCTURE_FERRY) return FERRY_CROSSING_LABEL;
  const leaf = normalizeStructureLeaf(structureLeaf);
  if (leaf && LABEL_BY_LEAF[leaf] && leaf !== "bridge") {
    return LABEL_BY_LEAF[leaf];
  }
  const layerN = Number(layer) || 0;
  if (code === STRUCTURE_TUNNEL || leaf === "tunnel") return "Tunnel";
  if (code === STRUCTURE_FORD || leaf === "ford") return "Ford";
  if (code === STRUCTURE_BRIDGE || leaf === "bridge") {
    if (layerN > 0) return "Overpass";
    if (layerN < 0) return "Underpass";
    return "Bridge";
  }
  if (layerN > 0) return "Overpass";
  if (layerN < 0) return "Underpass";
  return null;
}

function segmentStructureFields({ structureCode, structureLeaf, layer } = {}) {
  return {
    crossingLabel: structureCrossingLabel({ structureCode, structureLeaf, layer }),
    waterCrossing: isWaterCrossing({ structureCode, structureLeaf }),
    structureLeaf: normalizeStructureLeaf(structureLeaf),
    layer: Number(layer) || 0
  };
}

module.exports = {
  STRUCTURE_NONE,
  STRUCTURE_BRIDGE,
  STRUCTURE_TUNNEL,
  STRUCTURE_FORD,
  LABEL_BY_LEAF,
  isPresentTag,
  normalizeStructureLeaf,
  structureFromTags,
  structureCodeFromType,
  isWaterCrossing,
  structureCrossingLabel,
  segmentStructureFields
};
