"use strict";

const ROUTING_SERVICE_CONTRACT = "dirt-routing.r0.v1";

function serviceBuild(environment = process.env) {
  return environment.VERCEL_GIT_COMMIT_SHA ||
    environment.GIT_COMMIT_SHA ||
    environment.SOURCE_VERSION ||
    "local-uncommitted";
}

function withServiceIdentity(result, environment = process.env) {
  const payload = result && typeof result === "object" ? result : {};
  return {
    ...payload,
    serviceContract: ROUTING_SERVICE_CONTRACT,
    serviceBuild: serviceBuild(environment),
    connectionRevision: environment.DIRT_V4_CONNECTION_REVISION || null
  };
}

module.exports = {
  ROUTING_SERVICE_CONTRACT,
  serviceBuild,
  withServiceIdentity
};
