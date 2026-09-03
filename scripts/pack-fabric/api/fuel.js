"use strict";

/**
 * Live planning fuel. Resolves the identical per-region candidate override as
 * /api/route, without changing the approved downloadable-pack manifest.
 */
const { loadFuelForLocations } = require("../routing/lib/fuel-data.js");
const {
  ROUTING_SERVICE_CONTRACT,
  serviceBuild,
  withServiceIdentity
} = require("../routing/lib/service-contract.js");

module.exports = async function handler(req, res) {
  const suppliedRequestId = String(
    req.headers && req.headers["x-dirt-request-id"] || ""
  ).trim();
  const requestId = /^[a-zA-Z0-9-]{1,64}$/.test(suppliedRequestId)
    ? suppliedRequestId
    : `fueldata-${Date.now().toString(36)}`;
  res.setHeader("X-Dirt-Request-ID", requestId);
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, X-Dirt-Request-ID");
  res.setHeader("Cache-Control", "no-store");

  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method === "GET") {
    return res.status(200).json({
      ok: true,
      service: "dirt-live-fuel",
      serviceContract: ROUTING_SERVICE_CONTRACT,
      serviceBuild: serviceBuild()
    });
  }
  if (req.method !== "POST") {
    return res.status(405).json({ ok: false, error: "method_not_allowed" });
  }

  const started = Date.now();
  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    console.log(
      `fuel data request begin id=${requestId} ` +
      `locations=${Array.isArray(body.locations) ? body.locations.length : 0}`
    );
    const fuel = await loadFuelForLocations(body.locations || []);
    if (!fuel.ok) {
      return res.status(400).json(withServiceIdentity({
        ok: false,
        error: fuel.error,
        message: fuel.message
      }));
    }
    console.log(
      `fuel data request end id=${requestId} elapsedMs=${Date.now() - started} ` +
      `regions=${fuel.regionIds.join(",")} stations=${fuel.stations.length}`
    );
    return res.status(200).json({
      schema: "fuel.v1",
      regionId: fuel.regionIds.length === 1 ? fuel.regionIds[0] : null,
      regionIds: fuel.regionIds,
      packIdentity: fuel.packIdentity || [],
      serviceContract: ROUTING_SERVICE_CONTRACT,
      serviceBuild: serviceBuild(),
      stations: fuel.stations
    });
  } catch (error) {
    console.error(`live fuel failed id=${requestId} elapsedMs=${Date.now() - started}`, error);
    return res.status(502).json(withServiceIdentity({
      ok: false,
      error: "fuel_source_unavailable",
      message: "Live packed fuel is temporarily unavailable."
    }));
  }
};

module.exports.config = {
  maxDuration: 30,
  memory: 1024
};
