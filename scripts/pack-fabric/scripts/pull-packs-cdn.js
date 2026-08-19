#!/usr/bin/env node
"use strict";

/**
 * Pull live R2 packs into the local staging folder.
 *
 *   node scripts/pack-fabric/scripts/pull-packs-cdn.js bc ab ns
 *   node scripts/pack-fabric/scripts/pull-packs-cdn.js --all
 *
 * Default: bc ab ns. Overwrites those folders with live CDN bytes.
 * Never deletes other region folders. --all fills missing files and skips
 * ones that already match the CDN size.
 */

const fs = require("fs");
const path = require("path");
const https = require("https");
const { spawn } = require("child_process");

const ROOT = path.join(__dirname, "..");
const OUT = path.join(ROOT, "app", "data", "packs", "v1");
const CDN = (process.env.PACK_CDN_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev").replace(
  /\/$/,
  ""
);
const CONCURRENCY = Number(process.env.PULL_CONCURRENCY || 6);

function getBuffer(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        getBuffer(res.headers.location).then(resolve, reject);
        return;
      }
      if (res.statusCode !== 200) {
        res.resume();
        reject(new Error("HTTP " + res.statusCode + " " + url));
        return;
      }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve(Buffer.concat(chunks)));
    });
    req.on("error", reject);
    req.setTimeout(120000, () => req.destroy(new Error("timeout " + url)));
  });
}

function curlGet(url, dest) {
  return new Promise((resolve, reject) => {
    const tmp = dest + ".part";
    try {
      fs.unlinkSync(tmp);
    } catch (_) {}
    const child = spawn(
      "/usr/bin/curl",
      ["-fsSL", "--retry", "3", "--retry-delay", "2", "-o", tmp, url],
      { stdio: ["ignore", "ignore", "pipe"] }
    );
    let err = "";
    child.stderr.on("data", (d) => {
      err += d;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error("curl " + code + " " + url + " " + err.slice(0, 200)));
        return;
      }
      fs.renameSync(tmp, dest);
      resolve();
    });
  });
}

function alreadyGood(dest, bytes) {
  if (!fs.existsSync(dest) || !bytes) return false;
  return fs.statSync(dest).size === bytes;
}

async function pool(items, limit, worker) {
  let i = 0;
  async function run() {
    while (i < items.length) {
      const item = items[i++];
      await worker(item);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, run));
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const manifestUrl = CDN + "/manifest.json";
  console.log("GET", manifestUrl);
  const raw = await getBuffer(manifestUrl);
  const manifest = JSON.parse(raw.toString("utf8"));
  const argv = process.argv.slice(2).filter((a) => a !== "--all");
  const wantAll = process.argv.includes("--all");
  const want = new Set(
    wantAll ? [] : (argv.length ? argv : ["bc", "ab", "ns"]).map((s) => s.toLowerCase())
  );
  const regions = (manifest.regions || []).filter((r) => wantAll || want.has(r.id));
  if (!wantAll && want.size && regions.length !== want.size) {
    const got = new Set(regions.map((r) => r.id));
    throw new Error("missing on CDN: " + [...want].filter((id) => !got.has(id)).join(", "));
  }
  let total = 0;
  const jobs = [];
  for (const r of regions) {
    for (const f of r.files || []) {
      total += Number(f.bytes || 0);
      jobs.push({ id: r.id, file: f });
    }
  }
  console.log(regions.length, "regions ·", Math.round(total / 1e6) + "MB on CDN · concurrency", CONCURRENCY);

  let pulled = 0;
  let skipped = 0;
  await pool(jobs, CONCURRENCY, async ({ id, file }) => {
    const dir = path.join(OUT, id);
    fs.mkdirSync(dir, { recursive: true });
    const dest = path.join(dir, file.name);
    if (wantAll && alreadyGood(dest, file.bytes)) {
      skipped += 1;
      return;
    }
    try {
      fs.unlinkSync(dest);
    } catch (_) {}
    const url = CDN + "/" + id + "/" + file.name;
    await curlGet(url, dest);
    const size = fs.statSync(dest).size;
    if (file.bytes && size !== file.bytes) {
      throw new Error(url + " size " + size + " != manifest " + file.bytes);
    }
    pulled += 1;
    console.log("ok", id + "/" + file.name, Math.round(size / 1e6) + "MB");
  });

  fs.writeFileSync(path.join(OUT, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  console.log("wrote", path.join(OUT, "manifest.json"));
  console.log("done pulled=" + pulled + " already-matched=" + skipped);
}

main().catch((err) => {
  console.error(err && err.message ? err.message : err);
  process.exit(1);
});
