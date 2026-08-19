#!/usr/bin/env node
"use strict";

/**
 * Publish graph.v2 packs to R2. This is the routing source of truth for
 * BOTH the iOS PACKS download and live `/api/route`. One file, two loaders.
 * Do not publish a second "live extract."
 *
 * Modes:
 *   1) Local staging (always): copy into app/data/packs/v1/{region}/
 *      → served by Vercel as static files (interim CDN).
 *   2) Cloudflare R2 / S3-compatible: if AWS_ACCESS_KEY_ID + AWS_ENDPOINT_URL
 *      (or R2_*) are set, also `aws s3 sync` the staging tree.
 *
 * Usage:
 *   node scripts/publish-packs-cdn.js              # ns only (merge into existing manifest)
 *   node scripts/publish-packs-cdn.js ns nb
 *   node scripts/publish-packs-cdn.js on --replace-manifest   # dangerous: drops other regions
 *   PACK_CDN_VERSION=v1 node scripts/publish-packs-cdn.js --all-longhaul
 *
 * Does not commit binaries (gitignored). Safe to run in CI after build-graph-v2.
 * Manifest defaults to --merge-manifest so a single-region publish cannot wipe Canada/US.
 */
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const crypto = require("crypto");

const ROOT = path.join(__dirname, "..");
const REGIONS = path.join(ROOT, "routing", "data", "regions");
const VERSION = process.env.PACK_CDN_VERSION || "v1";
const OUT = path.join(ROOT, "app", "data", "packs", VERSION);

const PHONE_FILE_NAMES = ["graph.v2.bin", "geometry.v1.bin"];
const LONGHAUL_FILE_NAMES = ["longhaul.v2.bin", "longhaul.geometry.v1.bin"];

function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex");
}

function listRegionIds(argv) {
  if (argv.includes("--all-longhaul")) {
    return fs
      .readdirSync(REGIONS)
      .filter((id) => fs.existsSync(path.join(REGIONS, id, "longhaul.v2.bin")));
  }
  const ids = argv.filter((a) => !a.startsWith("-"));
  return ids.length ? ids : ["ns"];
}

function fileNamesForArgs(argv) {
  if (argv.includes("--all-longhaul")) return LONGHAUL_FILE_NAMES;
  return PHONE_FILE_NAMES;
}

function stageRegion(regionId, fileNames) {
  const srcDir = path.join(REGIONS, regionId);
  const destDir = path.join(OUT, regionId);
  fs.mkdirSync(destDir, { recursive: true });
  const files = [];
  for (const name of fileNames) {
    const src = path.join(srcDir, name);
    if (!fs.existsSync(src)) continue;
    const dest = path.join(destDir, name);
    fs.copyFileSync(src, dest);
    const st = fs.statSync(dest);
    files.push({
      name,
      bytes: st.size,
      sha256: sha256File(dest)
    });
    console.log("staged", regionId + "/" + name, Math.round(st.size / 1e6) + "MB");
  }
  if (!files.length) {
    console.warn("skip", regionId, "(no v2 binaries — run build-graph-v2.js)");
  }
  return { regionId, files };
}

function writeManifest(regions, { merge = true } = {}) {
  const manifestPath = path.join(OUT, "manifest.json");
  fs.mkdirSync(OUT, { recursive: true });

  let base = {
    schemaVersion: "pack-manifest.v1",
    packFormat: "graph.v2",
    geometryFormat: "geometry.v1",
    version: VERSION,
    generatedAt: new Date().toISOString(),
    basePath: `/app/data/packs/${VERSION}`,
    regions: []
  };

  if (merge && fs.existsSync(manifestPath)) {
    try {
      base = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    } catch (e) {
      console.warn("could not parse existing manifest — rewriting", e.message);
    }
  }

  const byId = new Map((base.regions || []).map((r) => [r.id, r]));
  for (const staged of regions.filter((r) => r.files.length)) {
    byId.set(staged.regionId, { id: staged.regionId, files: staged.files });
  }

  const manifest = {
    ...base,
    schemaVersion: "pack-manifest.v1",
    packFormat: "graph.v2",
    geometryFormat: "geometry.v1",
    version: VERSION,
    generatedAt: new Date().toISOString(),
    basePath: `/app/data/packs/${VERSION}`,
    regions: [...byId.values()].sort((a, b) => a.id.localeCompare(b.id))
  };

  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  console.log(
    "wrote",
    manifestPath,
    merge ? `(merged, ${manifest.regions.length} regions)` : `(replaced, ${manifest.regions.length} regions)`
  );
  return manifest;
}

function syncR2() {
  const endpoint =
    process.env.AWS_ENDPOINT_URL ||
    process.env.R2_ENDPOINT_URL ||
    "";
  const bucket = process.env.R2_BUCKET || process.env.AWS_S3_BUCKET || "";
  const keyId = process.env.AWS_ACCESS_KEY_ID || process.env.R2_ACCESS_KEY_ID;
  if (!endpoint || !bucket || !keyId) {
    console.log(
      "R2/S3 sync skipped (set AWS_ENDPOINT_URL + R2_BUCKET + AWS_ACCESS_KEY_ID to upload)"
    );
    return false;
  }
  const prefix = process.env.R2_PREFIX || `packs/${VERSION}`;
  const dest = `s3://${bucket}/${prefix}`;
  console.log("aws s3 sync", OUT, "→", dest);
  const r = spawnSync(
    "aws",
    ["s3", "sync", OUT, dest, "--endpoint-url", endpoint],
    { stdio: "inherit", env: process.env }
  );
  if (r.status !== 0) {
    console.error("aws s3 sync failed — install AWS CLI or fix credentials");
    process.exit(r.status || 1);
  }
  return true;
}

function main() {
  const argv = process.argv.slice(2);
  const regionIds = listRegionIds(argv);
  const fileNames = fileNamesForArgs(argv);
  const merge = !argv.includes("--replace-manifest");
  console.log("publish packs", VERSION, regionIds.join(","), merge ? "merge-manifest" : "REPLACE-manifest");
  const staged = regionIds.map((id) => stageRegion(id, fileNames));
  const manifest = writeManifest(staged, { merge });
  syncR2();
  console.log(
    JSON.stringify(
      {
        ok: true,
        version: VERSION,
        regionCount: manifest.regions.length,
        localPath: OUT,
        interimPublicURL: process.env.R2_PUBLIC_BASE
          ? `${process.env.R2_PUBLIC_BASE.replace(/\/$/, "")}/manifest.json`
          : `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/manifest.json`
      },
      null,
      2
    )
  );
}

main();
