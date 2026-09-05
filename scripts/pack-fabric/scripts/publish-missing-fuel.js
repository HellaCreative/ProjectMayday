#!/usr/bin/env node
"use strict";

/** Upload only missing fuel.v1 sidecars and merge them into the live catalog. */

const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const FUEL_ROOT = path.join(FABRIC, "app/data/packs/v1");
const PUBLIC_BASE = (
  process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev"
).replace(/\/$/, "");

function sha256(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function appendFuel(catalog, additions, generatedAt) {
  const targets = new Map(additions.map((item) => [item.id, item.file]));
  const seen = new Set();
  const regions = catalog.regions.map((region) => {
    const file = targets.get(region.id);
    if (!file) return region;
    if ((region.files || []).some((item) => item.name === "fuel.v1.json")) {
      throw new Error(`Region '${region.id}' already advertises fuel; refusing to replace it`);
    }
    seen.add(region.id);
    return { ...region, files: [...region.files, file] };
  });
  const missing = [...targets.keys()].filter((id) => !seen.has(id));
  if (missing.length) throw new Error(`Catalog has no fuel targets: ${missing.join(",")}`);
  return { ...catalog, generatedAt, regions };
}

function request(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers: { "Cache-Control": "no-cache" } }, resolve);
    req.setTimeout(120_000, () => req.destroy(new Error(`Timeout: ${url}`)));
    req.on("error", reject);
  });
}

async function fetchBuffer(url) {
  const response = await request(url);
  const chunks = [];
  for await (const chunk of response) chunks.push(chunk);
  if (response.statusCode !== 200) throw new Error(`HTTP ${response.statusCode} ${url}`);
  return Buffer.concat(chunks);
}

function putObject(key, filePath) {
  const result = spawnSync(
    "npx", ["wrangler", "r2", "object", "put", key, `--file=${filePath}`, "--remote"],
    { cwd: FABRIC, encoding: "utf8" }
  );
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) throw new Error(`Failed to upload ${key}`);
}

function localAddition(id) {
  const filePath = path.join(FUEL_ROOT, id, "fuel.v1.json");
  const buffer = fs.readFileSync(filePath);
  const payload = JSON.parse(buffer.toString("utf8"));
  if (
    payload.schema !== "fuel.v1" || payload.regionId !== id ||
    !Array.isArray(payload.stations) || !payload.stations.length
  ) {
    throw new Error(`Invalid local fuel sidecar '${id}'`);
  }
  return {
    id,
    filePath,
    file: { name: "fuel.v1.json", bytes: buffer.length, sha256: sha256(buffer) }
  };
}

async function main() {
  const apply = process.argv.slice(2).includes("--apply");
  const unknown = process.argv.slice(2).filter((arg) => arg !== "--apply");
  if (unknown.length) throw new Error(`Unknown argument: ${unknown[0]}`);
  const before = await fetchBuffer(`${PUBLIC_BASE}/manifest.json?before=${Date.now()}`);
  const catalog = JSON.parse(before.toString("utf8"));
  const ids = catalog.regions
    .filter((region) => !(region.files || []).some((file) => file.name === "fuel.v1.json"))
    .map((region) => region.id)
    .sort();
  const additions = ids.map(localAddition);
  const next = appendFuel(catalog, additions, new Date().toISOString());
  console.log(`missing fuel ready regions=${ids.length} stations=${additions.reduce((sum, item) => {
    return sum + JSON.parse(fs.readFileSync(item.filePath, "utf8")).stations.length;
  }, 0)} apply=${apply ? 1 : 0}`);
  if (!apply) {
    console.log("DRY RUN complete; no remote data changed");
    return;
  }
  for (const item of additions) {
    putObject(`dirt-packs/${item.id}/fuel.v1.json`, item.filePath);
    const remote = await fetchBuffer(`${PUBLIC_BASE}/${item.id}/fuel.v1.json?verify=${Date.now()}`);
    if (remote.length !== item.file.bytes || sha256(remote) !== item.file.sha256) {
      throw new Error(`Published fuel identity mismatch '${item.id}'`);
    }
    console.log(`verified ${item.id}/fuel.v1.json ${item.file.bytes}`);
  }
  const latest = await fetchBuffer(`${PUBLIC_BASE}/manifest.json?latest=${Date.now()}`);
  if (sha256(latest) !== sha256(before)) {
    throw new Error("Public pack catalog changed during fuel upload; refusing to overwrite it");
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const backup = path.join(os.tmpdir(), `dirt-pack-manifest-before-fuel-${process.pid}.json`);
  const output = path.join(os.tmpdir(), `dirt-pack-manifest-with-fuel-${process.pid}.json`);
  const outputBytes = Buffer.from(JSON.stringify(next, null, 2) + "\n");
  fs.writeFileSync(backup, before);
  fs.writeFileSync(output, outputBytes);
  try {
    putObject(`dirt-packs/catalog-backups/manifest-${stamp}-${sha256(before)}.json`, backup);
    putObject("dirt-packs/manifest.json", output);
  } finally {
    fs.unlinkSync(backup);
    fs.unlinkSync(output);
  }
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const published = await fetchBuffer(`${PUBLIC_BASE}/manifest.json?published=${Date.now()}-${attempt}`);
    if (sha256(published) === sha256(outputBytes)) {
      console.log(`fuel catalog published and verified ${sha256(outputBytes)}`);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 500 * (attempt + 1)));
  }
  throw new Error("Fuel catalog upload did not converge on the public endpoint");
}

if (require.main === module) {
  main().catch((error) => {
    console.error("FUEL PUBLISH FAIL:", error && error.message || String(error));
    process.exit(1);
  });
}

module.exports = { appendFuel, localAddition, sha256 };
