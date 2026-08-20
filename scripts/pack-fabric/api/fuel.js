"use strict";

/**
 * Live planning fuel. Resolves the identical per-region candidate override as
 * /api/route, without changing the approved downloadable-pack manifest.
 */
const { loadFuelForLocations } = require("../routing/lib/fuel-data.js");

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  res.setHeader("Cache-Control", "no-store");

  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method === "GET") {
    return res.status(200).json({ ok: true, service: "dirt-live-fuel" });
  }
  if (req.method !== "POST") {
    return res.status(405).json({ ok: false, error: "method_not_allowed" });
  }

  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    const fuel = await loadFuelForLocations(body.locations || []);
    if (!fuel.ok) {
      return res.status(400).json({
        ok: false,
        error: fuel.error,
        message: fuel.message
      });
    }
    return res.status(200).json({
      schema: "fuel.v1",
      regionId: fuel.regionIds.length === 1 ? fuel.regionIds[0] : null,
      regionIds: fuel.regionIds,
      stations: fuel.stations
    });
  } catch (error) {
    console.error("live fuel failed", error);
    return res.status(502).json({
      ok: false,
      error: "fuel_source_unavailable",
      message: "Live packed fuel is temporarily unavailable."
    });
  }
};

module.exports.config = {
  maxDuration: 30,
  memory: 1024
};
