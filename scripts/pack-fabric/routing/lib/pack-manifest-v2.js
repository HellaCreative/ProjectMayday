"use strict";

const REQUIRED_CAPABILITY = "legal-topology.v1";
const SEAM_CAPABILITY = "cross-pack-seams.v2";
const FILE_NAMES = {
  graph: "graph.v4.bin",
  geometry: "geometry.v1.bin",
  fuel: "fuel.v1.json",
  seams: "cross-pack-seams.v2.json"
};
const SHA256 = /^[0-9a-f]{64}$/;

function validatePackManifestV2(manifest, { requireSeams = false } = {}) {
  if (!manifest || manifest.schema !== "pack-manifest.v2") {
    throw new Error("unsupported pack manifest");
  }
  if (!Array.isArray(manifest.capabilities) || !manifest.capabilities.includes(REQUIRED_CAPABILITY)) {
    throw new Error("missing required capability legal-topology.v1");
  }
  if (requireSeams && !manifest.seams) {
    throw new Error("pack-manifest.v2 missing seams identity");
  }
  const artifactKeys = ["graph", "geometry", "fuel"];
  if (requireSeams || manifest.seams) artifactKeys.push("seams");
  for (const key of artifactKeys) {
    const file = manifest[key];
    if (!file || file.name !== FILE_NAMES[key]) {
      throw new Error(`pack-manifest.v2 ${key} filename must be ${FILE_NAMES[key]}`);
    }
    if (!Number.isSafeInteger(file.bytes) || file.bytes <= 0) {
      throw new Error("pack-manifest.v2 " + key + " bytes must be positive");
    }
    if (!SHA256.test(String(file.sha256 || "")) || /^0+$/.test(file.sha256)) {
      throw new Error("pack-manifest.v2 missing " + key + " identity");
    }
  }
  if (manifest.seams && !manifest.capabilities.includes(SEAM_CAPABILITY)) {
    throw new Error("pack-manifest.v2 seams require cross-pack-seams.v2 capability");
  }
  if (!String(manifest.fabricReleaseId || "").trim()) {
    throw new Error("pack-manifest.v2 missing fabricReleaseId");
  }
  // Province/state ids are two letters; subregions append -<token> (on-s, on-n).
  if (!/^[a-z]{2}(-[a-z0-9]+)?$/.test(String(manifest.regionId || ""))) {
    throw new Error("pack-manifest.v2 invalid regionId");
  }
  if (!String(manifest.sourceEpoch || "").trim()) throw new Error("pack-manifest.v2 missing sourceEpoch");
  if (!String(manifest.timezone || "").includes("/")) throw new Error("pack-manifest.v2 missing timezone");
  return true;
}

function buildPackManifestV2({ fabricReleaseId, regionId, graph, geometry, fuel, seams = null, sourceEpoch, timezone }) {
  const manifest = {
    schema: "pack-manifest.v2",
    fabricReleaseId,
    regionId,
    capabilities: seams ? [REQUIRED_CAPABILITY, SEAM_CAPABILITY] : [REQUIRED_CAPABILITY],
    graph,
    geometry,
    fuel,
    sourceEpoch,
    timezone
  };
  if (seams) manifest.seams = seams;
  validatePackManifestV2(manifest, { requireSeams: Boolean(seams) });
  return manifest;
}

module.exports = {
  REQUIRED_CAPABILITY,
  SEAM_CAPABILITY,
  validatePackManifestV2,
  buildPackManifestV2
};
