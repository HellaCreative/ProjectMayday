#!/usr/bin/env node
"use strict";

/**
 * Upload one NS V4 DEV candidate. Does not touch V1/V3 public keys, catalog,
 * or dirt-mayday. Does not promote.
 *
 *   node scripts/pack-fabric/scripts/ship-v4-candidate.js \
 *     --candidate ns-v4-legal-topology-20260906-02 --pack ns
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const PACKS_V4 = path.join(FABRIC, "app/data/packs/v4");
const RELEASES = path.join(FABRIC, "routing/data/releases");
const PUBLIC_R2_BASE = process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";
const V4_FILES = ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "pack-manifest.v2.json"];

function die(msg) {
  console.error(msg);
  process.exit(1);
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function parseArgs(argv) {
  let candidate = null;
  let pack = false;
  let live = false;
  const ids = [];
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--promote") die("V4 promote is forbidden until owner acceptance of NS");
    if (value === "--candidate") {
      candidate = argv[i + 1];
      i += 1;
      continue;
    }
    if (value === "--pack") {
      pack = true;
      continue;
    }
    if (value === "--live") {
      live = true;
      continue;
    }
    if (!value.startsWith("-")) ids.push(String(value).toLowerCase());
  }
  return { candidate, pack, live, ids };
}

function putR2(key, src) {
  if (!fs.existsSync(src)) die("missing " + src);
  const mb = fs.statSync(src).size / 1e6;
  console.log("PUT", key, mb >= 1 ? Math.round(mb) + "MB" : Math.round(mb * 1000) + "KB");
  const r = spawnSync("npx", ["wrangler", "r2", "object", "put", key, "--file=" + src, "--remote"], {
    cwd: FABRIC,
    encoding: "utf8",
    stdio: "inherit"
  });
  if (r.status !== 0) die("wrangler put failed for " + key);
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (!opts.candidate || !opts.pack) {
    die("Usage: ship-v4-candidate.js --candidate <id> --pack ns [--live]");
  }
  const ids = opts.ids.length ? opts.ids : ["ns"];
  if (ids.some((id) => id !== "ns")) die("V4 candidate upload is Nova Scotia only");
  const releaseId = opts.candidate;
  if (!/^ns-v4-legal-topology-[0-9]{8}-[0-9]{2}$/.test(releaseId)) {
    die("V4 release id must be ns-v4-legal-topology-YYYYMMDD-NN");
  }
  const files = [];
  for (const name of V4_FILES) {
    const src = path.join(PACKS_V4, "ns", name);
    if (name === "pack-manifest.v2.json" && !fs.existsSync(src)) continue;
    if (!fs.existsSync(src)) die("missing " + src);
    const stat = fs.statSync(src);
    files.push({ name, bytes: stat.size, sha256: sha256File(src) });
  }
  const record = {
    schemaVersion: "dirt-pack-release.v4",
    releaseId,
    status: "dev-candidate",
    namespace: "dirt-packs/v4/candidates",
    createdAt: new Date().toISOString(),
    publicBase: PUBLIC_R2_BASE.replace(/\/$/, "") + "/v4/candidates/" + releaseId,
    productionUntouched: true,
    publicV3CatalogUntouched: true,
    regions: [{ id: "ns", files }]
  };
  fs.mkdirSync(RELEASES, { recursive: true });
  const recordPath = path.join(RELEASES, releaseId + ".json");
  fs.writeFileSync(recordPath, JSON.stringify(record, null, 2) + "\n");
  const prefix = "v4/candidates/" + releaseId;
  for (const file of files) {
    putR2("dirt-packs/" + prefix + "/ns/" + file.name, path.join(PACKS_V4, "ns", file.name));
  }
  putR2("dirt-packs/" + prefix + "/release.json", recordPath);
  console.log("V4 DEV candidate uploaded; public V1/V3 catalog untouched", record.publicBase);
  if (opts.live) {
    const ship = path.join(__dirname, "ship-routing.js");
    const overrides = JSON.stringify({ ns: record.publicBase });
    const git = spawnSync("git", ["rev-parse", "HEAD"], { cwd: DIRT, encoding: "utf8" });
    const sourceVersion = git.status === 0 ? String(git.stdout || "").trim() : "";
    const r = spawnSync(
      "npx",
      [
        "vercel",
        "--prod",
        "--yes",
        "--env",
        "SOURCE_VERSION=" + sourceVersion,
        "--env",
        "R2_REGION_BASE_OVERRIDES=" + overrides,
        "--env",
        "DIRT_V4_REGIONS=ns"
      ],
      { cwd: FABRIC, encoding: "utf8", stdio: "inherit" }
    );
    if (r.status !== 0) die("DEV pack-fabric deploy failed");
    console.log("pointed pack-fabric DEV at", record.publicBase);
  }
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = { main };
