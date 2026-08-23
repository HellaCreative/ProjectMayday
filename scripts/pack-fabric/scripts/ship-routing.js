#!/usr/bin/env node
"use strict";

/**
 * One door for live + download. There is no second fabric.
 *
 *   node scripts/pack-fabric/scripts/ship-routing.js --assert
 *   node scripts/pack-fabric/scripts/ship-routing.js --pack bc
 *   node scripts/pack-fabric/scripts/ship-routing.js --live
 *   node scripts/pack-fabric/scripts/ship-routing.js --pack bc --live --assert
 *   node scripts/pack-fabric/scripts/ship-routing.js --candidate ns-20260820 --pack ns --live
 *   node scripts/pack-fabric/scripts/ship-routing.js --promote ns-20260820 --pack ns --live
 *
 * --pack  uploads graph.v2.bin + geometry.v1.bin (+ fuel.v1.json if present) to R2 dirt-packs/{id}/
 * --live  deploys /api/route from this pack-fabric tree (not another repo)
 * --assert  curls production; fails if the graph is still the longhaul extract
 * --candidate uploads immutable candidate objects and deploys only the named
 *             regions from that prefix. It does not touch the download manifest.
 * --promote verifies the candidate record, copies the same local checksums to
 *           stable pack keys, updates the approved manifest, and removes the
 *           candidate override on the next live deployment.
 */

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const os = require("os");
const zlib = require("zlib");
const { spawnSync } = require("child_process");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const PACKS = path.join(FABRIC, "app/data/packs/v1");
const PHONE_FILES = ["graph.v2.bin", "geometry.v1.bin"];
const OPTIONAL_PHONE_FILES = ["fuel.v1.json"];
const ALL_PHONE_FILES = PHONE_FILES.concat(OPTIONAL_PHONE_FILES);
const RELEASES = path.join(FABRIC, "routing/data/releases");
const PUBLIC_R2_BASE = process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";
/** Wrangler `r2 object put` rejects bodies over 300 MiB; gzip large packs under that. */
const WRANGLER_MAX_BYTES = 290 * 1024 * 1024;

function die(msg) {
  console.error(msg);
  process.exit(1);
}

function run(cmd, args, opts) {
  const r = spawnSync(cmd, args, {
    encoding: "utf8",
    stdio: "inherit",
    ...opts
  });
  if (r.status !== 0) die((cmd + " " + args.join(" ")).trim() + " failed (" + r.status + ")");
}

function parseArgs(argv) {
  const flags = new Set(argv.filter((a) => a.startsWith("--")));
  const ids = [];
  let candidate = null;
  let promote = null;
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--candidate" || value === "--promote") {
      const releaseId = argv[i + 1];
      if (!releaseId || releaseId.startsWith("--")) die(value + " requires a release id");
      if (!/^[a-z0-9][a-z0-9._-]{2,80}$/i.test(releaseId)) die("invalid release id " + releaseId);
      if (value === "--candidate") candidate = releaseId;
      else promote = releaseId;
      i += 1;
      continue;
    }
    if (!value.startsWith("-")) ids.push(value.toLowerCase());
  }
  if (candidate && promote) die("choose --candidate or --promote, not both");
  return {
    pack: flags.has("--pack"),
    live: flags.has("--live"),
    assert: flags.has("--assert"),
    ids: ids.length ? ids : flags.has("--pack") ? ["bc"] : [],
    candidate,
    promote
  };
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function putR2(regionId, fileName, prefix = "") {
  const src = path.join(PACKS, regionId, fileName);
  if (!fs.existsSync(src)) die("missing " + src + " — build the phone pack first");
  const key = "dirt-packs/" + (prefix ? prefix.replace(/^\/+|\/+$/g, "") + "/" : "") + regionId + "/" + fileName;
  const bytes = fs.statSync(src).size;
  const mb = bytes / 1e6;
  let uploadPath = src;
  const extra = [];
  let tmp = null;
  if (bytes > WRANGLER_MAX_BYTES) {
    tmp = path.join(os.tmpdir(), `dirt-r2-${regionId}-${fileName.replace(/\W+/g, "_")}.gz`);
    const gz = zlib.gzipSync(fs.readFileSync(src), { level: 1 });
    if (gz.length > WRANGLER_MAX_BYTES) {
      die(
        key +
          " is " +
          Math.round(mb) +
          "MB raw / " +
          Math.round(gz.length / 1e6) +
          "MB gzip — still over wrangler 300MiB; need S3 multipart"
      );
    }
    fs.writeFileSync(tmp, gz);
    uploadPath = tmp;
    extra.push("--content-encoding", "gzip");
    console.log(
      "PUT",
      key,
      Math.round(mb) + "MB raw →",
      Math.round(gz.length / 1e6) + "MB gzip (wrangler 300MiB cap)"
    );
  } else {
    console.log("PUT", key, mb >= 1 ? Math.round(mb) + "MB" : Math.round(mb * 1000) + "KB");
  }
  try {
    run(
      "npx",
      ["wrangler", "r2", "object", "put", key, "--file=" + uploadPath, "--remote"].concat(extra),
      { cwd: FABRIC }
    );
  } finally {
    if (tmp) {
      try {
        fs.unlinkSync(tmp);
      } catch (_) {}
    }
  }
}

function releasePath(releaseId) {
  return path.join(RELEASES, releaseId + ".json");
}

function packRecord(regionId) {
  const files = [];
  for (const name of ALL_PHONE_FILES) {
    const file = path.join(PACKS, regionId, name);
    if (!fs.existsSync(file)) {
      if (PHONE_FILES.includes(name)) die("missing " + file);
      continue;
    }
    const stat = fs.statSync(file);
    files.push({ name, bytes: stat.size, sha256: sha256File(file) });
  }
  return { id: regionId, files };
}

function writeCandidateRecord(releaseId, ids) {
  fs.mkdirSync(RELEASES, { recursive: true });
  const record = {
    schemaVersion: "dirt-pack-release.v1",
    releaseId,
    status: "live-candidate",
    createdAt: new Date().toISOString(),
    publicBase: PUBLIC_R2_BASE.replace(/\/$/, "") + "/candidates/" + releaseId,
    regions: ids.map(packRecord)
  };
  const file = releasePath(releaseId);
  if (fs.existsSync(file)) {
    const existing = JSON.parse(fs.readFileSync(file, "utf8"));
    const comparable = (value) => JSON.stringify((value.regions || []).map((region) => ({
      id: region.id,
      files: region.files
    })));
    if (comparable(existing) !== comparable(record)) {
      die("release id " + releaseId + " already exists with different checksums; choose a new id");
    }
    return existing;
  }
  fs.writeFileSync(file, JSON.stringify(record, null, 2) + "\n");
  return record;
}

function readCandidateRecord(releaseId) {
  const file = releasePath(releaseId);
  if (!fs.existsSync(file)) die("missing candidate release record " + file);
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function verifyCandidateRecord(releaseId, ids) {
  const record = readCandidateRecord(releaseId);
  for (const id of ids) {
    const recorded = (record.regions || []).find((region) => region.id === id);
    if (!recorded) die(releaseId + " does not contain region " + id);
    const current = packRecord(id);
    for (const file of recorded.files || []) {
      const local = current.files.find((row) => row.name === file.name);
      if (!local || local.bytes !== file.bytes || local.sha256 !== file.sha256) {
        die(`${releaseId}/${id}/${file.name} no longer matches the tested candidate`);
      }
    }
  }
  return record;
}

function uploadCandidate(releaseId, ids) {
  const prefix = "candidates/" + releaseId;
  const record = writeCandidateRecord(releaseId, ids);
  for (const id of ids) {
    for (const name of ALL_PHONE_FILES) {
      const file = path.join(PACKS, id, name);
      if (fs.existsSync(file)) putR2(id, name, prefix);
    }
  }
  const recordFile = releasePath(releaseId);
  run("npx", ["wrangler", "r2", "object", "put", `dirt-packs/${prefix}/release.json`, "--file=" + recordFile, "--remote"], {
    cwd: FABRIC
  });
  console.log("candidate uploaded without changing the approved download manifest", record.publicBase);
  return record;
}

function mergeFuelIntoManifest(ids) {
  const manifestPath = path.join(PACKS, "manifest.json");
  if (!fs.existsSync(manifestPath)) return;
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  let changed = false;
  for (const id of ids) {
    const src = path.join(PACKS, id, "fuel.v1.json");
    if (!fs.existsSync(src)) continue;
    const region = (manifest.regions || []).find((r) => r.id === id);
    if (!region) continue;
    const st = fs.statSync(src);
    region.files = (region.files || []).filter((f) => f.name !== "fuel.v1.json");
    region.files.push({ name: "fuel.v1.json", bytes: st.size, sha256: sha256File(src) });
    changed = true;
  }
  if (changed) {
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
    console.log("manifest merged fuel.v1.json for", ids.join(","));
  }
}

function shipPack(ids) {
  mergeFuelIntoManifest(ids);
  for (const id of ids) {
    for (const name of PHONE_FILES) putR2(id, name);
    for (const name of OPTIONAL_PHONE_FILES) {
      const src = path.join(PACKS, id, name);
      if (fs.existsSync(src)) putR2(id, name);
      else console.warn("skip", id + "/" + name, "(not built — extract-osm-fuel + pack-region-fuel)");
    }
  }
  const manifest = path.join(PACKS, "manifest.json");
  if (fs.existsSync(manifest)) {
    console.log("PUT dirt-packs/manifest.json (merge on the bucket — this replaces the object)");
    run("npx", ["wrangler", "r2", "object", "put", "dirt-packs/manifest.json", "--file=" + manifest, "--remote"], {
      cwd: FABRIC
    });
  }
  console.log("pack published — live /api/route and PACKS download now share those bytes");
}

/**
 * Pin live `/api/route` to the latest live-candidate per region. Regions whose
 * newest release is promoted resolve from stable R2 with no override.
 */
function collectLiveCandidateOverrides() {
  if (!fs.existsSync(RELEASES)) return {};
  const latestByRegion = {};
  for (const file of fs.readdirSync(RELEASES).filter((name) => name.endsWith(".json"))) {
    const record = JSON.parse(fs.readFileSync(path.join(RELEASES, file), "utf8"));
    for (const region of record.regions || []) {
      const id = region.id;
      const prev = latestByRegion[id];
      if (!prev || String(record.releaseId).localeCompare(String(prev.releaseId)) > 0) {
        latestByRegion[id] = record;
      }
    }
  }
  const overrides = {};
  for (const [id, record] of Object.entries(latestByRegion)) {
    if (record.status !== "live-candidate" || !record.publicBase) continue;
    overrides[id] = String(record.publicBase).replace(/\/$/, "");
  }
  return overrides;
}

function shipLive(regionBaseOverrides) {
  console.log("deploying /api/route from", FABRIC);
  const args = ["vercel", "--prod", "--yes"];
  if (regionBaseOverrides && Object.keys(regionBaseOverrides).length) {
    console.log("R2_REGION_BASE_OVERRIDES for", Object.keys(regionBaseOverrides).length, "regions");
    args.push("--env", "R2_REGION_BASE_OVERRIDES=" + JSON.stringify(regionBaseOverrides));
  }
  run("npx", args, { cwd: FABRIC });
}

function shipAssert() {
  run(process.execPath, [path.join(__dirname, "assert-live-pack-lockstep.js")], {
    cwd: DIRT,
    env: process.env
  });
}

function main() {
  const argv = process.argv.slice(2);
  if (!argv.length || argv.includes("--help")) {
    console.log(`Usage:
  node scripts/pack-fabric/scripts/ship-routing.js --assert
  node scripts/pack-fabric/scripts/ship-routing.js --pack bc
  node scripts/pack-fabric/scripts/ship-routing.js --live
  node scripts/pack-fabric/scripts/ship-routing.js --pack bc --live --assert
  node scripts/pack-fabric/scripts/ship-routing.js --candidate ns-20260820 --pack ns --live
  node scripts/pack-fabric/scripts/ship-routing.js --promote ns-20260820 --pack ns --live`);
    process.exit(argv.includes("--help") ? 0 : 1);
  }
  const opts = parseArgs(argv);
  if ((opts.candidate || opts.promote) && !opts.ids.length) {
    const existing = readCandidateRecord(opts.candidate || opts.promote);
    opts.ids = (existing.regions || []).map((region) => region.id);
  }
  if ((opts.candidate || opts.promote) && !opts.ids.length) {
    die("candidate/promote requires at least one region");
  }
  let liveOverrides = null;
  if (opts.candidate) {
    const record = opts.pack
      ? uploadCandidate(opts.candidate, opts.ids)
      : verifyCandidateRecord(opts.candidate, opts.ids);
    liveOverrides = Object.fromEntries(opts.ids.map((id) => [id, record.publicBase]));
  } else if (opts.promote) {
    verifyCandidateRecord(opts.promote, opts.ids);
    if (opts.pack) shipPack(opts.ids);
  } else if (opts.pack) {
    shipPack(opts.ids);
  }
  if (opts.live) {
    const overrides = liveOverrides || collectLiveCandidateOverrides();
    shipLive(overrides);
  }
  if (opts.assert) shipAssert();
}

main();
