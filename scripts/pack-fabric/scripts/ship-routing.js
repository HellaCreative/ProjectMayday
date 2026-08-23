#!/usr/bin/env node
"use strict";

/**
 * One door for live + download. There is no second fabric.
 *
 *   node scripts/pack-fabric/scripts/ship-routing.js --assert
 *   node scripts/pack-fabric/scripts/ship-routing.js --live
 *   node scripts/pack-fabric/scripts/ship-routing.js --candidate ns-osm-20260821-02 --pack ns --live
 *   node scripts/pack-fabric/scripts/ship-routing.js --promote ns-osm-20260821-02 --pack ns
 *
 * --candidate uploads immutable candidate objects. It does not touch the download catalog.
 * --promote --pack copies recorded candidate bytes to stable keys and merges only
 *             those regions into the current remote catalog.
 * --pack alone is rejected: it used to publish unrecorded local bytes and replace
 *             the 63-region public catalog.
 * --live  deploys /api/route from this pack-fabric tree
 * --assert  curls production; fails if the graph is still the longhaul extract
 */

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const os = require("os");
const { spawnSync } = require("child_process");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const PACKS = path.join(FABRIC, "app/data/packs/v1");
const PHONE_FILES = ["graph.v2.bin", "geometry.v1.bin"];
const OPTIONAL_PHONE_FILES = ["fuel.v1.json"];
const ALL_PHONE_FILES = PHONE_FILES.concat(OPTIONAL_PHONE_FILES);
const RELEASES = path.join(FABRIC, "routing/data/releases");
const PUBLIC_R2_BASE = process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";
const BARE_PACK_REJECTION =
  "bare --pack is rejected: it would publish unrecorded local bytes and replace the public catalog. " +
  "Use --candidate <releaseId> --pack <region> to upload an immutable live candidate without changing the download catalog, " +
  "or --promote <releaseId> --pack <region> to publish the recorded candidate bytes by merging that region into the remote catalog.";

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
    ids,
    candidate,
    promote
  };
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function fileIdentity(file) {
  return {
    name: String(file.name),
    bytes: Number(file.bytes),
    sha256: String(file.sha256)
  };
}

function assertCatalogShape(catalog, label) {
  if (catalog == null || typeof catalog !== "object" || Array.isArray(catalog)) {
    throw new Error(label + " catalog is missing or not an object");
  }
  if (!Array.isArray(catalog.regions)) {
    throw new Error(label + " catalog has no regions array");
  }
}

function parseRemoteCatalogJson(text) {
  if (text == null || String(text).trim() === "") {
    throw new Error("remote catalog unavailable");
  }
  let parsed;
  try {
    parsed = JSON.parse(String(text));
  } catch (error) {
    throw new Error("malformed remote catalog: " + error.message);
  }
  assertCatalogShape(parsed, "remote");
  return parsed;
}

function assertSourceMatchesRelease(sourceFiles, recordedFiles, label) {
  const sourceByName = new Map((sourceFiles || []).map((file) => [file.name, fileIdentity(file)]));
  for (const recorded of recordedFiles || []) {
    const expected = fileIdentity(recorded);
    const source = sourceByName.get(expected.name);
    if (!source || source.bytes !== expected.bytes || source.sha256 !== expected.sha256) {
      throw new Error(`${label}/${expected.name} no longer matches the tested candidate`);
    }
  }
}

function mergePromotedRegionsIntoCatalog(remoteCatalog, promotedRegions, options = {}) {
  assertCatalogShape(remoteCatalog, "remote");
  if (!Array.isArray(promotedRegions) || !promotedRegions.length) {
    throw new Error("promotion requires at least one region");
  }
  const byId = new Map();
  for (const region of promotedRegions) {
    if (!region || !region.id) throw new Error("promoted region is missing id");
    const files = (region.files || []).map(fileIdentity);
    for (const required of PHONE_FILES) {
      if (!files.some((file) => file.name === required)) {
        throw new Error("release record missing " + required + " for " + region.id);
      }
    }
    byId.set(region.id, { id: region.id, files });
  }
  const seen = new Set();
  const regions = remoteCatalog.regions.map((region) => {
    const promoted = byId.get(region.id);
    if (!promoted) return region;
    seen.add(region.id);
    return Object.assign({}, region, { id: region.id, files: promoted.files });
  });
  for (const promoted of byId.values()) {
    if (!seen.has(promoted.id)) {
      regions.push({ id: promoted.id, files: promoted.files });
    }
  }
  const catalog = Object.assign({}, remoteCatalog, { regions });
  if (options.generatedAt !== false) {
    catalog.generatedAt = options.generatedAt || new Date().toISOString();
  }
  return catalog;
}

function planStablePublication({
  remoteCatalogText,
  releaseRecord,
  regionIds,
  sourceRegions,
  generatedAt
} = {}) {
  const remote = parseRemoteCatalogJson(remoteCatalogText);
  if (!releaseRecord || !Array.isArray(releaseRecord.regions)) {
    throw new Error("immutable release record is missing regions");
  }
  if (!Array.isArray(regionIds) || !regionIds.length) {
    throw new Error("promotion requires at least one region");
  }
  const sourceById = new Map((sourceRegions || []).map((region) => [region.id, region]));
  const promoted = [];
  for (const id of regionIds) {
    const recorded = releaseRecord.regions.find((region) => region.id === id);
    if (!recorded) {
      throw new Error((releaseRecord.releaseId || "release") + " does not contain region " + id);
    }
    const source = sourceById.get(id);
    if (!source) throw new Error("missing local source for " + id);
    const label = (releaseRecord.releaseId || "release") + "/" + id;
    assertSourceMatchesRelease(source.files, recorded.files, label);
    promoted.push({
      id,
      files: (recorded.files || []).map(fileIdentity)
    });
  }
  return {
    catalog: mergePromotedRegionsIntoCatalog(remote, promoted, { generatedAt }),
    promoted
  };
}

function publishStablePack(input) {
  const planned = planStablePublication(input);
  const putObject = input && input.putObject;
  if (typeof putObject !== "function") {
    throw new Error("publication requires a putObject handler");
  }
  for (const region of planned.promoted) {
    for (const file of region.files) {
      putObject({
        kind: "pack",
        regionId: region.id,
        fileName: file.name,
        bytes: file.bytes,
        sha256: file.sha256
      });
    }
  }
  putObject({ kind: "manifest", catalog: planned.catalog });
  return planned;
}

function assertPublicationCommand(opts) {
  if (opts && opts.pack && !opts.promote && !opts.candidate) {
    throw new Error(BARE_PACK_REJECTION);
  }
}

function putR2(regionId, fileName, prefix = "") {
  const src = path.join(PACKS, regionId, fileName);
  if (!fs.existsSync(src)) die("missing " + src + " — build the phone pack first");
  const key = "dirt-packs/" + (prefix ? prefix.replace(/^\/+|\/+$/g, "") + "/" : "") + regionId + "/" + fileName;
  const mb = fs.statSync(src).size / 1e6;
  console.log("PUT", key, mb >= 1 ? Math.round(mb) + "MB" : Math.round(mb * 1000) + "KB");
  run("npx", ["wrangler", "r2", "object", "put", key, "--file=" + src, "--remote"], {
    cwd: FABRIC
  });
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
    assertSourceMatchesRelease(packRecord(id).files, recorded.files, `${releaseId}/${id}`);
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

function fetchRemoteCatalogText() {
  const url = PUBLIC_R2_BASE.replace(/\/$/, "") + "/manifest.json";
  const script =
    "fetch(process.argv[1],{cache:'no-store'}).then(async(res)=>{if(!res.ok){console.error('HTTP '+res.status);process.exit(2);}process.stdout.write(await res.text());}).catch((err)=>{console.error(err&&err.message?err.message:err);process.exit(2);});";
  const r = spawnSync(process.execPath, ["-e", script, url], {
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024
  });
  if (r.status !== 0) {
    throw new Error("remote catalog unavailable" + (r.stderr ? ": " + String(r.stderr).trim() : ""));
  }
  return r.stdout;
}

async function shipPack(ids, releaseRecord) {
  const remoteCatalogText = await fetchRemoteCatalogText();
  publishStablePack({
    remoteCatalogText,
    releaseRecord,
    regionIds: ids,
    sourceRegions: ids.map(packRecord),
    putObject: (item) => {
      if (item.kind === "pack") {
        putR2(item.regionId, item.fileName);
        return;
      }
      if (item.kind !== "manifest") return;
      const tmp = path.join(os.tmpdir(), "dirt-manifest-merge-" + process.pid + ".json");
      fs.writeFileSync(tmp, JSON.stringify(item.catalog, null, 2) + "\n");
      try {
        console.log("PUT dirt-packs/manifest.json (merge only promoted regions into the remote catalog)");
        run(
          "npx",
          ["wrangler", "r2", "object", "put", "dirt-packs/manifest.json", "--file=" + tmp, "--remote"],
          { cwd: FABRIC }
        );
      } finally {
        try {
          fs.unlinkSync(tmp);
        } catch (_) {}
      }
    }
  });
  console.log("pack published — live /api/route and PACKS download now share those recorded bytes");
}

function shipLive(regionBaseOverrides) {
  console.log("deploying /api/route from", FABRIC);
  const git = spawnSync("git", ["rev-parse", "HEAD"], { cwd: DIRT, encoding: "utf8" });
  const sourceVersion = git.status === 0 ? String(git.stdout || "").trim() : "";
  if (!/^[a-f0-9]{7,40}$/i.test(sourceVersion)) {
    throw new Error("live deployment requires a committed Git source identity");
  }
  const args = liveDeployArgs(regionBaseOverrides, sourceVersion);
  run("npx", args, { cwd: FABRIC });
}

function liveDeployArgs(regionBaseOverrides, sourceVersion) {
  if (!/^[a-f0-9]{7,40}$/i.test(String(sourceVersion || ""))) {
    throw new Error("live deployment requires a committed Git source identity");
  }
  const args = ["vercel", "--prod", "--yes", "--env", "SOURCE_VERSION=" + sourceVersion];
  if (regionBaseOverrides && Object.keys(regionBaseOverrides).length) {
    args.push("--env", "R2_REGION_BASE_OVERRIDES=" + JSON.stringify(regionBaseOverrides));
  }
  return args;
}

function shipAssert() {
  run(process.execPath, [path.join(__dirname, "assert-live-pack-lockstep.js")], {
    cwd: DIRT,
    env: process.env
  });
}

async function main() {
  const argv = process.argv.slice(2);
  if (!argv.length || argv.includes("--help")) {
    console.log(`Usage:
  node scripts/pack-fabric/scripts/ship-routing.js --assert
  node scripts/pack-fabric/scripts/ship-routing.js --live
  node scripts/pack-fabric/scripts/ship-routing.js --candidate ns-osm-20260821-02 --pack ns --live
  node scripts/pack-fabric/scripts/ship-routing.js --promote ns-osm-20260821-02 --pack ns
bare --pack is rejected; use --candidate/--promote with a recorded release id.`);
    process.exit(argv.includes("--help") ? 0 : 1);
  }
  const opts = parseArgs(argv);
  assertPublicationCommand(opts);
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
    const record = verifyCandidateRecord(opts.promote, opts.ids);
    if (opts.pack) await shipPack(opts.ids, record);
  }
  if (opts.live) shipLive(liveOverrides);
  if (opts.assert) shipAssert();
}

if (require.main === module) {
  main().catch((error) => {
    die(error && error.message ? error.message : String(error));
  });
}

module.exports = {
  ALL_PHONE_FILES,
  BARE_PACK_REJECTION,
  PHONE_FILES,
  assertPublicationCommand,
  assertSourceMatchesRelease,
  mergePromotedRegionsIntoCatalog,
  liveDeployArgs,
  parseArgs,
  parseRemoteCatalogJson,
  planStablePublication,
  publishStablePack
};
