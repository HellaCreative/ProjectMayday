"use strict";

const { fuelChainRequest } = require("../routing/lib/fuel-chain.js");

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  res.setHeader("Cache-Control", "no-store");

  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method === "GET") {
    return res.status(200).json({
      ok: true,
      service: "dirt-live-fuel-chain",
      strategy: "forward-graph-reachability"
    });
  }
  if (req.method !== "POST") {
    return res.status(405).json({ status: "error", error: "method_not_allowed" });
  }

  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    const result = await fuelChainRequest(body);
    const status = result.status === "complete" ? 200 : (result.status === "error" ? 400 : 422);
    return res.status(status).json(result);
  } catch (error) {
    console.error("live fuel chain failed", error);
    return res.status(500).json({
      status: "error",
      error: "fuel_chain_internal_error",
      message: error && error.message ? error.message : "Live fuel-chain planning failed."
    });
  }
};

module.exports.config = {
  maxDuration: 60,
  memory: 2048
};
