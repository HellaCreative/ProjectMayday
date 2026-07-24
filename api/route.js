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
      note: "NS: OSM+NSTDB (no NRN). NB: OSM+Forest Roads (no NRN; provincial kept on longhaul). QC/PE: OSM-only. Other longhaul: OSM+NRN fabric; provincial capillary unknown-gated on full packs."
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
    const message = err && err.message ? err.message : "Routing failed";
    const memoryPressure = /graph_memory_pressure/i.test(message);
    return res.status(memoryPressure ? 503 : 500).json({
      status: "error",
      error: memoryPressure ? "graph_memory_pressure" : "route_internal_error",
      message,
      // Helps Debug dumps when the isolate survives long enough to respond.
      rssMb:
        typeof process.memoryUsage === "function"
          ? Math.round(process.memoryUsage().rss / (1024 * 1024))
          : null
    });
  }
};

module.exports.config = {
  maxDuration: 300,
  // Hobby personal accounts cap at 2048 MB — single OSM-only QC pack fits.
  memory: 2048,
  includeFiles: [
    "routing/lib/**",
    "routing/regional/**",
    "routing/schema/**",
    "routing/data/regions/ns/longhaul.v1.json.gz",
    "routing/data/regions/nb/longhaul.v1.json.gz",
    "routing/data/regions/qc/longhaul.v1.json.gz",
    "routing/data/regions/pe/longhaul.v1.json.gz"
  ]
};
