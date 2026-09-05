#!/usr/bin/env node
"use strict";

/**
 * Repair catalog rows to the exact graph/geometry/fuel bytes already present
 * at their stable R2 keys. This tool never uploads pack data and never replaces
 * an unrelated region row.
 *
 * Dry run (default):
 *   node scripts/pack-fabric/scripts/repair-pack-catalog.js
 * Apply after review:
 *   node scripts/pack-fabric/scripts/repair-pack-catalog.js --apply
 */

const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const SEED_MANIFEST = path.join(FABRIC, "app/data/packs/v1/manifest.json");
const PUBLIC_R2_BASE = (
  process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev"
).replace(/\/$/, "");
const DEFAULT_REGIONS = ["id", "mi", "mn", "mt", "nd", "nh", "ny", "vt", "wa"];

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function assertCatalog(catalog, label) {
  if (!catalog || !Array.isArray(catalog.regions)) {
    throw new Error(`${label} catalog has no regions array`);
  }
  const ids = catalog.regions.map((region) => String(region.id || "").toLowerCase());
  if (ids.some((id) => !id)) throw new Error(`${label} catalog has an empty region id`);
  if (new Set(ids).size !== ids.length) throw new Error(`${label} catalog has duplicate region ids`);
}

function parseRegions(value) {
  const ids = String(value || "")
    .split(",")
    .map((id) => id.trim().toLowerCase())
    .filter(Boolean);
  if (!ids.length || ids.some((id) => !/^[a-z]{2}$/.test(id))) {
    throw new Error("--regions requires comma-separated two-letter region ids");
  }
  return [...new Set(ids)];
}

function parseArgs(argv) {
  let apply = false;
  let regions = DEFAULT_REGIONS;
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--apply") apply = true;
    else if (value === "--regions") regions = parseRegions(argv[++index]);
    else if (value === "--help" || value === "-h") return { help: true, apply, regions };
    else throw new Error(`Unknown argument: ${value}`);
  }
  return { help: false, apply, regions };
}

function regionMap(catalog) {
  return new Map(catalog.regions.map((region) => [String(region.id).toLowerCase(), region]));
}

function normalizedFile(file) {
  const value = {
    name: String(file && file.name || ""),
    bytes: Number(file && file.bytes),
    sha256: String(file && file.sha256 || "").toLowerCase()
  };
  if (!value.name || !Number.isSafeInteger(value.bytes) || value.bytes <= 0) {
    throw new Error(`Invalid file identity for ${value.name || "unnamed file"}`);
  }
  if (!/^[a-f0-9]{64}$/.test(value.sha256)) {
    throw new Error(`Invalid SHA-256 for ${value.name}`);
  }
  return value;
}

function repairCatalogRows(remote, seed, regionIds, generatedAt) {
  assertCatalog(remote, "remote");
  assertCatalog(seed, "seed");
  const seedById = regionMap(seed);
  const targets = new Set(regionIds);
  const seen = new Set();
  const regions = remote.regions.map((region) => {
    const id = String(region.id).toLowerCase();
    if (!targets.has(id)) return region;
    const source = seedById.get(id);
    if (!source) throw new Error(`Seed catalog has no region '${id}'`);
    const files = (source.files || []).map(normalizedFile);
    if (!files.some((file) => /^graph\.v[23]\.bin$/.test(file.name))) {
      throw new Error(`Seed region '${id}' has no graph`);
    }
    if (!files.some((file) => file.name === "geometry.v1.bin")) {
      throw new Error(`Seed region '${id}' has no geometry`);
    }
    seen.add(id);
    return { ...region, id, files };
  });
  const missing = regionIds.filter((id) => !seen.has(id));
  if (missing.length) throw new Error(`Remote catalog has no target regions: ${missing.join(",")}`);
  return { ...remote, generatedAt, regions };
}

function assertOnlyTargetRowsChanged(before, after, regionIds) {
  assertCatalog(before, "before");
  assertCatalog(after, "after");
  if (before.regions.length !== after.regions.length) {
    throw new Error("Catalog repair changed the region count");
  }
  const targets = new Set(regionIds);
  const afterById = regionMap(after);
  for (const region of before.regions) {
    if (targets.has(region.id)) continue;
    if (JSON.stringify(region) !== JSON.stringify(afterById.get(region.id))) {
      throw new Error(`Catalog repair changed unrelated region '${region.id}'`);
    }
  }
}

function request(url, { method = "GET" } = {}) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, { method, headers: { "Cache-Control": "no-cache" } }, resolve);
    req.setTimeout(120_000, () => req.destroy(new Error(`Timeout: ${url}`)));
    req.on("error", reject);
    req.end();
  });
}

async function responseText(response, url) {
  const chunks = [];
  for await (const chunk of response) chunks.push(chunk);
  if (response.statusCode !== 200) throw new Error(`HTTP ${response.statusCode} ${url}`);
  return Buffer.concat(chunks).toString("utf8");
}

async function fetchCatalogText() {
  const url = `${PUBLIC_R2_BASE}/manifest.json?audit=${Date.now()}`;
  return responseText(await request(url), url);
}

async function remoteIdentity(regionId, fileName) {
  const url = `${PUBLIC_R2_BASE}/${regionId}/${fileName}?audit=${Date.now()}`;
  const response = await request(url);
  if (response.statusCode !== 200) {
    response.resume();
    throw new Error(`HTTP ${response.statusCode} ${regionId}/${fileName}`);
  }
  const hash = crypto.createHash("sha256");
  let bytes = 0;
  for await (const chunk of response) {
    bytes += chunk.length;
    hash.update(chunk);
  }
  return { name: fileName, bytes, sha256: hash.digest("hex") };
}

async function verifyStableObjects(catalog, regionIds, concurrency = 3) {
  const byId = regionMap(catalog);
  const jobs = regionIds.flatMap((id) => {
    const region = byId.get(id);
    if (!region) throw new Error(`Catalog has no region '${id}'`);
    return (region.files || []).map((file) => ({ id, expected: normalizedFile(file) }));
  });
  let cursor = 0;
  async function worker() {
    while (cursor < jobs.length) {
      const job = jobs[cursor++];
      const actual = await remoteIdentity(job.id, job.expected.name);
      if (
        actual.bytes !== job.expected.bytes ||
        actual.sha256 !== job.expected.sha256
      ) {
        throw new Error(
          `${job.id}/${job.expected.name} does not match seed: ` +
          `R2 ${actual.bytes}/${actual.sha256}, seed ${job.expected.bytes}/${job.expected.sha256}`
        );
      }
      console.log(`verified ${job.id}/${job.expected.name} ${actual.bytes} ${actual.sha256}`);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, jobs.length) }, worker));
}

function runWranglerPut(key, file) {
  const result = spawnSync(
    "npx",
    ["wrangler", "r2", "object", "put", key, `--file=${file}`, "--remote"],
    { cwd: FABRIC, encoding: "utf8" }
  );
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) throw new Error(`Failed to upload ${key}`);
}

async function publishCatalog(originalText, repaired) {
  const latestText = await fetchCatalogText();
  if (sha256(latestText) !== sha256(originalText)) {
    throw new Error("Public catalog changed during verification; refusing to overwrite it");
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const originalHash = sha256(originalText);
  const repairedText = JSON.stringify(repaired, null, 2) + "\n";
  const repairedHash = sha256(repairedText);
  const originalFile = path.join(os.tmpdir(), `dirt-manifest-before-${process.pid}.json`);
  const repairedFile = path.join(os.tmpdir(), `dirt-manifest-repaired-${process.pid}.json`);
  fs.writeFileSync(originalFile, originalText);
  fs.writeFileSync(repairedFile, repairedText);
  try {
    runWranglerPut(`dirt-packs/catalog-backups/manifest-${stamp}-${originalHash}.json`, originalFile);
    runWranglerPut("dirt-packs/manifest.json", repairedFile);
  } finally {
    try { fs.unlinkSync(originalFile); } catch (_) {}
    try { fs.unlinkSync(repairedFile); } catch (_) {}
  }
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const published = await fetchCatalogText();
    if (sha256(published) === repairedHash) return repairedHash;
    await new Promise((resolve) => setTimeout(resolve, 500 * (attempt + 1)));
  }
  throw new Error("Repaired catalog was uploaded but public verification did not converge");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log("Usage: repair-pack-catalog.js [--regions id,mi,...] [--apply]");
    return;
  }
  const originalText = await fetchCatalogText();
  const remote = JSON.parse(originalText);
  const seed = JSON.parse(fs.readFileSync(SEED_MANIFEST, "utf8"));
  const generatedAt = new Date().toISOString();
  const repaired = repairCatalogRows(remote, seed, options.regions, generatedAt);
  assertOnlyTargetRowsChanged(remote, repaired, options.regions);
  console.log(`catalog sha256 before ${sha256(originalText)}`);
  console.log(`repair rows ${options.regions.join(",")}`);
  await verifyStableObjects(repaired, options.regions);
  if (!options.apply) {
    console.log("DRY RUN complete; no remote data changed");
    return;
  }
  const publishedHash = await publishCatalog(originalText, repaired);
  console.log(`catalog repair published and verified ${publishedHash}`);
}

if (require.main === module) {
  main().catch((error) => {
    console.error("CATALOG REPAIR FAIL:", error && error.message ? error.message : String(error));
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_REGIONS,
  assertOnlyTargetRowsChanged,
  parseArgs,
  repairCatalogRows
};
