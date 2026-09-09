#!/usr/bin/env node
"use strict";

/**
 * Resume-safe V4 continent factory. Graph, fuel, and Rider Services for each
 * region are built from one source lock. Large intermediates are deleted only
 * after that region's final artifacts pass their manifests.
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const os = require("os");
const { spawnSync } = require("child_process");
const { OSM_REGION } = require("../routing/registry/geofabrik");
const { validatePackManifestV2 } = require("../routing/lib/pack-manifest-v2");
const { validateGeometry } = require("./prepare-v4-polygons");
const { clipGeojsonPath } = require("./fetch-admin-polygon");

const FABRIC = path.join(__dirname, "..");
const DIRT = path.resolve(FABRIC, "../..");
const ALL_REGIONS = Object.keys(OSM_REGION).sort();
const GIB = 1024 ** 3;

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

function fileIdentity(file) {
  return { name: path.basename(file), bytes: fs.statSync(file).size, sha256: shaFile(file) };
}

function parseArgs(argv) {
  const opts = { releaseId: null, sourceLock: null, root: null, keepWork: false, regions: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--release") opts.releaseId = argv[++i];
    else if (value === "--source-lock") opts.sourceLock = path.resolve(argv[++i]);
    else if (value === "--root") opts.root = path.resolve(argv[++i]);
    else if (value === "--keep-work") opts.keepWork = true;
    else if (value.startsWith("-")) throw new Error(`unknown argument ${value}`);
    else opts.regions.push(String(value).toLowerCase());
  }
  if (!/^fabric-v4-[0-9]{8}-[0-9]{2}$/.test(opts.releaseId || "")) {
    throw new Error("--release must be fabric-v4-YYYYMMDD-NN");
  }
  if (!opts.sourceLock) throw new Error("--source-lock is required");
  opts.root = opts.root || path.join(FABRIC, "routing", "candidates", opts.releaseId);
  opts.regions = opts.regions.length ? [...new Set(opts.regions)].sort() : ALL_REGIONS;
  for (const id of opts.regions) if (!OSM_REGION[id]) throw new Error(`unknown region ${id}`);
  return opts;
}

function readSourceLock(file) {
  const doc = JSON.parse(fs.readFileSync(file, "utf8"));
  if (doc.schema !== "dirt-osm-source-lock.v1" || !doc.fabricEpoch || !doc.regions) {
    throw new Error("source lock is incomplete");
  }
  return doc;
}

function freeBytes(at) {
  fs.mkdirSync(at, { recursive: true });
  const stats = fs.statfsSync(at);
  return Number(stats.bavail) * Number(stats.bsize);
}

function assertDiskSpace(at, id) {
  const minimum = Number(process.env.DIRT_V4_MIN_FREE_GIB || 16) * GIB;
  const free = freeBytes(at);
  if (!Number.isFinite(free) || free < minimum) {
    throw new Error(`${id}: only ${(free / GIB).toFixed(1)} GiB free; ${minimum / GIB} GiB safety floor`);
  }
}

function run(command, args, env, { attempts = 1 } = {}) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const result = spawnSync(command, args, { cwd: DIRT, stdio: "inherit", env: { ...process.env, ...env } });
    if (result.status === 0) return;
    if (attempt < attempts) {
      console.warn(`${path.basename(args[0] || command)} failed; retrying (${attempt + 1}/${attempts})`);
    }
  }
  throw new Error(`${path.basename(args[0] || command)} failed after ${attempts} attempt(s)`);
}

function graphHeapMiB() {
  const physicalMiB = Math.floor(os.totalmem() / (1024 * 1024));
  const safeCeiling = Math.max(2048, Math.floor(physicalMiB * 0.62));
  const requested = Number(process.env.DIRT_V4_GRAPH_HEAP_MIB || 10240);
  return Math.min(Number.isFinite(requested) ? requested : 10240, safeCeiling);
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function verifyRegion(paths, id, releaseId, lock, { requireSeams = false, factoryCommit = null } = {}) {
  const dir = path.join(paths.packRoot, id);
  const manifest = readJSON(path.join(dir, "pack-manifest.v2.json"));
  validatePackManifestV2(manifest, { requireSeams });
  if (manifest.fabricReleaseId !== releaseId || manifest.regionId !== id) {
    throw new Error(`${id}: manifest release identity mismatch`);
  }
  if (manifest.sourceEpoch !== lock.fabricEpoch) {
    throw new Error(`${id}: pack source epoch mismatch`);
  }
  const artifactKeys = ["graph", "geometry", "fuel"];
  if (manifest.seams) artifactKeys.push("seams");
  for (const key of artifactKeys) {
    const file = path.join(dir, manifest[key].name);
    const identity = fileIdentity(file);
    if (identity.bytes !== manifest[key].bytes || identity.sha256 !== manifest[key].sha256) {
      throw new Error(`${id}: ${key} does not match its manifest`);
    }
  }

  const reportFile = path.join(dir, "legal-topology-report.json");
  const report = readJSON(reportFile);
  if (report.unprovenStitches !== 0 || !report.counts || report.counts.nodes <= 0 || report.counts.edges <= 0) {
    throw new Error(`${id}: legal-topology report is incomplete`);
  }
  if (!report.provenance || report.provenance.sourceEpoch !== lock.fabricEpoch) {
    throw new Error(`${id}: legal-topology provenance mismatch`);
  }
  if (factoryCommit && report.provenance.factoryCommit !== factoryCommit) {
    throw new Error(`${id}: pack was built by a different factory commit`);
  }

  const riderFile = path.join(paths.riderRoot, id, "rider-services.v1.json");
  const rider = readJSON(riderFile);
  if (rider.schema !== "rider-services.v1" || rider.regionId !== id) {
    throw new Error(`${id}: Rider Services identity mismatch`);
  }
  for (const category of ["campground", "lodging", "liquor"]) {
    if (!Number.isSafeInteger(rider.counts && rider.counts[category]) || rider.counts[category] <= 0) {
      throw new Error(`${id}: Rider Services has no ${category} data`);
    }
  }
  const source = lock.regions[id];
  if (rider.sourceUpdatedAt !== source.osmTimestamp) {
    throw new Error(`${id}: Rider Services was not built from the locked source`);
  }

  const fuel = readJSON(path.join(dir, "fuel.v1.json"));
  if (fuel.schema !== "fuel.v1" || fuel.regionId !== id || !Array.isArray(fuel.stations) || !fuel.stations.length) {
    throw new Error(`${id}: fuel sidecar is incomplete`);
  }
  if (fuel.sourceUpdatedAt !== source.osmTimestamp) {
    throw new Error(`${id}: fuel was not built from the locked source`);
  }

  return {
    id,
    packManifest: manifest,
    legalTopologyReport: fileIdentity(reportFile),
    legalCounts: report.counts,
    fuelStations: fuel.stations.length,
    riderServices: {
      ...fileIdentity(riderFile),
      counts: rider.counts,
      sourceUpdatedAt: rider.sourceUpdatedAt
    }
  };
}

function safeCleanWork(paths, source) {
  if (paths.keepWork) return;
  for (const dir of [
    path.join(paths.legalRoot, source.slug),
    path.join(paths.serviceRoot, source.slug)
  ]) {
    const relative = path.relative(paths.workRoot, dir);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error(`refusing to clean non-work path ${dir}`);
    }
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
}

function sameRegions(left, right) {
  return left.length === right.length && left.every((id, index) => id === right[index]);
}

function gitHead() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: DIRT, encoding: "utf8" });
  if (result.status !== 0) throw new Error("could not resolve factory commit");
  return String(result.stdout || "").trim();
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const lock = readSourceLock(options.sourceLock);
  for (const id of options.regions) {
    if (!lock.regions[id]) throw new Error(`source lock missing ${id}`);
    const polygon = clipGeojsonPath(id);
    if (!polygon) throw new Error(`admin polygon missing ${id}; run prepare-v4-polygons.js`);
    validateGeometry(polygon, id);
  }

  const paths = {
    candidateRoot: options.root,
    packRoot: path.join(options.root, "packs"),
    riderRoot: path.join(options.root, "rider-services"),
    workRoot: path.join(options.root, "work"),
    legalRoot: path.join(options.root, "work", "legal"),
    serviceRoot: path.join(options.root, "work", "services"),
    keepWork: options.keepWork
  };
  for (const dir of [paths.packRoot, paths.riderRoot, paths.workRoot]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const progressFile = path.join(options.root, "progress.json");
  const factoryCommit = gitHead();
  let records = [];
  for (let index = 0; index < options.regions.length; index += 1) {
    const id = options.regions[index];
    const source = OSM_REGION[id];
    assertDiskSpace(options.root, id);
    let record = null;
    try {
      record = verifyRegion(paths, id, options.releaseId, lock, { factoryCommit });
      console.log(`[${index + 1}/${options.regions.length}] verified ${id} (resume)`);
    } catch (_) {
      console.log(`[${index + 1}/${options.regions.length}] building ${id} from ${lock.fabricEpoch}`);
      const riderOut = path.join(paths.riderRoot, id, "rider-services.v1.json");
      const fuelOut = path.join(paths.packRoot, id, "fuel.v1.json");
      run("bash", [path.join(__dirname, "extract-region-service-data.sh"), id, "with-fuel"], {
        DIRT_V4_SOURCE_LOCK: options.sourceLock,
        OSM_SERVICE_WORK_ROOT: paths.serviceRoot,
        RIDER_SERVICES_V1_OUT: riderOut,
        FUEL_V1_OUT: fuelOut
      }, { attempts: 3 });
      run(process.execPath, [
        `--max-old-space-size=${graphHeapMiB()}`,
        "--expose-gc",
        path.join(__dirname, "build-region-graph-v4.js"),
        id
      ], {
        DIRT_V4_SOURCE_LOCK: options.sourceLock,
        DIRT_V4_RELEASE_ID: options.releaseId,
        DIRT_V4_PACK_ROOT: paths.packRoot,
        DIRT_V4_FUEL_PATH: fuelOut,
        OSM_LEGAL_ROOT: paths.legalRoot
      }, { attempts: 2 });
      record = verifyRegion(paths, id, options.releaseId, lock, { factoryCommit });
      safeCleanWork(paths, source);
      console.log(`[${index + 1}/${options.regions.length}] sealed ${id}`);
    }
    records.push(record);
    writeJSON(progressFile, {
      schemaVersion: "dirt-fabric-progress.v4",
      releaseId: options.releaseId,
      sourceEpoch: lock.fabricEpoch,
      completedRegionIds: records.map((row) => row.id),
      regionCount: options.regions.length,
      updatedAt: new Date().toISOString()
    });
  }

  const isFullFabric = sameRegions(options.regions, ALL_REGIONS);
  let topology = null;
  if (isFullFabric) {
    const topologyFile = path.join(options.root, "cross-pack-topology.v2.json");
    run(process.execPath, [path.join(__dirname, "build-v4-seams.js"), "--root", paths.packRoot, "--output", topologyFile], {});
    const topologyDoc = readJSON(topologyFile);
    if (topologyDoc.sourceEpoch !== lock.fabricEpoch || !Array.isArray(topologyDoc.pairs) || !topologyDoc.pairs.length) {
      throw new Error("full seam topology is incomplete");
    }
    topology = { ...fileIdentity(topologyFile), pairs: topologyDoc.pairs.length };
    records = options.regions.map((id) =>
      verifyRegion(paths, id, options.releaseId, lock, { requireSeams: true, factoryCommit })
    );
  }

  const release = {
    schemaVersion: "dirt-fabric-release.v4",
    releaseId: options.releaseId,
    status: isFullFabric ? "local-candidate-sealed" : "local-partial-candidate",
    createdAt: new Date().toISOString(),
    factoryCommit,
    sourceEpoch: lock.fabricEpoch,
    sourceLock: null,
    completeFabric: isFullFabric,
    regionCount: records.length,
    requiredRegionCount: ALL_REGIONS.length,
    topology,
    regions: records
  };
  const sealedSourceLock = path.join(options.root, "source-lock.json");
  fs.copyFileSync(options.sourceLock, sealedSourceLock);
  release.sourceLock = fileIdentity(sealedSourceLock);
  writeJSON(path.join(options.root, "release.json"), release);
  console.log(JSON.stringify({
    releaseId: release.releaseId,
    status: release.status,
    regionCount: release.regionCount,
    sourceEpoch: release.sourceEpoch,
    topologyPairs: topology ? topology.pairs : 0,
    root: options.root
  }, null, 2));
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = { main, parseArgs, verifyRegion, sameRegions, graphHeapMiB };
