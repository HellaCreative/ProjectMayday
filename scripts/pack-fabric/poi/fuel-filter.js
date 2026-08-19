"use strict";

/**
 * Motorcycle-usable fuel. Twin of Dirt/Map/FuelPOIFilter.swift
 *
 * Keep bare amenity=fuel. Drop truck-only, cardlock/bulk, known-closed.
 * hgv=yes is not an auto-exclude (retail stations often serve trucks).
 */

const GASOLINE_KEYS = [
  "fuel:gasoline",
  "fuel:petrol",
  "fuel:e10",
  "fuel:e85",
  "fuel:octane_87",
  "fuel:octane_89",
  "fuel:octane_91",
  "fuel:octane_92",
  "fuel:octane_94",
  "fuel:octane_95",
  "fuel:octane_98"
];

function tagYes(v) {
  if (v == null) return false;
  const s = String(v).trim().toLowerCase();
  return s === "yes" || s === "true" || s === "1";
}

function tagNo(v) {
  if (v == null) return false;
  const s = String(v).trim().toLowerCase();
  return s === "no" || s === "false" || s === "0";
}

function normalizeTags(tags) {
  const out = {};
  if (!tags || typeof tags !== "object") return out;
  for (const [k, v] of Object.entries(tags)) {
    if (v == null) continue;
    const key = String(k).trim().toLowerCase();
    const val = String(v).trim().toLowerCase();
    if (!key || !val) continue;
    out[key] = val;
  }
  return out;
}

function hasGasolineYes(tags) {
  return GASOLINE_KEYS.some((k) => tagYes(tags[k]));
}

function hasOctaneYes(tags) {
  return GASOLINE_KEYS.some((k) => k.startsWith("fuel:octane_") && tagYes(tags[k]));
}

function hasExplicitOctaneNo(tags) {
  return GASOLINE_KEYS.some((k) => k.startsWith("fuel:octane_") && tagNo(tags[k]));
}

function isKnownClosed(input, tags) {
  if (tagYes(tags.disused) || tagYes(tags.abandoned)) return true;
  if (tags.amenity === "disused" || tags.amenity === "abandoned") return true;
  if (tags["disused:amenity"] === "fuel" || tags["abandoned:amenity"] === "fuel") return true;
  const hours = String(input.openingHours || tags.opening_hours || "")
    .trim()
    .toLowerCase();
  return hours === "closed" || hours === "off";
}

function isTruckOnly(tags) {
  const hgv = tags.hgv || "";
  if (hgv === "designated" || hgv === "only") return true;
  if (tagYes(tags["fuel:hgv_diesel"]) && !hasGasolineYes(tags)) return true;
  if (tags["capacity:hgv"] != null && (tagYes(tags["fuel:diesel"]) || tagYes(tags["fuel:hgv_diesel"])) && !hasGasolineYes(tags)) {
    return true;
  }
  return false;
}

function isPrivateOrGated(tags) {
  return ["private", "customers", "no", "permit", "military"].includes(tags.access);
}

function isDieselOnlyDepot(tags) {
  if (hasGasolineYes(tags)) return false;
  if (tagNo(tags["fuel:gasoline"]) || tagNo(tags["fuel:petrol"])) {
    return tagYes(tags["fuel:diesel"]) || tagYes(tags["fuel:hgv_diesel"]);
  }
  if (hasExplicitOctaneNo(tags) && !hasOctaneYes(tags)) {
    return tagYes(tags["fuel:diesel"]) || tagYes(tags["fuel:hgv_diesel"]);
  }
  return false;
}

function isBulkOrCardlockName(input, tags) {
  const blobs = [input.name, input.brand, tags.name, tags.brand, tags.operator, tags["operator:type"]]
    .filter(Boolean)
    .map((s) => String(s).toLowerCase());
  const text = blobs.join(" ");
  if (!text) return false;
  if (/card[\s\-]?lock/.test(text)) return true;
  if (/key[\s\-]?lock/.test(text)) return true;
  if (/\bfleet\s+(fuel|card)/.test(text)) return true;
  if (/\bbulk\s+(fuel|plant|station|terminal|depot|card)/.test(text)) return true;
  if (/\bbulk\b/.test(text) && /\b(fuel|gas|petrol|diesel|cardlock)\b/.test(text)) return true;
  return false;
}

function rejection(input) {
  const tags = normalizeTags(input.tags || {});
  if (isKnownClosed(input, tags)) return "closed";
  if (isTruckOnly(tags)) return "truckOnly";
  if (isPrivateOrGated(tags)) return "privateAccess";
  if (isDieselOnlyDepot(tags)) return "dieselOnly";
  if (isBulkOrCardlockName(input, tags)) return "bulkOrCardlock";
  return null;
}

function isMotorcycleUsable(input) {
  return rejection(input) == null;
}

module.exports = {
  isMotorcycleUsable,
  rejection
};
