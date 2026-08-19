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
 * --pack  uploads Dirt graph.v2.bin + geometry.v1.bin to R2 dirt-packs/{id}/
 *         That object is PACKS download AND live /api/route.
 * --live  copies phone cost tables into Mayday and deploys /api/route.
 *         Refuses Documents/Mayday when overlay chunks are dirty.
 * --assert  curls production; fails if the graph is still the longhaul extract.
 */

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const DIRT = path.resolve(__dirname, "../../..");
const MAYDAY = process.env.MAYDAY_ROOT || "/Users/richardsmith/Documents/Mayday";
const PACKS = path.join(DIRT, "scripts/pack-fabric/app/data/packs/v1");
const COSTS_SRC = path.join(DIRT, "scripts/pack-fabric/routing/lib/profile-costs.js");
const PHONE_FILES = ["graph.v2.bin", "geometry.v1.bin"];

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

function overlayChunkCount(root) {
  const dir = path.join(root, "app/data/bc-gov-chunks");
  if (!fs.existsSync(dir)) return 0;
  const st = spawnSync("git", ["-C", root, "status", "--porcelain", "app/data/bc-gov-chunks"], {
    encoding: "utf8"
  });
  if (st.status !== 0) return 0;
  return (st.stdout || "").split("\n").filter(Boolean).length;
}

function putR2(regionId, fileName) {
  const src = path.join(PACKS, regionId, fileName);
  if (!fs.existsSync(src)) die("missing " + src + " — build the phone pack first");
  const key = "dirt-packs/" + regionId + "/" + fileName;
  console.log("PUT", key, Math.round(fs.statSync(src).size / 1e6) + "MB");
  run("npx", ["wrangler", "r2", "object", "put", key, "--file=" + src, "--remote"], {
    cwd: MAYDAY
  });
}

function shipPack(ids) {
  if (!fs.existsSync(MAYDAY)) die("MAYDAY_ROOT not found: " + MAYDAY);
  for (const id of ids) {
    for (const name of PHONE_FILES) putR2(id, name);
  }
  const manifest = path.join(PACKS, "manifest.json");
  if (fs.existsSync(manifest)) {
    console.log("PUT dirt-packs/manifest.json (merge on the bucket — this replaces the object)");
    run(
      "npx",
      ["wrangler", "r2", "object", "put", "dirt-packs/manifest.json", "--file=" + manifest, "--remote"],
      { cwd: MAYDAY }
    );
  }
  console.log("pack published — live /api/route and PACKS download now share those bytes");
}

function shipLive() {
  if (!fs.existsSync(MAYDAY)) die("MAYDAY_ROOT not found: " + MAYDAY);
  const dirtyChunks = overlayChunkCount(MAYDAY);
  if (dirtyChunks > 20) {
    die(
      "Refuse to vercel --prod from " +
        MAYDAY +
        " (" +
        dirtyChunks +
        " dirty overlay chunks). Use a clean worktree on origin/main:\n" +
        "  git -C " +
        MAYDAY +
        " worktree add /tmp/mayday-ship origin/main\n" +
        "  MAYDAY_ROOT=/tmp/mayday-ship node scripts/pack-fabric/scripts/ship-routing.js --live"
    );
  }
  const dest = path.join(MAYDAY, "routing/lib/profile-costs.js");
  if (!fs.existsSync(dest)) die("Mayday profile-costs missing: " + dest);
  fs.copyFileSync(COSTS_SRC, dest);
  console.log("copied", COSTS_SRC, "→", dest);
  console.log("deploying /api/route from", MAYDAY);
  run("npx", ["vercel", "--prod", "--yes"], { cwd: MAYDAY });
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
