#!/usr/bin/env node
"use strict";

/**
 * Assemble a FULL national V4 candidate that replaces monolithic on/qc/ca/nl
 * with published halves, reusing sealed production packs for every other region.
 *
 *   node scripts/pack-fabric/scripts/assemble-full-split-fabric.js \
 *     --release fabric-v4-20260917-02 \
 *     --production fabric-v4-20260909-02 \
 *     --on-partial fabric-v4-20260917-01
 *
 * Same-length string restamp keeps RegionalGraph epoch/release lockstep without
 * rewriting graph section offsets. Newly built split packs must already share
 * the --epoch value (extend the ON partial source lock).
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const { catalogRegionIds, OSM_REGION } = require("../routing/registry/geofabrik");

const FABRIC = path.join(__dirname, "..");
const DIRT = path.resolve(FABRIC, "../..");

const PHONE_FILES = ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "cross-pack-seams.v2.json"];
const AUDIT_FILES = ["pack-manifest.v2.json", "legal-topology-report.json"];
const TEXT_REPLACE_FILES = [
  "pack-manifest.v2.json",
  "cross-pack-seams.v2.json",
  "legal-topology-report.json",
  "fuel.v1.json",
  "restriction-revision.v1.json"
];

function die(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const opts = {
    release: null,
    production: "fabric-v4-20260909-02",
    onPartial: "fabric-v4-20260917-01",
    epoch: null,
    root: null
  };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--release") opts.release = argv[++i];
    else if (value === "--production") opts.production = argv[++i];
    else if (value === "--on-partial") opts.onPartial = argv[++i];
    else if (value === "--epoch") opts.epoch = argv[++i];
    else if (value === "--root") opts.root = path.resolve(argv[++i]);
    else die(`unknown argument ${value}`);
  }
  if (!opts.release || !/^fabric-v4-[0-9]{8}-[0-9]{2}$/.test(opts.release)) {
    die("--release must be fabric-v4-YYYYMMDD-NN");
  }
  opts.root = opts.root || path.join(FABRIC, "routing", "candidates", opts.release);
  opts.productionRoot = path.join(FABRIC, "routing", "candidates", opts.production);
  opts.onPartialRoot = path.join(FABRIC, "routing", "candidates", opts.onPartial);
  return opts;
}

function shaFile(file) {
  const hash = crypto.createHash("sha256");
  const fd = fs.openSync(file, "r");
  const buffer = Buffer.allocUnsafe(8 * 1024 * 1024);
  try {
    for (;;) {
      const read = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (!read) break;
      hash.update(buffer.subarray(0, read));
    }
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest("hex");
}

function identity(file) {
  return { name: path.basename(file), bytes: fs.statSync(file).size, sha256: shaFile(file) };
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
}

function copyTree(src, dest) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.cpSync(src, dest, { recursive: true, force: true });
}

function replaceAllBuffer(buf, from, to) {
  if (from.length !== to.length) die(`restamp length mismatch ${from} vs ${to}`);
  const fromBuf = Buffer.from(from, "utf8");
  const toBuf = Buffer.from(to, "utf8");
  let count = 0;
  let index = 0;
  while (index < buf.length) {
    const at = buf.indexOf(fromBuf, index);
    if (at < 0) break;
    toBuf.copy(buf, at);
    count += 1;
    index = at + toBuf.length;
  }
  return count;
}

function restampFile(filePath, replacements) {
  if (!fs.existsSync(filePath)) return 0;
  const original = fs.readFileSync(filePath);
  const buf = Buffer.from(original);
  let total = 0;
  for (const [from, to] of replacements) total += replaceAllBuffer(buf, from, to);
  if (total > 0) fs.writeFileSync(filePath, buf);
  return total;
}

function refreshManifestIdentities(packDir, releaseId, epoch) {
  const manifestPath = path.join(packDir, "pack-manifest.v2.json");
  const manifest = readJSON(manifestPath);
  manifest.fabricReleaseId = releaseId;
  manifest.sourceEpoch = epoch;
  for (const key of ["graph", "geometry", "fuel", "seams", "restrictionRevision"]) {
    const entry = manifest[key];
    if (!entry || !entry.name) continue;
    const filePath = path.join(packDir, entry.name);
    if (!fs.existsSync(filePath)) continue;
    const next = identity(filePath);
    entry.bytes = next.bytes;
    entry.sha256 = next.sha256;
  }
  writeJSON(manifestPath, manifest);
  return manifest;
}

function gitHead() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: DIRT, encoding: "utf8" });
  if (result.status !== 0) die("could not resolve factory commit");
  return String(result.stdout || "").trim();
}

function sourceForRegion(id, opts) {
  if (id === "on-s" || id === "on-n") return { kind: "on-partial", root: opts.onPartialRoot };
  if (["qc-s", "qc-n", "ca-s", "ca-n", "nl-island", "nl-lab"].includes(id)) {
    return { kind: "built", root: opts.root };
  }
  return { kind: "production", root: opts.productionRoot };
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const catalog = catalogRegionIds();
  const productionRelease = readJSON(path.join(opts.productionRoot, "release.json"));
  const onPartialRelease = readJSON(path.join(opts.onPartialRoot, "release.json"));
  const epoch = opts.epoch || onPartialRelease.sourceEpoch;
  if (!epoch) die("missing --epoch and on-partial sourceEpoch");
  if (epoch.length !== productionRelease.sourceEpoch.length) {
    die(`epoch length must match production (${productionRelease.sourceEpoch.length})`);
  }
  if (opts.release.length !== productionRelease.releaseId.length) {
    die("release id length must match production for binary restamp");
  }

  const packRoot = path.join(opts.root, "packs");
  const riderRoot = path.join(opts.root, "rider-services");
  fs.mkdirSync(packRoot, { recursive: true });
  fs.mkdirSync(riderRoot, { recursive: true });

  const replacementsForProduction = [
    [productionRelease.releaseId, opts.release],
    [productionRelease.sourceEpoch, epoch]
  ];
  const replacementsForOn = [
    [onPartialRelease.releaseId, opts.release]
  ];

  const records = [];
  for (let index = 0; index < catalog.length; index += 1) {
    const id = catalog[index];
    const source = sourceForRegion(id, opts);
    const destPack = path.join(packRoot, id);
    const destRider = path.join(riderRoot, id);
    const srcPack = path.join(source.root, "packs", id);
    const srcRider = path.join(source.root, "rider-services", id);
    if (!fs.existsSync(srcPack)) die(`missing pack source ${srcPack}`);
    if (!fs.existsSync(srcRider)) die(`missing rider-services source ${srcRider}`);

    console.log(`[${index + 1}/${catalog.length}] assemble ${id} from ${source.kind}`);
    if (path.resolve(srcPack) !== path.resolve(destPack)) {
      copyTree(srcPack, destPack);
    }
    if (path.resolve(srcRider) !== path.resolve(destRider)) {
      copyTree(srcRider, destRider);
    }

    if (source.kind === "production") {
      restampFile(path.join(destPack, "graph.v4.bin"), replacementsForProduction);
      for (const name of TEXT_REPLACE_FILES) {
        restampFile(path.join(destPack, name), replacementsForProduction);
      }
      restampFile(path.join(destRider, "rider-services.v1.json"), replacementsForProduction);
    } else if (source.kind === "on-partial") {
      restampFile(path.join(destPack, "graph.v4.bin"), replacementsForOn);
      for (const name of TEXT_REPLACE_FILES) {
        restampFile(path.join(destPack, name), replacementsForOn);
      }
      restampFile(path.join(destRider, "rider-services.v1.json"), replacementsForOn);
    } else {
      // Newly built packs already carry the target release/epoch from the factory.
      const manifest = readJSON(path.join(destPack, "pack-manifest.v2.json"));
      if (manifest.fabricReleaseId !== opts.release || manifest.sourceEpoch !== epoch) {
        die(`${id}: built pack identity mismatch (${manifest.fabricReleaseId}/${manifest.sourceEpoch})`);
      }
    }

    const manifest = refreshManifestIdentities(destPack, opts.release, epoch);
    const riderPath = path.join(destRider, "rider-services.v1.json");
    const rider = readJSON(riderPath);
    records.push({
      id,
      packManifest: {
        schema: manifest.schema,
        fabricReleaseId: manifest.fabricReleaseId,
        regionId: manifest.regionId,
        capabilities: manifest.capabilities,
        graph: manifest.graph,
        geometry: manifest.geometry,
        fuel: manifest.fuel,
        sourceEpoch: manifest.sourceEpoch,
        timezone: manifest.timezone,
        seams: manifest.seams,
        restrictionRevision: manifest.restrictionRevision || undefined
      },
      riderServices: {
        name: "rider-services.v1.json",
        bytes: fs.statSync(riderPath).size,
        sha256: shaFile(riderPath),
        counts: rider.counts,
        sourceUpdatedAt: rider.sourceUpdatedAt || null
      }
    });
  }

  // Full topology for the assembled catalog.
  const topologyFile = path.join(opts.root, "cross-pack-topology.v2.json");
  const seam = spawnSync(
    process.execPath,
    [
      path.join(__dirname, "build-v4-seams.js"),
      "--root", packRoot,
      "--output", topologyFile,
      "--regions",
      catalog.join(",")
    ],
    { cwd: DIRT, stdio: "inherit" }
  );
  if (seam.status !== 0) die("build-v4-seams failed");

  const thinPairs = [
    ["on-s", "on-n"],
    ["qc-s", "qc-n"],
    ["ca-s", "ca-n"],
    ["nl-island", "nl-lab"]
  ];
  for (const [a, b] of thinPairs) {
    const thin = spawnSync(
      process.execPath,
      [
        path.join(__dirname, "thin-subregion-seams.js"),
        "--topology",
        topologyFile,
        "--root",
        packRoot,
        "--pair",
        `${a},${b}`,
        "--max",
        "600"
      ],
      { cwd: DIRT, stdio: "inherit" }
    );
    if (thin.status !== 0) die(`thin-subregion-seams failed for ${a},${b}`);
  }

  // Refresh manifests after seam sidecars changed.
  for (const id of catalog) {
    refreshManifestIdentities(path.join(packRoot, id), opts.release, epoch);
  }
  for (let i = 0; i < records.length; i += 1) {
    const manifest = readJSON(path.join(packRoot, records[i].id, "pack-manifest.v2.json"));
    records[i].packManifest = {
      schema: manifest.schema,
      fabricReleaseId: manifest.fabricReleaseId,
      regionId: manifest.regionId,
      capabilities: manifest.capabilities,
      graph: manifest.graph,
      geometry: manifest.geometry,
      fuel: manifest.fuel,
      sourceEpoch: manifest.sourceEpoch,
      timezone: manifest.timezone,
      seams: manifest.seams,
      restrictionRevision: manifest.restrictionRevision || undefined
    };
  }

  const topologyDoc = readJSON(topologyFile);
  if (topologyDoc.fabricReleaseId !== opts.release) {
    // Seams builder stamps from pack manifests; force release identity if needed.
    topologyDoc.fabricReleaseId = opts.release;
    topologyDoc.sourceEpoch = epoch;
    writeJSON(topologyFile, topologyDoc);
  }
  const topologyIdentity = identity(topologyFile);
  const sourceLockPath = path.join(opts.root, "source-lock.json");
  if (!fs.existsSync(sourceLockPath)) die("source-lock.json missing; prepare lock before assemble");

  const release = {
    schemaVersion: "dirt-fabric-release.v4",
    releaseId: opts.release,
    status: "local-candidate-sealed",
    createdAt: new Date().toISOString(),
    factoryCommit: gitHead(),
    assemblyCommit: gitHead(),
    sourceEpoch: epoch,
    sourceLock: null,
    parentRelease: opts.production,
    onPartialRelease: opts.onPartial,
    completeFabric: true,
    requiredRegionCount: catalog.length,
    regionCount: catalog.length,
    reusedRegions: catalog.filter((id) => sourceForRegion(id, opts).kind !== "built").length,
    regions: records,
    topology: { ...topologyIdentity, pairs: (topologyDoc.pairs || []).length }
  };
  writeJSON(path.join(opts.root, "release.json"), release);
  console.log(
    JSON.stringify(
      {
        releaseId: opts.release,
        sourceEpoch: epoch,
        regionCount: catalog.length,
        topologyPairs: release.topology.pairs,
        reusedRegions: release.reusedRegions
      },
      null,
      2
    )
  );
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = { main, parseArgs };
