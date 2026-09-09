const { parseRoutingBody, dispatchRouting } = require("../routing/lib/dispatch");
/**
 * Thin Vercel handler for Phase 2B routing.
 * Loads the prebuilt offline graph once per warm isolate.
 */
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
    : `route-${Date.now().toString(36)}`;
  res.setHeader("X-Dirt-Request-ID", requestId);
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, X-Dirt-Request-ID");

  if (req.method === "OPTIONS") return res.status(200).end();

  if (req.method === "GET") {
    return res.status(200).json({
      ok: true,
      adventureCanary: process.env.DIRT_ADVENTURE_CANARY || null,
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

  const started = Date.now();
  const abortController = new AbortController();
  const abortRequest = () => abortController.abort();
  if (req.aborted) abortRequest();
  if (typeof req.once === "function") req.once("aborted", abortRequest);
  if (typeof res.once === "function") {
    res.once("close", () => {
      if (!res.writableEnded) abortRequest();
    });
  }
  try {
    const body = parseRoutingBody(req.body, abortController.signal);
    console.log(
      `route request begin id=${requestId} profile=${body.profile || "-"} ` +
      `locations=${Array.isArray(body.locations) ? body.locations.length : 0}`
    );
    const result = await dispatchRouting(body, "route");
    console.log(
      `route request end id=${requestId} status=${result.status || "-"} ` +
      `elapsedMs=${Date.now() - started}`
    );
    const code = result.status === "complete" ? 200 : (result.status === "error" ? 400 : 422);
    return res.status(code).json(withServiceIdentity(result));
  } catch (err) {
    if (err?.code === "invalid_request_body") {
      return res.status(400).json(withServiceIdentity({ status: "error", error: err.code, message: err.message }));
    }
    console.error(`route failed id=${requestId} elapsedMs=${Date.now() - started}`, err);
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
