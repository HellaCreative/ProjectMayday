/**
 * Thin Vercel handler for Phase 2B routing.
 * Loads the prebuilt offline graph once per warm isolate.
 */
const { routeRequest } = require("../routing/lib/router.js");
const {
  ROUTING_SERVICE_CONTRACT,
  serviceBuild,
  withServiceIdentity
} = require("../routing/lib/service-contract.js");

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") return res.status(200).end();

  if (req.method === "GET") {
    return res.status(200).json({
      ok: true,
      service: "dirt-route",
      engine: "dirt-node-astar",
      serviceContract: ROUTING_SERVICE_CONTRACT,
      serviceBuild: serviceBuild(),
      note: "BC foundational pack is OSM-only; DRA/FTEN are inactive. Other regional stacks remain recorded in routing/registry/sources.json."
    });
  }

  if (req.method !== "POST") {
    return res.status(405).json({ status: "error", error: "method_not_allowed" });
  }

  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    const result = await routeRequest(body);
    const code = result.status === "complete" ? 200 : (result.status === "error" ? 400 : 422);
    return res.status(code).json(withServiceIdentity(result));
  } catch (err) {
    console.error("route failed", err);
    const message = err && err.message ? err.message : "Routing failed";
    const memoryPressure = /graph_memory_pressure/i.test(message);
    return res.status(memoryPressure ? 503 : 500).json(withServiceIdentity({
      status: "error",
      error: memoryPressure ? "graph_memory_pressure" : "route_internal_error",
      message,
      // Helps Debug dumps when the isolate survives long enough to respond.
      rssMb:
        typeof process.memoryUsage === "function"
          ? Math.round(process.memoryUsage().rss / (1024 * 1024))
          : null
    }));
  }
};

module.exports.config = {
  maxDuration: 300,
  // Hobby: API code only. Graphs load from R2. Never include pack binaries.
  memory: 2048
};
