"use strict";

const { fuelChainRequest } = require("../routing/lib/fuel-chain.js");
const {
  ROUTING_SERVICE_CONTRACT,
  serviceBuild,
  withServiceIdentity
} = require("../routing/lib/service-contract.js");

function echoLegId(result, legId) {
  if (legId == null || legId === "" || !result || typeof result !== "object") return result;
  return { ...result, legId };
}

module.exports = async function handler(req, res) {
  const suppliedRequestId = String(
    req.headers && req.headers["x-dirt-request-id"] || ""
  ).trim();
  const requestId = /^[a-zA-Z0-9-]{1,64}$/.test(suppliedRequestId)
    ? suppliedRequestId
    : `fuel-${Date.now().toString(36)}`;
  res.setHeader("X-Dirt-Request-ID", requestId);
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, X-Dirt-Request-ID");
  res.setHeader("Cache-Control", "no-store");

  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method === "GET") {
    const { FUEL_CHAIN_SERVICE_VERSION } = require("../routing/lib/fuel-chain.js");
    return res.status(200).json({
      ok: true,
      service: "dirt-live-fuel-chain",
      strategy: "forward-graph-reachability",
      serviceContract: ROUTING_SERVICE_CONTRACT,
      serviceBuild: serviceBuild(),
      serviceVersion: FUEL_CHAIN_SERVICE_VERSION
    });
  }
  if (req.method !== "POST") {
    return res.status(405).json({ status: "error", error: "method_not_allowed" });
  }

  const started = Date.now();
  const abortController = new AbortController();
  const abortRequest = () => abortController.abort();
  if (typeof req.once === "function") req.once("aborted", abortRequest);
  if (typeof res.once === "function") {
    res.once("close", () => {
      if (!res.writableEnded) abortRequest();
    });
  }
  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    body.options = { ...(body.options || {}), abortSignal: abortController.signal };
    console.log(
      `fuel request begin id=${requestId} profile=${body.profile || "-"} ` +
      `riderLeg=${body.fuel && body.fuel.riderLegId || "-"} ` +
      `locations=${Array.isArray(body.locations) ? body.locations.length : 0} ` +
      `budgetMs=${body.fuel && body.fuel.windowTimeBudgetMs || "-"}`
    );
    const result = echoLegId(await fuelChainRequest(body), body.legId);
    const diagnostics = result && result.diagnostics || {};
    console.log(
      `fuel request end id=${requestId} status=${result.status || "-"} ` +
      `elapsedMs=${Date.now() - started} ` +
      `stops=${Array.isArray(result.stops) ? result.stops.length : 0}`
    );
    console.log(
      `fuel phases id=${requestId} endpoint=${diagnostics.endpointResolutionMs ?? "-"}ms ` +
      `load=${diagnostics.planningDataLoadMs ?? "-"}ms ` +
      `routeFirst=${diagnostics.routeFirstMs ?? "-"}ms ` +
      `(snap=${diagnostics.routeFirstSnapMs ?? "-"}/search=${diagnostics.routeFirstSearchMs ?? "-"}` +
      `/post=${diagnostics.routeFirstPostprocessMs ?? "-"}/pops=${diagnostics.routeFirstPops ?? "-"}) ` +
      `routeSearchGranted=${diagnostics.routeFirstSearchBudgetGrantedMs ?? "-"}ms ` +
      `loadRelief=${diagnostics.routeFirstLoadBudgetReliefMs ?? "-"}ms ` +
      `escape=${diagnostics.destinationEscapeSearchMs ?? "-"}ms ` +
      `targets=${diagnostics.targetPrepareMs ?? "-"}ms ` +
      `fuelSearch=${diagnostics.elapsedMs ?? "-"}ms ` +
      `profileRoutes=${diagnostics.profileRouteAttempts ?? "-"} ` +
      `deadlinePhase=${diagnostics.deadlinePhase || "-"} ` +
      `overrun=${diagnostics.windowBudgetOverrunMs ?? 0}ms`
    );
    const status = result.status === "complete" ? 200 : (result.status === "error" ? 400 : 422);
    return res.status(status).json(withServiceIdentity(result));
  } catch (error) {
    console.error(
      `live fuel chain failed id=${requestId} elapsedMs=${Date.now() - started}`,
      error
    );
    return res.status(500).json(withServiceIdentity({
      status: "error",
      error: "fuel_chain_internal_error",
      message: error && error.message ? error.message : "Live fuel-chain planning failed."
    }));
  }
};

module.exports.config = {
  maxDuration: 60,
  memory: 2048
};
module.exports.echoLegId = echoLegId;
