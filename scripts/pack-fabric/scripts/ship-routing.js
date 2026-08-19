#!/usr/bin/env node
"use strict";

/**
 * One door for live + download. There is no second fabric.
 *
 *   node scripts/pack-fabric/scripts/ship-routing.js --assert
 *   node scripts/pack-fabric/scripts/ship-routing.js --pack bc
 *   node scripts/pack-fabric/scripts/ship-routing.js --live
 *   node scripts/pack-fabric/scripts/ship-routing.js --pack bc --live --assert
 *
 * --pack  uploads graph.v2.bin + geometry.v1.bin (+ fuel.v1.json if present) to R2 dirt-packs/{id}/
 * --live  deploys /api/route from this pack-fabric tree (not another repo)
 * --assert  curls production; fails if the graph is still the longhaul extract
 */

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const PACKS = path.join(FABRIC, "app/data/packs/v1");
const PHONE_FILES = ["graph.v2.bin", "geometry.v1.bin"];
const OPTIONAL_PHONE_FILES = ["fuel.v1.json"];

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
  const ids = argv.filter((a) => !a.startsWith("-")).map((s) => s.toLowerCase());
  return {
    pack: flags.has("--pack"),
    live: flags.has("--live"),
    assert: flags.has("--assert"),
    ids: ids.length ? ids : flags.has("--pack") ? ["bc"] : []
  };
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function putR2(regionId, fileName) {
  const src = path.join(PACKS, regionId, fileName);
  if (!fs.existsSync(src)) die("missing " + src + " — build the phone pack first");
  const key = "dirt-packs/" + regionId + "/" + fileName;
  const mb = fs.statSync(src).size / 1e6;
  console.log("PUT", key, mb >= 1 ? Math.round(mb) + "MB" : Math.round(mb * 1000) + "KB");
  run("npx", ["wrangler", "r2", "object", "put", key, "--file=" + src, "--remote"], {
    cwd: FABRIC
  });
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

function shipLive() {
  console.log("deploying /api/route from", FABRIC);
  run("npx", ["vercel", "--prod", "--yes"], { cwd: FABRIC });
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
  node scripts/pack-fabric/scripts/ship-routing.js --pack bc --live --assert`);
    process.exit(argv.includes("--help") ? 0 : 1);
  }
  const opts = parseArgs(argv);
  if (opts.pack) shipPack(opts.ids);
  if (opts.live) shipLive();
  if (opts.assert) shipAssert();
}

main();
