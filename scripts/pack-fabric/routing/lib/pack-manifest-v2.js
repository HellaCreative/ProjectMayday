"use strict";

const REQUIRED_CAPABILITY = "legal-topology.v1";

function validatePackManifestV2(manifest) {
  if (!manifest || manifest.schema !== "pack-manifest.v2") {
    throw new Error("unsupported pack manifest");
  }
  if (!Array.isArray(manifest.capabilities) || !manifest.capabilities.includes(REQUIRED_CAPABILITY)) {
    throw new Error("missing required capability legal-topology.v1");
  }
  for (const key of ["graph", "geometry", "fuel"]) {
    const file = manifest[key];
    if (!file || !file.name || !file.sha256 || !Number.isFinite(file.bytes)) {
      throw new Error("pack-manifest.v2 missing " + key + " identity");
    }
  }
  if (manifest.graph.name !== "graph.v4.bin") {
    throw new Error("pack-manifest.v2 graph must be graph.v4.bin");
  }
  if (!manifest.sourceEpoch) throw new Error("pack-manifest.v2 missing sourceEpoch");
  return true;
}

function buildPackManifestV2({ fabricReleaseId, regionId, graph, geometry, fuel, sourceEpoch, timezone }) {
  const manifest = {
    schema: "pack-manifest.v2",
    fabricReleaseId,
    regionId,
    capabilities: [REQUIRED_CAPABILITY],
    graph,
    geometry,
    fuel,
    sourceEpoch,
    timezone: timezone || "America/Halifax"
  };
  validatePackManifestV2(manifest);
  return manifest;
}

module.exports = {
  REQUIRED_CAPABILITY,
  validatePackManifestV2,
  buildPackManifestV2
};
