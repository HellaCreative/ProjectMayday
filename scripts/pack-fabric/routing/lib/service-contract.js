"use strict";

const ROUTING_SERVICE_CONTRACT = "dirt-routing.r0.v1";

function serviceBuild(environment = process.env) {
  // An explicit deployment identity describes the exact qualified worktree.
  // Vercel's automatic Git SHA can only identify the checked-out base commit
  // when a private preview is deployed from deliberate, uncommitted changes.
  return environment.SOURCE_VERSION ||
    environment.VERCEL_GIT_COMMIT_SHA ||
    environment.GIT_COMMIT_SHA ||
    "local-uncommitted";
}

function withServiceIdentity(result, environment = process.env) {
  const payload = result && typeof result === "object" ? result : {};
  return {
    ...payload,
    serviceContract: ROUTING_SERVICE_CONTRACT,
    serviceBuild: serviceBuild(environment)
  };
}

module.exports = {
  ROUTING_SERVICE_CONTRACT,
  serviceBuild,
  withServiceIdentity
};
