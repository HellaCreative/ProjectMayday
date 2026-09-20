#!/usr/bin/env node
"use strict";

// Derive regional inputs from one immutable PBF. No independently dated regional
// downloads, and no release-label rewriting of previously encoded graph bytes.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const { geofabrikSource } = require("../routing/registry/geofabrik");
const { bufferProjection } = require("../routing/registry/timezones");
const { clipGeojsonPath } = require("./fetch-admin-polygon");
const { validateGeometry } = require("./prepare-v4-polygons");

function hashFileSet(file, algorithms) {
  const hashes = Object.fromEntries(algorithms.map(name => [name, crypto.createHash(name)]));
  const fd = fs.openSync(file, "r"), buffer = Buffer.allocUnsafe(8 * 1024 * 1024);
  try {
    for (;;) {
      const n = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (!n) break;
      const bytes = buffer.subarray(0, n);
      for (const hash of Object.values(hashes)) hash.update(bytes);
    }
  } finally { fs.closeSync(fd); }
  return Object.fromEntries(Object.entries(hashes).map(([name, hash]) => [name, hash.digest("hex")]));
}
function hashFile(file, algorithm = "sha256") {
  return hashFileSet(file, [algorithm])[algorithm];
}

function run(command, args, log) {
  const fd = log ? fs.openSync(log, "a") : null;
  try {
    const r = spawnSync(command, args, { encoding: "utf8", stdio: log ? ["ignore", fd, fd] : "pipe" });
    if (r.error || r.status !== 0) throw new Error(`${command} failed: ${r.error || r.stderr || log}`);
    return String(r.stdout || "").trim();
  } finally { if (fd !== null) fs.closeSync(fd); }
}
function save(file, doc) {
  fs.writeFileSync(file + ".tmp", JSON.stringify(doc, null, 2) + "\n");
  fs.renameSync(file + ".tmp", file);
}
function parseArgs(args) {
  const o = { regions: [], batchSize: 1 };
  const flags = { "--source": "source", "--url": "url", "--md5": "md5", "--output": "output" };
  for (let i = 0; i < args.length; i++) {
    if (flags[args[i]]) {
      const key = flags[args[i]];
      if (!args[i + 1] || args[i + 1].startsWith("--")) throw new Error(`missing ${args[i]}`);
      o[key] = args[++i];
    } else if (args[i] === "--batch-size") {
      o.batchSize = Number(args[++i]);
      if (!Number.isInteger(o.batchSize) || o.batchSize < 1 || o.batchSize > 2)
        throw new Error("batch size must be 1 or 2 until larger batches are measured");
    } else if (args[i].startsWith("-")) throw new Error(`unknown argument ${args[i]}`);
    else o.regions.push(args[i]);
  }
  if (!o.source || !o.url || !/^[a-f0-9]{32}$/.test(o.md5 || "") || !o.output || !o.regions.length)
    throw new Error("require --source PBF --url dated-URL --md5 expected --output lock.json region...");
  o.regions = [...new Set(o.regions)].sort();
  o.regions.forEach(geofabrikSource);
  return o;
}
function batchConfig(items, timestamp) {
  return { extracts: items.map(item => ({ output: item.pbf,
    polygon: { file_name: item.halo, file_type: "geojson" },
    output_header: { osmosis_replication_timestamp: timestamp } })) };
}
function main(args = process.argv.slice(2)) {
  const o = parseArgs(args), source = path.resolve(o.source), output = path.resolve(o.output);
  const root = path.join(path.dirname(output), "regional-sources");
  fs.mkdirSync(root, { recursive: true });
  const sourceHashes = hashFileSet(source, ["md5", "sha256"]);
  if (sourceHashes.md5 !== o.md5) throw new Error("download does not match publisher MD5");
  const timestamp = run("osmium", ["fileinfo", "-g", "header.option.osmosis_replication_timestamp", source]);
  if (!Number.isFinite(Date.parse(timestamp))) throw new Error("source has no valid OSM timestamp");
  const parent = { sourceUrl: o.url, sourceBytes: fs.statSync(source).size,
    sourceSha256: sourceHashes.sha256, osmTimestamp: timestamp, publisherMD5: o.md5 };
  const epoch = `osm-${timestamp.replace(/[-:]/g, "")}-${parent.sourceSha256.slice(0, 16)}`;
  const partial = output + ".partial";
  const doc = fs.existsSync(partial) ? JSON.parse(fs.readFileSync(partial)) : {
    schema: "dirt-osm-source-lock.partial.v1", fabricEpoch: epoch,
    capturedAt: new Date().toISOString(), commonSource: parent, regions: {}
  };
  if (doc.fabricEpoch !== epoch) throw new Error("resume parent source changed; use a new output directory");
  save(partial, doc);
  console.log(`verified source ${parent.sourceBytes} bytes sha256=${parent.sourceSha256} timestamp=${timestamp}`);
  const tool = run("osmium", ["--version"]).split("\n")[0];
  const pending = [];
  for (const id of o.regions) {
    const region = geofabrikSource(id), polygon = clipGeojsonPath(id);
    if (!polygon) throw new Error(`${id}: missing polygon`);
    validateGeometry(polygon, id);
    const dir = path.join(root, id);
    fs.mkdirSync(dir, { recursive: true });
    const pbf = path.join(dir, "source.osm.pbf"), halo = path.join(dir, "halo.geojson");
    const recipe = { version: 1, parentSha256: parent.sourceSha256,
      polygonSha256: hashFile(polygon), haloMeters: 2000,
      strategy: "smart", completeRelationTypes: "multipolygon,restriction", tool };
    const old = doc.regions[id];
    if (old) {
      if (JSON.stringify(old.extraction) !== JSON.stringify(recipe) ||
          !fs.existsSync(pbf) || hashFile(pbf) !== old.sourceSha256)
        throw new Error(`${id}: resumed source or extraction recipe changed`);
      console.log(`${id}: verified regional source (resume)`);
      continue;
    }
    if (fs.existsSync(halo)) fs.unlinkSync(halo);
    const layer = path.basename(polygon, ".geojson").replace(/'/g, "''");
    run("ogr2ogr", ["-f", "GeoJSON", halo, polygon, "-dialect", "sqlite", "-sql",
      `SELECT ST_Transform(ST_Buffer(ST_Transform(geometry, ${bufferProjection(id, region.country)}), 2000), 4326) AS geometry FROM '${layer}'`, "-nln", "halo"]);
    pending.push({ id, pbf, halo, recipe, dir });
  }
  // One process scans the common parent for at most two independent extracts.
  // Polygon, halo and smart relation-completion semantics are unchanged.
  for (let offset = 0; offset < pending.length; offset += o.batchSize) {
    const batch = pending.slice(offset, offset + o.batchSize);
    const config = path.join(root, `batch-${batch.map(x => x.id).join("-")}.json`);
    save(config, batchConfig(batch, timestamp));
    console.log(`${batch.map(x => x.id).join(",")}: extracting from ${timestamp}`);
    const started = Date.now();
    run("/usr/bin/time", ["-l", "osmium", "extract", "--config", config, "--strategy", "smart",
      "-S", "types=multipolygon,restriction", "--overwrite", source], config + ".log");
    for (const { id, pbf, recipe } of batch) {
      doc.regions[id] = { sourceUrl: o.url, sourceBytes: fs.statSync(pbf).size,
        sourceSha256: hashFile(pbf), osmTimestamp: timestamp, cachedPath: pbf,
        extraction: recipe, elapsedMs: Date.now() - started,
        extractionBatch: batch.map(x => x.id), measurementFile: config + ".log" };
    }
    save(partial, doc);
  }
  doc.regions = Object.fromEntries(o.regions.map(id => [id, doc.regions[id]]));
  doc.regionCount = o.regions.length;
  doc.schema = "dirt-osm-source-lock.v1";
  doc.maxTimestampSkewHours = 0;
  save(output, doc);
  console.log(`locked ${doc.regionCount} regions from ${epoch}`);
}
if (require.main === module) {
  try { main(); } catch (e) { console.error(e); process.exitCode = 1; }
}
module.exports = { main, parseArgs, hashFile, hashFileSet, batchConfig };
