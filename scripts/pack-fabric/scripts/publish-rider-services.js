#!/usr/bin/env node
"use strict";

/** Publish immutable Rider Services objects, then atomically publish their catalog. */

const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const { OSM_REGION } = require("../routing/registry/geofabrik");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const LOCAL_ROOT = path.join(FABRIC, "app/data/rider-services/v1");
const PUBLIC_BASE = (
  process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev"
).replace(/\/$/, "");
const PUBLIC_PREFIX = "rider-services/v1";
const R2_PREFIX = `dirt-packs/${PUBLIC_PREFIX}`;

function sha256(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function localRows(regionIds) {
  return regionIds.map((id) => {
    const filePath = path.join(LOCAL_ROOT, id, "rider-services.v1.json");
    const buffer = fs.readFileSync(filePath);
    const pack = JSON.parse(buffer.toString("utf8"));
    if (
      pack.schema !== "rider-services.v1" || pack.regionId !== id ||
      !Array.isArray(pack.bounds) || pack.bounds.length !== 4 ||
      !Array.isArray(pack.elements) || !pack.elements.length
    ) throw new Error(`Invalid local Rider Services pack '${id}'`);
    const hash = sha256(buffer);
    return {
      id,
      bounds: pack.bounds,
      counts: pack.counts,
      sourceUpdatedAt: pack.sourceUpdatedAt || null,
      file: {
        name: `rider-services.v1.${hash.slice(0, 12)}.json`,
        bytes: buffer.length,
        sha256: hash
      },
      filePath
    };
  });
}

function buildManifest(rows, generatedAt) {
  const expected = Object.keys(OSM_REGION).sort();
  const ids = rows.map((row) => row.id).sort();
  if (JSON.stringify(ids) !== JSON.stringify(expected)) {
    throw new Error(`Rider Services publication requires all ${expected.length} registered regions`);
  }
  return {
    schema: "rider-services-manifest.v1",
    generatedAt,
    basePath: `/${PUBLIC_PREFIX}`,
    regions: rows.map(({ filePath, ...row }) => row).sort((a, b) => a.id.localeCompare(b.id))
  };
}

function request(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers: { "Cache-Control": "no-cache" } }, resolve);
    req.setTimeout(120_000, () => req.destroy(new Error(`Timeout: ${url}`)));
    req.on("error", reject);
  });
}

async function fetchOptional(url) {
  const response = await request(url);
  const chunks = [];
  for await (const chunk of response) chunks.push(chunk);
  if (response.statusCode === 404) return null;
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

async function verifyRow(row) {
  const url = `${PUBLIC_BASE}/${PUBLIC_PREFIX}/${row.id}/${row.file.name}?verify=${Date.now()}`;
  const buffer = await fetchOptional(url);
  if (!buffer || buffer.length !== row.file.bytes || sha256(buffer) !== row.file.sha256) {
    throw new Error(`Published Rider Services identity mismatch '${row.id}'`);
  }
}

async function main() {
  const apply = process.argv.slice(2).includes("--apply");
  const unknown = process.argv.slice(2).filter((arg) => arg !== "--apply");
  if (unknown.length) throw new Error(`Unknown argument: ${unknown[0]}`);
  const ids = Object.keys(OSM_REGION).sort();
  const rows = localRows(ids);
  const manifest = buildManifest(rows, new Date().toISOString());
  const bytes = rows.reduce((sum, row) => sum + row.file.bytes, 0);
  console.log(`Rider Services ready regions=${rows.length} bytes=${bytes} apply=${apply ? 1 : 0}`);
  if (!apply) {
    console.log("DRY RUN complete; no remote data changed");
    return;
  }

  const manifestURL = `${PUBLIC_BASE}/${PUBLIC_PREFIX}/manifest.json`;
  const before = await fetchOptional(`${manifestURL}?before=${Date.now()}`);
  for (const row of rows) {
    putObject(`${R2_PREFIX}/${row.id}/${row.file.name}`, row.filePath);
    await verifyRow(row);
    console.log(`verified ${row.id}/${row.file.name} ${row.file.bytes}`);
  }
  const latest = await fetchOptional(`${manifestURL}?latest=${Date.now()}`);
  if ((before && !latest) || (!before && latest) || (before && latest && sha256(before) !== sha256(latest))) {
    throw new Error("Rider Services catalog changed during object upload; refusing to overwrite it");
  }
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const temp = path.join(os.tmpdir(), `dirt-rider-services-${process.pid}.json`);
  fs.writeFileSync(temp, JSON.stringify(manifest, null, 2) + "\n");
  try {
    if (before) {
      const backup = path.join(os.tmpdir(), `dirt-rider-services-before-${process.pid}.json`);
      fs.writeFileSync(backup, before);
      try {
        putObject(`${R2_PREFIX}/catalog-backups/manifest-${stamp}-${sha256(before)}.json`, backup);
      } finally {
        fs.unlinkSync(backup);
      }
    }
    putObject(`${R2_PREFIX}/manifest.json`, temp);
  } finally {
    fs.unlinkSync(temp);
  }
  const expectedHash = sha256(Buffer.from(JSON.stringify(manifest, null, 2) + "\n"));
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const published = await fetchOptional(`${manifestURL}?published=${Date.now()}-${attempt}`);
    if (published && sha256(published) === expectedHash) {
      console.log(`Rider Services catalog published and verified ${expectedHash}`);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 500 * (attempt + 1)));
  }
  throw new Error("Rider Services catalog upload did not converge on the public endpoint");
}

if (require.main === module) {
  main().catch((error) => {
    console.error("RIDER SERVICES PUBLISH FAIL:", error && error.message || String(error));
    process.exit(1);
  });
}

module.exports = { buildManifest, localRows, sha256 };
