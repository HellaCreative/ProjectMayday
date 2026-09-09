"use strict";
const { adventureCanaryRequest } = require("./adventure/live-canary");

function parseRoutingBody(raw, signal) {
  let body;
  try { body = typeof raw === "string" ? JSON.parse(raw) : raw; }
  catch { throw Object.assign(new Error("Request body must be a JSON object."), { code: "invalid_request_body" }); }
  const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
  if (!object(body) || (body.options != null && !object(body.options)) ||
      (body.fuel != null && !object(body.fuel))) {
    throw Object.assign(new Error("Request body, options and fuel must be JSON objects."), { code: "invalid_request_body" });
  }
  return { ...body, options: { ...(body.options || {}), abortSignal: signal } };
}

// Only an explicit lack of coverage can enter the compatibility engine.
// Unknown, failed and cancelled searches never switch algorithms or retry there.
// Load compatibility code only when that request actually needs it.
async function dispatchRouting(body, kind, {
  adventure = adventureCanaryRequest,
  compatibility = (request, type) => type === "fuel"
    ? require("./fuel-chain").fuelChainRequest(request)
    : require("./router").routeRequest(request)
} = {}) {
  const cancelled = () => ({ status: "unknown", error: "request_cancelled",
    message: "Route request was cancelled.", routes: [], stops: [], windowComplete: false });
  if (body.options?.abortSignal?.aborted) return cancelled();
  const result = await adventure(body, kind);
  if (body.options?.abortSignal?.aborted) return cancelled();
  if (result !== null) return result;
  const legacyResult = await compatibility(body, kind);
  return body.options?.abortSignal?.aborted ? cancelled() : legacyResult;
}
module.exports = { parseRoutingBody, dispatchRouting };
