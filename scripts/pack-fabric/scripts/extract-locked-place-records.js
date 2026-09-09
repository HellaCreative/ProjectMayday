#!/usr/bin/env node
"use strict";

// Read only the locked source; never refresh OSM or overwrite a sealed pack.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

function hashFile(file) {
  const hash = crypto.createHash("sha256");
  const fd = fs.openSync(file, "r"), buffer = Buffer.alloc(8 * 1024 * 1024);
  try { let n; while ((n = fs.readSync(fd, buffer, 0, buffer.length, null))) hash.update(buffer.subarray(0, n)); }
  finally { fs.closeSync(fd); }
  return hash.digest("hex");
}
function decode(value) {
  return value.replace(/%([0-9a-f]+)%/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16)));
}
function parseRecord(line) {
  const parts = line.split(" "), type = { n: "node", w: "way", r: "relation" }[parts[0][0]];
  if (!type) throw new Error("Unsupported OPL record");
  const tags = {};
  for (const pair of (parts.find(p => p.startsWith("T")) || "T").slice(1).split(",")) {
    if (!pair) continue;
    const at = pair.indexOf("=");
    if (at < 0) throw new Error("Malformed OPL tag");
    tags[decode(pair.slice(0, at))] = decode(pair.slice(at + 1));
  }
  const row = { sourceId: `${type}/${parts[0].slice(1)}`, type, tags };
  if (type === "node") {
    const x = parts.find(p => p.startsWith("x")), y = parts.find(p => p.startsWith("y"));
    if (!x || !y || x.length < 2 || y.length < 2) throw new Error("Place node lacks coordinates");
    row.coordinate = [Number(x.slice(1)), Number(y.slice(1))];
    if (!row.coordinate.every(Number.isFinite)) throw new Error("Invalid place coordinates");
  }
  return row;
}
function extract(lockPath, outputRoot, regionIds = null) {
  const lock = JSON.parse(fs.readFileSync(lockPath));
  if (lock.schema !== "dirt-osm-source-lock.v1" || Object.keys(lock.regions).length !== 63) throw new Error("Complete source lock required");
  fs.mkdirSync(outputRoot, { recursive: true });
  const progress = { sourceEpoch: lock.fabricEpoch, completed: [] };
  const ids = regionIds || Object.keys(lock.regions).sort();
  if (ids.some(id => !lock.regions[id])) throw new Error("Unknown locked source region");
  for (const id of ids) {
    const source = lock.regions[id], dir = path.join(outputRoot, id);
    fs.mkdirSync(dir, { recursive: true });
    if (fs.statSync(source.cachedPath).size !== source.sourceBytes || hashFile(source.cachedPath) !== source.sourceSha256) throw new Error(`${id}: locked source mismatch`);
    const opl = path.join(dir, "places.opl"), recordPath = path.join(dir, "place-records.json");
    if (!fs.existsSync(recordPath)) {
      const disk = fs.statfsSync(outputRoot);
      if (disk.bavail * disk.bsize < 16 * 1024 ** 3) throw new Error("Pack working-space floor reached");
      const result = spawnSync("osmium", ["tags-filter", source.cachedPath, "nwr/place=city,town", "--omit-referenced", "-f", "opl", "-o", `${opl}.tmp`], { encoding: "utf8" });
      if (result.status !== 0) throw new Error(`${id}: ${result.stderr}`);
      fs.renameSync(`${opl}.tmp`, opl);
      const records = fs.readFileSync(opl, "utf8").split("\n").filter(Boolean).map(parseRecord);
      if (records.some(r => !["city", "town"].includes(r.tags.place))) throw new Error("Unexpected place filter result");
      const data = { schema: "dirt-locked-place-records.v1", regionId: id, sourceEpoch: lock.fabricEpoch, source, extractSha256: hashFile(opl), records };
      fs.writeFileSync(`${recordPath}.tmp`, JSON.stringify(data) + "\n");
      fs.renameSync(`${recordPath}.tmp`, recordPath);
    }
    const data = JSON.parse(fs.readFileSync(recordPath));
    if (data.source.sourceSha256 !== source.sourceSha256 || data.extractSha256 !== hashFile(opl)) throw new Error(`${id}: saved extract mismatch`);
    const count = type => data.records.filter(r => r.type === type).length;
    const row = { id, nodes: count("node"), ways: count("way"), relations: count("relation"), sha256: hashFile(recordPath) };
    progress.completed.push(row);
    fs.writeFileSync(path.join(outputRoot, "progress.json"), JSON.stringify(progress, null, 2) + "\n");
    console.log(JSON.stringify(row));
  }
}
if (require.main === module) extract(path.resolve(process.argv[2]), path.resolve(process.argv[3]));
module.exports = { hashFile, parseRecord, extract };
