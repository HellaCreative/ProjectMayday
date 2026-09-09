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
const { spawn, spawnSync } = require("child_process");
const net = require("net");
const { OSM_REGION } = require("../routing/registry/geofabrik");
const { validatePackManifestV2 } = require("../routing/lib/pack-manifest-v2");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const PUBLIC_R2_BASE = process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";
const PHONE_FILES = ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "cross-pack-seams.v2.json"];
const AUDIT_FILES = ["pack-manifest.v2.json", "legal-topology-report.json"];
// Wrangler accepts larger single requests, but Cloudflare's API gateway can time
// them out before completion on slower links. Multipart keeps every request well
// below that timeout while retaining an exact final-object checksum gate.
const RELIABLE_DIRECT_UPLOAD_LIMIT = 96 * 1024 * 1024;
const MULTIPART_PART_BYTES = 32 * 1024 * 1024;
const MULTIPART_CONFIG = path.join(FABRIC, "wrangler.multipart-upload.toml");

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
    else if (value === "--regions") {
      options.regions = [...new Set((argv[++i] || "").split(","))].sort();
      if (options.regions.length < 2 || options.regions.some(id => !OSM_REGION[id])) {
        die("--regions requires at least two recognized region IDs");
      }
    }
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
  const expectedIds = options.regions || Object.keys(OSM_REGION).sort();
  const actualIds = (release.regions || []).map((row) => row.id).sort();
  const expectedStatus = options.regions ? "local-partial-candidate" : "local-candidate-sealed";
  if (release.releaseId !== options.candidate || release.status !== expectedStatus ||
      (!options.regions && !release.completeFabric) || JSON.stringify(actualIds) !== JSON.stringify(expectedIds)) {
    die("candidate does not match the explicitly selected sealed region set");
  }
  if (!release.topology || !release.topology.sha256) die("candidate has no sealed topology index");
  const topologyFile = path.join(options.root, "cross-pack-topology.v2.json");
  const topologyIdentity = identity(topologyFile);
  const topology = readJSON(topologyFile);
  if (topologyIdentity.sha256 !== release.topology.sha256 || topologyIdentity.bytes !== release.topology.bytes ||
      topology.fabricReleaseId !== release.releaseId || topology.sourceEpoch !== release.sourceEpoch ||
      JSON.stringify(Object.keys(topology.regions).sort()) !== JSON.stringify(expectedIds)) {
    die("candidate topology identity or selected regions mismatch");
  }

  const catalog = {
    version: options.candidate,
    fabricReleaseId: options.candidate,
    sourceEpoch: release.sourceEpoch,
    regions: []
  };
  const riderCatalog = {
    schema: "rider-services-manifest.v1",
    generatedAt: release.createdAt,
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

async function putR2(item) {
  const size = item.identity.bytes / 1e6;
  console.log("PUT", item.key, size >= 1 ? `${Math.round(size)}MB` : `${Math.round(size * 1000)}KB`);
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    const result = spawnSync(
      "npx",
      ["wrangler", "r2", "object", "put", `dirt-packs/${item.key}`, `--file=${item.filePath}`, "--remote"],
      { cwd: FABRIC, stdio: "inherit", env: process.env }
    );
    if (result.status === 0) return;
    if (attempt < 4) {
      console.warn("RETRY", item.key, `${attempt}/3`);
      await delay(attempt * 1000);
    }
  }
  die(`R2 upload failed for ${item.key} after four attempts`);
}

function needsMultipart(item) {
  return item.identity.bytes > RELIABLE_DIRECT_UPLOAD_LIMIT;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function findFreePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => error ? reject(error) : resolve(address.port));
    });
  });
}

async function requestOK(url, options, attempts = 4) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetch(url, options);
      if (response.ok) return response;
      lastError = new Error(`HTTP ${response.status}: ${await response.text()}`);
    } catch (error) {
      lastError = error;
    }
    if (attempt < attempts) await delay(500 * attempt);
  }
  throw lastError;
}

class MultipartUploader {
  constructor() {
    this.child = null;
    this.endpoint = null;
    this.output = "";
  }

  async start() {
    if (this.child) return;
    const port = await findFreePort();
    this.endpoint = `http://127.0.0.1:${port}`;
    this.child = spawn("npx", [
      "wrangler", "dev", "--config", MULTIPART_CONFIG,
      "--ip", "127.0.0.1", "--port", String(port),
      "--show-interactive-dev-session=false", "--log-level=warn"
    ], { cwd: FABRIC, env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    const collect = (chunk) => {
      this.output = (this.output + chunk.toString()).slice(-12_000);
    };
    this.child.stdout.on("data", collect);
    this.child.stderr.on("data", collect);

    for (let attempt = 0; attempt < 120; attempt += 1) {
      if (this.child.exitCode !== null) {
        die(`multipart upload bridge exited early\n${this.output}`);
      }
      try {
        const response = await fetch(`${this.endpoint}/__health`);
        if (response.ok) return;
      } catch (_) {
        // Wrangler is still starting.
      }
      await delay(500);
    }
    die(`multipart upload bridge did not start\n${this.output}`);
  }

  url(item, action, extra = {}) {
    const url = new URL(`${this.endpoint}/${item.key}`);
    url.searchParams.set("action", action);
    for (const [key, value] of Object.entries(extra)) url.searchParams.set(key, String(value));
    return url;
  }

  async put(item) {
    await this.start();
    const created = await requestOK(this.url(item, "create"), { method: "POST" });
    const { uploadId } = await created.json();
    const parts = [];
    const handle = fs.openSync(item.filePath, "r");
    try {
      const partCount = Math.ceil(item.identity.bytes / MULTIPART_PART_BYTES);
      for (let index = 0; index < partCount; index += 1) {
        const offset = index * MULTIPART_PART_BYTES;
        const length = Math.min(MULTIPART_PART_BYTES, item.identity.bytes - offset);
        const body = Buffer.allocUnsafe(length);
        const bytesRead = fs.readSync(handle, body, 0, length, offset);
        if (bytesRead !== length) die(`${item.key}: short read at multipart part ${index + 1}`);
        const response = await requestOK(this.url(item, "part", {
          uploadId,
          partNumber: index + 1
        }), { method: "PUT", body });
        parts.push(await response.json());
        console.log("PART", item.key, `${index + 1}/${partCount}`);
      }
      await requestOK(this.url(item, "complete", { uploadId }), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ parts })
      });
    } catch (error) {
      try {
        await fetch(this.url(item, "abort", { uploadId }), { method: "DELETE" });
      } catch (_) {
        // R2 also removes abandoned multipart uploads automatically.
      }
      throw error;
    } finally {
      fs.closeSync(handle);
    }
  }

  stop() {
    if (this.child && this.child.exitCode === null) this.child.kill("SIGTERM");
    this.child = null;
  }
}

async function verifyRemote(item, publicBase, options = {}) {
  const relative = item.key.replace(/^v4\/candidates\/[^/]+\//, "");
  const attempts = options.attempts || 6;
  const retryBaseMilliseconds = options.retryBaseMilliseconds ?? 1000;
  const fetchFn = options.fetchFn || fetch;
  let lastError;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetchFn(`${publicBase}/${relative}?verify=${Date.now()}`, { cache: "no-store" });
      if ((response.status === 404 || response.status === 410) && options.allowMissing) return false;
      if (!response.ok || !response.body) {
        throw new Error(`remote verification HTTP ${response.status} for ${item.key}`);
      }
      const contentLength = Number(response.headers.get("content-length"));
      if (Number.isFinite(contentLength) && contentLength !== item.identity.bytes) {
        throw new Error(`remote byte mismatch for ${item.key}`);
      }
      const hash = crypto.createHash("sha256");
      let bytes = 0;
      for await (const chunk of response.body) {
        bytes += chunk.length;
        hash.update(chunk);
      }
      if (bytes !== item.identity.bytes || hash.digest("hex") !== item.identity.sha256) {
        throw new Error(`remote identity mismatch for ${item.key}`);
      }
      if (!options.quiet) console.log("VERIFIED", item.key);
      return true;
    } catch (error) {
      lastError = error;
      if (attempt < attempts) {
        console.warn("VERIFY RETRY", item.key, `${attempt}/${attempts - 1}`);
        await delay(retryBaseMilliseconds * attempt);
      }
    }
  }
  throw lastError;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const candidate = verifyLocalCandidate(options);
  const multipart = new MultipartUploader();
  try {
    for (const item of candidate.uploads) {
      if (options.verify && await verifyRemote(item, candidate.publicBase, { allowMissing: true, quiet: true })) {
        console.log("REUSED VERIFIED", item.key);
        continue;
      }
      if (needsMultipart(item)) {
        const size = Math.round(item.identity.bytes / 1e6);
        console.log("MULTIPART PUT", item.key, `${size}MB`);
        await multipart.put(item);
      } else {
        await putR2(item);
      }
      if (options.verify) await verifyRemote(item, candidate.publicBase);
    }
  } finally {
    multipart.stop();
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

module.exports = { parseArgs, verifyLocalCandidate, needsMultipart, verifyRemote, main };
