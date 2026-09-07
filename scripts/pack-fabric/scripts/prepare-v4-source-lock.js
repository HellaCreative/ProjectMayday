#!/usr/bin/env node
"use strict";

/**
 * Download/cache every regional Geofabrik source and lock its exact identity
 * before any V4 graph is stamped. The partial file is resume-safe.
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const { OSM_REGION, geofabrikPbfUrl } = require("../routing/registry/geofabrik");

const FABRIC = path.join(__dirname, "..");
const CACHE_ROOT = process.env.OSM_PBF_CACHE || path.join(process.env.TMPDIR || "/tmp", "dirt-osm-poi-build/regions");
const GIB = 1024 ** 3;

function assertDiskSpace(regionId) {
  fs.mkdirSync(CACHE_ROOT, { recursive: true });
  const stats = fs.statfsSync(CACHE_ROOT);
  const free = Number(stats.bavail) * Number(stats.bsize);
  const minimum = Number(process.env.DIRT_V4_SOURCE_MIN_FREE_GIB || 16) * GIB;
  if (!Number.isFinite(free) || free < minimum) {
    throw new Error(`${regionId}: only ${(free / GIB).toFixed(1)} GiB free before source download; safety floor is ${minimum / GIB} GiB`);
  }
}

function shaFile(file) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash("sha256");
    const stream = fs.createReadStream(file);
    stream.on("error", reject);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

function parseArgs(argv) {
  const options = { output: null, refresh: false, regions: [] };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--output") options.output = argv[++i];
    else if (argv[i] === "--refresh") options.refresh = true;
    else options.regions.push(String(argv[i]).toLowerCase());
  }
  if (!options.output) throw new Error("--output <source-lock.json> is required");
  return options;
}

function pbfTimestamp(file) {
  const result = spawnSync("osmium", ["fileinfo", "-g", "header.option.osmosis_replication_timestamp", file], {
    encoding: "utf8"
  });
  if (result.status !== 0) throw new Error(`cannot read OSM timestamp for ${file}`);
  return String(result.stdout || "").trim();
}

function save(file, document) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(document, null, 2) + "\n");
}

async function identity(regionId) {
  const source = OSM_REGION[regionId];
  const pbf = path.join(CACHE_ROOT, source.slug, "source.osm.pbf");
  const stat = fs.statSync(pbf);
  return {
    sourceUrl: geofabrikPbfUrl(regionId),
    sourceBytes: stat.size,
    sourceSha256: await shaFile(pbf),
    osmTimestamp: pbfTimestamp(pbf),
    cachedPath: pbf
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const output = path.resolve(options.output);
  const ids = (options.regions.length ? options.regions : Object.keys(OSM_REGION)).sort();
  for (const id of ids) {
    if (!OSM_REGION[id]) throw new Error(`unknown region ${id}`);
  }
  const partial = output + ".partial";
  let doc = fs.existsSync(partial)
    ? JSON.parse(fs.readFileSync(partial, "utf8"))
    : {
        schema: "dirt-osm-source-lock.partial.v1",
        fabricEpoch: `geofabrik-capture-${new Date().toISOString().replace(/[-:.]/g, "").slice(0, 15)}Z`,
        capturedAt: new Date().toISOString(),
        regionCount: ids.length,
        regions: {}
      };
  for (let index = 0; index < ids.length; index += 1) {
    const id = ids[index];
    const source = OSM_REGION[id];
    if (doc.regions[id]) {
      const current = await identity(id).catch(() => null);
      if (current && current.sourceSha256 === doc.regions[id].sourceSha256) {
        console.log(`[${index + 1}/${ids.length}] locked ${id} (resume)`);
        continue;
      }
      throw new Error(`cached source changed after ${id} was locked`);
    }
    assertDiskSpace(id);
    console.log(`[${index + 1}/${ids.length}] locking ${id} (${source.slug})`);
    const result = spawnSync(
      "bash",
      [path.join(__dirname, "ensure-current-osm-pbf.sh"),
        `https://download.geofabrik.de/north-america/${source.country}`,
        source.slug,
        path.join(CACHE_ROOT, source.slug, "source.osm.pbf")],
      {
        stdio: "inherit",
        env: {
          ...process.env,
          OSM_REFRESH: options.refresh ? "1" : "0",
          OSM_PBF_MAX_AGE_HOURS: options.refresh ? "0" : (process.env.OSM_PBF_MAX_AGE_HOURS || "12")
        }
      }
    );
    if (result.status !== 0) throw new Error(`source download failed for ${id}`);
    doc.regions[id] = await identity(id);
    save(partial, doc);
  }
  const times = ids.map((id) => Date.parse(doc.regions[id].osmTimestamp));
  if (times.some((value) => !Number.isFinite(value))) throw new Error("source lock has invalid OSM timestamps");
  const skewHours = (Math.max(...times) - Math.min(...times)) / 3_600_000;
  if (skewHours > 72) throw new Error(`regional source timestamps span ${skewHours.toFixed(1)} hours`);
  doc.schema = "dirt-osm-source-lock.v1";
  doc.completedAt = new Date().toISOString();
  doc.maxTimestampSkewHours = skewHours;
  save(output, doc);
  console.log(JSON.stringify({ output, fabricEpoch: doc.fabricEpoch, regions: ids.length, maxTimestampSkewHours: skewHours }, null, 2));
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  });
}

module.exports = { main, parseArgs };
