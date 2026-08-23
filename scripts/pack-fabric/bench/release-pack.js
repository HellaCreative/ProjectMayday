"use strict";

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

function regionRecord(release, regionId) {
  if (!release || release.schemaVersion !== "dirt-pack-release.v1") {
    throw new Error("Immutable release record has an unsupported schema");
  }
  if (!release.releaseId || !release.publicBase) {
    throw new Error("Immutable release record is missing releaseId or publicBase");
  }
  const region = (release.regions || []).find((row) => row.id === regionId);
  if (!region) throw new Error(`Release ${release.releaseId} has no ${regionId} region`);
  return region;
}

function fileRecord(release, regionId, fileName) {
  const region = regionRecord(release, regionId);
  const record = (region.files || []).find((row) => row.name === fileName);
  if (!record || !Number.isInteger(record.bytes) || !/^[a-f0-9]{64}$/.test(record.sha256 || "")) {
    throw new Error(`Release ${release.releaseId} has invalid identity for ${regionId}/${fileName}`);
  }
  return record;
}

function verifyReleaseBytes(buffer, record, label) {
  if (!Buffer.isBuffer(buffer)) throw new Error(`${label} did not produce binary bytes`);
  if (buffer.length !== record.bytes) {
    throw new Error(`${label} byte mismatch: expected ${record.bytes}, received ${buffer.length}`);
  }
  const sha256 = crypto.createHash("sha256").update(buffer).digest("hex");
  if (sha256 !== record.sha256) {
    throw new Error(`${label} SHA-256 mismatch: expected ${record.sha256}, received ${sha256}`);
  }
  return sha256;
}

async function download(fetchImpl, url) {
  if (typeof fetchImpl !== "function") throw new Error("No fetch implementation is available");
  const response = await fetchImpl(url);
  if (!response || !response.ok) {
    throw new Error(`Immutable release download failed (${response ? response.status : "no response"}) for ${url}`);
  }
  return Buffer.from(await response.arrayBuffer());
}

async function materializeVerifiedRelease({
  release,
  regionId,
  fileNames,
  fetchImpl = globalThis.fetch,
  cacheRoot = path.join(os.tmpdir(), "dirt-routing-bench")
}) {
  regionRecord(release, regionId);
  const releaseRoot = path.join(cacheRoot, release.releaseId, regionId);
  fs.mkdirSync(releaseRoot, { recursive: true });
  const files = {};

  for (const fileName of fileNames) {
    const record = fileRecord(release, regionId, fileName);
    // Keep canonical neighbouring filenames because graph.v2 decoding resolves
    // geometry.v1.bin beside the graph. The releaseId directory plus strict
    // verification provides the immutable cache identity.
    const target = path.join(releaseRoot, fileName);
    let bytes = null;
    if (fs.existsSync(target)) {
      const cached = fs.readFileSync(target);
      try {
        verifyReleaseBytes(cached, record, `Cached ${regionId}/${fileName}`);
        bytes = cached;
      } catch (_) {
        // A corrupt cache is never accepted as the requested release. Fetch the
        // immutable object again and verify it before replacing the cache.
      }
    }
    if (!bytes) {
      const url = `${String(release.publicBase).replace(/\/$/, "")}/${regionId}/${fileName}`;
      bytes = await download(fetchImpl, url);
      verifyReleaseBytes(bytes, record, `${release.releaseId}/${regionId}/${fileName}`);
      fs.writeFileSync(target, bytes);
    }
    files[fileName] = {
      path: target,
      bytes: record.bytes,
      sha256: record.sha256
    };
  }

  return {
    releaseId: release.releaseId,
    publicBase: release.publicBase,
    regionId,
    files
  };
}

module.exports = {
  fileRecord,
  materializeVerifiedRelease,
  regionRecord,
  verifyReleaseBytes
};
