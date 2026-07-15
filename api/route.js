/**
 * Thin Vercel proxy / route handler for Phase 2B.
 * Loads the prebuilt offline graph once per warm isolate and searches it
 * server-side. The browser never builds the Nova Scotia graph.
 */
import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { routeRequest } = require("../routing/lib/router.js");

export const config = {
  maxDuration: 60,
  memory: 2048,
  includeFiles: ["routing/data/**", "routing/lib/**"]
};

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") return res.status(200).end();

  if (req.method === "GET") {
    return res.status(200).json({
      ok: true,
      service: "dirt-route",
      engine: "dirt-node-astar",
      note: "Valhalla deferred: custom NSTDB attributes + no persistent tile host in this deploy environment. One Node offline-graph engine served via this endpoint."
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
      message: err.message || "Routing failed"
    });
  }
}
