"use strict";

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

async function loadRegionFuel(regionId) {
  const id = String(regionId || "").toLowerCase();
  const url = `${graphCdnBaseUrlForRegion(id)}/${id}/fuel.v1.json`;
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) {
    if (response.status === 404) return { regionId: id, stations: [] };
    throw new Error(`fuel_fetch_${id}_${response.status}`);
  }
  const payload = await response.json();
  return {
    regionId: id,
    stations: Array.isArray(payload && payload.stations) ? payload.stations : []
  };
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
  return {
    ok: true,
    selection,
    regionIds,
    stations: packs.flatMap((pack) => pack.stations)
  };
}

module.exports = {
  loadRegionFuel,
  loadFuelForLocations
};
