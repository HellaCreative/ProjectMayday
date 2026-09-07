#!/usr/bin/env node
"use strict";

/**
 * Upload one complete, locally sealed V4 fabric to an immutable DEV candidate
 * prefix. This script has no production or promotion path.
 *
 *   node scripts/pack-fabric/scripts/ship-v4-candidate.js \
 *     --candidate fabric-v4-20260907-01 --pack [--verify]
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const { OSM_REGION } = require("../routing/registry/geofabrik");
const { validatePackManifestV2 } = require("../routing/lib/pack-manifest-v2");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const PUBLIC_R2_BASE = process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";
const PHONE_FILES = ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "cross-pack-seams.v2.json"];
const AUDIT_FILES = ["pack-manifest.v2.json", "legal-topology-report.json"];

function die(message) {
  throw new Error(message);
}

function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  const fd = fs.openSync(filePath, "r");
  const buffer = Buffer.allocUnsafe(8 * 1024 * 1024);
  try {
    for (;;) {
      const count = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (!count) break;
      hash.update(buffer.subarray(0, count));
    }
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest("hex");
}

function identity(filePath) {
  return {
    name: path.basename(filePath),
    bytes: fs.statSync(filePath).size,
    sha256: sha256File(filePath)
  };
}

function parseArgs(argv) {
  const options = { candidate: null, pack: false, verify: false, root: null };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--promote" || value === "--live") {
      die(`${value} is forbidden here; candidate upload cannot touch production or deploy`);
    } else if (value === "--candidate") options.candidate = argv[++i];
    else if (value === "--root") options.root = path.resolve(argv[++i]);
    else if (value === "--pack") options.pack = true;
    else if (value === "--verify") options.verify = true;
    else die(`unknown argument ${value}`);
  }
  if (!options.candidate || !options.pack) {
    die("Usage: ship-v4-candidate.js --candidate fabric-v4-YYYYMMDD-NN --pack [--verify]");
  }
  if (!/^fabric-v4-[0-9]{8}-[0-9]{2}$/.test(options.candidate)) {
    die("V4 release id must be fabric-v4-YYYYMMDD-NN");
  }
  options.root = options.root || path.join(FABRIC, "routing", "candidates", options.candidate);
  return options;
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function verifyLocalCandidate(options) {
  const release = readJSON(path.join(options.root, "release.json"));
  const expectedIds = Object.keys(OSM_REGION).sort();
  const actualIds = (release.regions || []).map((row) => row.id).sort();
  if (release.releaseId !== options.candidate || release.status !== "local-candidate-sealed" ||
      !release.completeFabric || JSON.stringify(actualIds) !== JSON.stringify(expectedIds)) {
    die("candidate is not a sealed 63-region fabric");
  }
  if (!release.topology || !release.topology.sha256) die("candidate has no sealed topology index");

  const catalog = {
    version: options.candidate,
    fabricReleaseId: options.candidate,
    sourceEpoch: release.sourceEpoch,
    regions: []
  };
  const riderCatalog = {
    schema: "rider-services-manifest.v1",
    generatedAt: new Date().toISOString(),
    basePath: `/v4/candidates/${options.candidate}/rider-services`,
    regions: []
  };
  const uploads = [];
  for (const id of expectedIds) {
    const releaseRegion = release.regions.find((row) => row.id === id);
    const dir = path.join(options.root, "packs", id);
    const manifest = readJSON(path.join(dir, "pack-manifest.v2.json"));
    validatePackManifestV2(manifest, { requireSeams: true });
    if (manifest.fabricReleaseId !== options.candidate || manifest.sourceEpoch !== release.sourceEpoch || manifest.regionId !== id) {
      die(`${id}: local manifest identity does not match the sealed release`);
    }
    const manifestIdentityByName = Object.fromEntries(
      [manifest.graph, manifest.geometry, manifest.fuel, manifest.seams].map((file) => [file.name, file])
    );
    const phoneFiles = [];
    for (const name of [...PHONE_FILES, ...AUDIT_FILES]) {
      const filePath = path.join(dir, name);
      if (!fs.existsSync(filePath)) die(`${id}: missing ${name}`);
      const file = identity(filePath);
      const expected = manifestIdentityByName[name];
      if (expected && (expected.bytes !== file.bytes || expected.sha256 !== file.sha256)) {
        die(`${id}: ${name} differs from its manifest`);
      }
      uploads.push({ key: `v4/candidates/${options.candidate}/${id}/${name}`, filePath, identity: file });
      if (PHONE_FILES.includes(name)) phoneFiles.push(file);
    }
    catalog.regions.push({ id, files: phoneFiles });

    const riderPath = path.join(options.root, "rider-services", id, "rider-services.v1.json");
    const rider = readJSON(riderPath);
    if (!releaseRegion || rider.regionId !== id ||
        rider.sourceUpdatedAt !== releaseRegion.riderServices.sourceUpdatedAt) {
      die(`${id}: Rider Services identity mismatch`);
    }
    const riderIdentity = identity(riderPath);
    const riderFile = {
      ...riderIdentity,
      name: `rider-services.v1.${riderIdentity.sha256.slice(0, 12)}.json`
    };
    uploads.push({
      key: `v4/candidates/${options.candidate}/rider-services/${id}/${riderFile.name}`,
      filePath: riderPath,
      identity: riderFile
    });
    riderCatalog.regions.push({
      id,
      bounds: rider.bounds,
      counts: rider.counts,
      sourceUpdatedAt: rider.sourceUpdatedAt || null,
      file: riderFile
    });
  }

  for (const [name, document] of [
    ["manifest.json", catalog],
    ["rider-services/manifest.json", riderCatalog]
  ]) {
    const filePath = path.join(options.root, name);
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, JSON.stringify(document, null, 2) + "\n");
    uploads.push({ key: `v4/candidates/${options.candidate}/${name}`, filePath, identity: identity(filePath) });
  }
  for (const name of ["release.json", "source-lock.json", "cross-pack-topology.v2.json"]) {
    const filePath = path.join(options.root, name);
    if (!fs.existsSync(filePath)) die(`candidate missing ${name}`);
    uploads.push({ key: `v4/candidates/${options.candidate}/${name}`, filePath, identity: identity(filePath) });
  }
  return {
    release,
    uploads,
    publicBase: `${PUBLIC_R2_BASE.replace(/\/$/, "")}/v4/candidates/${options.candidate}`
  };
}

function putR2(item) {
  const size = item.identity.bytes / 1e6;
  console.log("PUT", item.key, size >= 1 ? `${Math.round(size)}MB` : `${Math.round(size * 1000)}KB`);
  const result = spawnSync(
    "npx",
    ["wrangler", "r2", "object", "put", `dirt-packs/${item.key}`, `--file=${item.filePath}`, "--remote"],
    { cwd: FABRIC, stdio: "inherit", env: process.env }
  );
  if (result.status !== 0) die(`R2 upload failed for ${item.key}`);
}

async function verifyRemote(item, publicBase) {
  const relative = item.key.replace(/^v4\/candidates\/[^/]+\//, "");
  const response = await fetch(`${publicBase}/${relative}?verify=${Date.now()}`, { cache: "no-store" });
  if (!response.ok || !response.body) die(`remote verification HTTP ${response.status} for ${item.key}`);
  const contentLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(contentLength) && contentLength !== item.identity.bytes) {
    die(`remote byte mismatch for ${item.key}`);
  }
  const hash = crypto.createHash("sha256");
  let bytes = 0;
  for await (const chunk of response.body) {
    bytes += chunk.length;
    hash.update(chunk);
  }
  if (bytes !== item.identity.bytes || hash.digest("hex") !== item.identity.sha256) {
    die(`remote identity mismatch for ${item.key}`);
  }
  console.log("VERIFIED", item.key);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const candidate = verifyLocalCandidate(options);
  for (const item of candidate.uploads) putR2(item);
  if (options.verify) {
    for (const item of candidate.uploads) await verifyRemote(item, candidate.publicBase);
  }
  console.log(JSON.stringify({
    releaseId: options.candidate,
    regionCount: candidate.release.regionCount,
    objectCount: candidate.uploads.length,
    publicBase: candidate.publicBase,
    productionUntouched: true,
    verified: options.verify
  }, null, 2));
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  });
}

module.exports = { parseArgs, verifyLocalCandidate, main };
