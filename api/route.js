/**
 * Thin Vercel handler for Phase 2B routing.
 * Loads the prebuilt offline graph once per warm isolate.
 */
const { routeRequest } = require("../routing/lib/router.js");

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
      note: "Regional offline graphs: NRN national backbone + provincial supplements. OSM is basemap/POI only."
    });
  }

  if (req.method !== "POST") {
    return res.status(405).json({ status: "error", error: "method_not_allowed" });
  }

  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : (req.body || {});
    const result = await routeRequest(body);
    const code = result.status === "complete" ? 200 : (result.status === "error" ? 400 : 422);
    return res.status(code).json(result);
  } catch (err) {
    console.error("route failed", err);
    return res.status(500).json({
      status: "error",
      error: "route_internal_error",
      message: err && err.message ? err.message : "Routing failed"
    });
  }
};

module.exports.config = {
  maxDuration: 300,
  memory: 3008,
  includeFiles: ["routing/lib/**", "routing/regional/**", "routing/schema/**", "routing/data/regions/**"]
};
